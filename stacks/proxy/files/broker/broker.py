#!/usr/bin/env python3
"""proxy broker — per-user persistent browsers over shared per-country NordVPN
gateways.

Model (validated by Spike G, memory #10214):
  * ONE **gateway** pod per active country holds that country's single NordVPN
    WireGuard tunnel (gluetun) and a WireGuard *server* sidecar; it FORWARDS
    traffic out through the tunnel (ip_forward + MASQUERADE + the return-path
    `ip rule`).  The NordVPN ~10-tunnel account cap therefore limits concurrent
    COUNTRIES (pool.MAX_COUNTRIES minus RESERVED_SLOTS), not users.
  * ONE **browser** pod per user (gluetun in custom-WireGuard mode dialling its
    country gateway + headful Chromium + noVNC, sharing one netns so the browser
    egresses leak-proof through the gateway).  A persistent encrypted PVC holds
    the Chromium profile, so logins/tabs survive across visits.

Peer wiring is ConfigMap-driven (the vpn-portal pattern, memory #9732): the
broker maintains a per-gateway peers ConfigMap; the gateway sidecar reconciles
wg0 from it, so peers survive a gateway restart and no `kubectl exec` is needed.
Pure stdlib on python:3.12-slim (ConfigMap-mounted, no custom image) — the
decision logic lives in pool.py, key generation in wgkeys.py (both unit-tested).
Design: docs/plans/2026-07-25-proxy-scale-design.md
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pool
import wgkeys

# ------------------------------------------------------------------ config
NS = os.environ.get("NAMESPACE", "proxy")
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
HERE = os.path.dirname(os.path.abspath(__file__))

HOST = os.environ.get("HOST", "proxy.viktorbarzin.me")
TLS_SECRET = os.environ.get("TLS_SECRET", "proxy-tls")
STRIP_MW = os.environ.get("STRIP_MIDDLEWARE", "%s-strip-session@kubernetescrd" % NS)
NORDVPN_TOKEN = os.environ.get("NORDVPN_TOKEN", "")
DEADLINE = int(os.environ.get("SESSION_DEADLINE_SECONDS", "0"))  # 0 = persistent
GW_IDLE_SECONDS = int(os.environ.get("GW_IDLE_SECONDS", "600"))  # reap empty gateways
PORT = int(os.environ.get("PORT", "8080"))
GLUETUN_IMAGE = os.environ.get("GLUETUN_IMAGE", "ghcr.io/qdm12/gluetun:latest")
WGTOOLS_IMAGE = os.environ.get("WGTOOLS_IMAGE", "ghcr.io/linuxserver/wireguard:latest")
BROWSER_IMAGE = os.environ.get("BROWSER_IMAGE", "ghcr.io/viktorbarzin/chrome-service-browser:latest")
NOVNC_IMAGE = os.environ.get("NOVNC_IMAGE", "ghcr.io/viktorbarzin/chrome-service-novnc:19d0f0933a8ec75be6cfa077db88e0f8c3760f40")
PROFILE_STORAGE_CLASS = os.environ.get("PROFILE_STORAGE_CLASS", "proxmox-lvm-encrypted")
PROFILE_SIZE = os.environ.get("PROFILE_SIZE", "2Gi")
GATEWAY_NODE_LABEL = os.environ.get("GATEWAY_NODE_LABEL", "proxy.viktorbarzin.me/gateway")
# Stable, unguessable per-user noVNC token: HMAC(salt, userkey). Salt defaults to
# the NordVPN token (always present, never user-visible) so no new secret is
# needed; the token gates the auth=none /s/<token> path.
TOKEN_SALT = os.environ.get("TOKEN_SALT", NORDVPN_TOKEN or "proxy").encode()

COUNTRIES = [
    "Japan", "United States", "United Kingdom", "Germany", "Netherlands",
    "France", "Canada", "Australia", "Switzerland", "Sweden", "Singapore",
    "Spain", "Italy", "Brazil", "India", "South Korea", "Poland", "Norway",
    "Ireland", "Finland", "Denmark", "Belgium", "Austria", "Portugal",
    "Hong Kong", "Taiwan", "Mexico", "New Zealand", "South Africa", "Turkey",
]

_TOKEN = open(_TOKEN_PATH).read().strip() if os.path.exists(_TOKEN_PATH) else ""
_SSL = ssl.create_default_context(cafile=_CA_PATH) if os.path.exists(_CA_PATH) else ssl.create_default_context()
_lock = threading.Lock()  # serialise capacity-check + create (TOCTOU)


# ------------------------------------------------------------------ k8s REST
def k8s(method, path, body=None, content_type="application/json"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + _TOKEN)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, context=_SSL, timeout=15) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else {}
        except Exception:
            return e.code, {"raw": raw.decode("utf-8", "replace")}


def _apply(kind_path, name, body):
    """Create, or PUT-replace on 409, an object. kind_path is the collection URL."""
    st, resp = k8s("POST", kind_path, body)
    if st == 409:
        return k8s("PUT", kind_path + "/" + name, body)
    return st, resp


# ------------------------------------------------------------------ nordvpn
def nordvpn_wg_key():
    req = urllib.request.Request("https://api.nordvpn.com/v1/users/services/credentials")
    req.add_header("Authorization", "Basic " + base64.b64encode(("token:" + NORDVPN_TOKEN).encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["nordlynx_private_key"]


def ensure_nordvpn_secret():
    """Upsert the shared Secret holding the current NordLynx key (re-fetched via
    the durable token, so account-side key rotation is picked up)."""
    key = nordvpn_wg_key()
    body = {"apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": "nordvpn-wg", "namespace": NS},
            "type": "Opaque", "stringData": {"wg_key": key}}
    st, _ = k8s("POST", "/api/v1/namespaces/%s/secrets" % NS, body)
    if st == 409:
        k8s("PATCH", "/api/v1/namespaces/%s/secrets/nordvpn-wg" % NS,
            {"stringData": {"wg_key": key}}, content_type="application/merge-patch+json")


# ------------------------------------------------------------------ helpers
def _label(s):
    return re.sub(r"[^a-z0-9-]", "-", (s or "").lower()).strip("-")[:40] or "x"


def _userkey(user):
    """DNS-safe, stable, collision-resistant per-user key."""
    return "%s-%s" % (_label(user), hashlib.sha1((user or "user").encode()).hexdigest()[:8])


def _token(userkey):
    return hmac.new(TOKEN_SALT, userkey.encode(), hashlib.sha256).hexdigest()[:32]


def _gw_name(idx):
    return "proxy-gw-%d" % idx


def _br_name(userkey):
    return "proxy-br-" + userkey


def _pvc_name(userkey):
    return "proxy-profile-" + userkey


def _url(token):
    return ("/s/%s/vnc.html?path=s/%s/websockify&autoconnect=true"
            "&resize=scale&quality=6&compression=6" % (token, token))


# ------------------------------------------------------------------ gateway objects
def build_gw_secret(idx, priv):
    return {"apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": _gw_name(idx) + "-wg", "namespace": NS,
                         "labels": {"app": "proxy-gateway", "proxy/gw-idx": str(idx)}},
            "type": "Opaque", "stringData": {"privkey": priv}}


def build_gw_peers_cm(idx, peers_text):
    return {"apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"name": _gw_name(idx) + "-peers", "namespace": NS,
                         "labels": {"app": "proxy-gateway", "proxy/gw-idx": str(idx)}},
            "data": {"peers": peers_text}}


def build_gw_service(idx):
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": _gw_name(idx), "namespace": NS,
                         "labels": {"app": "proxy-gateway", "proxy/gw-idx": str(idx)}},
            "spec": {"selector": {"proxy/gw-idx": str(idx)},
                     "ports": [{"name": "wg", "port": 51820, "targetPort": 51820, "protocol": "UDP"}]}}


def build_gw_pod(idx, country, pubkey):
    subnet = pool.gateway_subnet(idx)
    gw_ip = pool.gateway_ip(idx)
    wg_script = (
        "set -x\n"
        "for i in $(seq 1 120); do ip link show tun0 >/dev/null 2>&1 && break; sleep 2; done\n"
        "ip link show tun0 || { echo TUN0_NEVER_UP; sleep 3600; }\n"
        "ip link add wg0 type wireguard 2>/dev/null || true\n"
        "wg set wg0 private-key /gw-wg/privkey listen-port 51820\n"
        "ip addr add %(gw_ip)s/24 dev wg0 2>/dev/null || true\n"
        "ip link set wg0 up\n"
        "iptables -t nat -C POSTROUTING -s %(subnet)s -o tun0 -j MASQUERADE 2>/dev/null || "
        "iptables -t nat -I POSTROUTING 1 -s %(subnet)s -o tun0 -j MASQUERADE\n"
        "iptables -C FORWARD -i wg0 -o tun0 -j ACCEPT 2>/dev/null || "
        "iptables -I FORWARD 1 -i wg0 -o tun0 -j ACCEPT\n"
        "iptables -C FORWARD -i tun0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || "
        "iptables -I FORWARD 1 -i tun0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
        "ip rule show | grep -q 'to %(subnet)s lookup main' || ip rule add to %(subnet)s lookup main pref 90\n"
        "echo GATEWAY_READY\n"
        "while true; do\n"
        "  if [ -f /peers/peers ]; then\n"
        "    while read pub aip; do [ -n \"$pub\" ] && wg set wg0 peer \"$pub\" allowed-ips \"$aip\"; done < /peers/peers\n"
        "    want=$(awk '{print $1}' /peers/peers | sort -u)\n"
        "    for p in $(wg show wg0 peers); do echo \"$want\" | grep -qx \"$p\" || wg set wg0 peer \"$p\" remove; done\n"
        "  fi\n"
        "  sleep 10\n"
        "done\n"
    ) % {"gw_ip": gw_ip, "subnet": subnet}
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": _gw_name(idx), "namespace": NS,
                     "labels": {"app": "proxy-gateway", "proxy/gw-idx": str(idx),
                                "proxy/country": _label(country)},
                     "annotations": {"proxy/country-name": country, "proxy/wg-pub": pubkey,
                                     "proxy/last-used": str(int(time.time()))}},
        "spec": {
            "restartPolicy": "Always",
            "nodeSelector": {GATEWAY_NODE_LABEL: "true"},
            "dnsPolicy": "None", "dnsConfig": {"nameservers": ["127.0.0.1"]},
            "securityContext": {"sysctls": [{"name": "net.ipv4.ip_forward", "value": "1"}]},
            "containers": [
                {"name": "gluetun", "image": GLUETUN_IMAGE,
                 "securityContext": {"capabilities": {"add": ["NET_ADMIN", "SYS_MODULE"]}},
                 "env": [
                     {"name": "VPN_SERVICE_PROVIDER", "value": "nordvpn"},
                     {"name": "VPN_TYPE", "value": "wireguard"},
                     {"name": "SERVER_COUNTRIES", "value": country},
                     {"name": "DOT", "value": "on"},
                     {"name": "FIREWALL_INPUT_PORTS", "value": "51820"},
                     {"name": "FIREWALL_OUTBOUND_SUBNETS",
                      "value": "10.10.0.0/16,10.96.0.0/12," + subnet},
                     {"name": "WIREGUARD_PRIVATE_KEY",
                      "valueFrom": {"secretKeyRef": {"name": "nordvpn-wg", "key": "wg_key"}}},
                 ],
                 "resources": {"requests": {"cpu": "20m", "memory": "80Mi"}, "limits": {"memory": "256Mi"}}},
                {"name": "wgserver", "image": WGTOOLS_IMAGE,
                 "securityContext": {"capabilities": {"add": ["NET_ADMIN"]}},
                 "command": ["bash", "-c", wg_script],
                 "volumeMounts": [{"name": "gw-wg", "mountPath": "/gw-wg", "readOnly": True},
                                  {"name": "peers", "mountPath": "/peers", "readOnly": True}],
                 "resources": {"requests": {"cpu": "10m", "memory": "48Mi"}, "limits": {"memory": "128Mi"}}},
            ],
            "volumes": [
                {"name": "gw-wg", "secret": {"secretName": _gw_name(idx) + "-wg", "defaultMode": 256}},
                {"name": "peers", "configMap": {"name": _gw_name(idx) + "-peers", "optional": True}},
            ],
        },
    }


# ------------------------------------------------------------------ browser objects
def build_pvc(userkey):
    return {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
            "metadata": {"name": _pvc_name(userkey), "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey},
                         "annotations": {"resize.topolvm.io/threshold": "10%",
                                         "resize.topolvm.io/increase": "100%",
                                         "resize.topolvm.io/storage_limit": "8Gi"}},
            "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": PROFILE_STORAGE_CLASS,
                     "resources": {"requests": {"storage": PROFILE_SIZE}}}}


def build_br_secret(userkey, priv):
    return {"apiVersion": "v1", "kind": "Secret",
            "metadata": {"name": _br_name(userkey) + "-wg", "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey}},
            "type": "Opaque", "stringData": {"WIREGUARD_PRIVATE_KEY": priv}}


def build_br_pod(userkey, country, gw_idx, wg_ip, gw_pub, gw_endpoint_ip, pubkey, token):
    chrome_cmd = (
        "set -e\n"
        "Xvfb :99 -screen 0 1280x720x24 -listen tcp -ac &\n"
        "sleep 2\n"
        "exec /opt/google/chrome/chrome --no-sandbox --disable-dev-shm-usage "
        "--no-first-run --no-default-browser-check --password-store=basic "
        "--use-mock-keychain --user-data-dir=/profile "
        "--window-size=1280,720 --start-maximized about:blank\n"
    )
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": _br_name(userkey), "namespace": NS,
                     "labels": {"app": "proxy-browser", "proxy/user": userkey,
                                "proxy/gw-idx": str(gw_idx), "proxy/country": _label(country)},
                     "annotations": {"proxy/country-name": country, "proxy/wg-pub": pubkey,
                                     "proxy/wg-ip": wg_ip, "proxy/token": token,
                                     "proxy/started": str(int(time.time()))}},
        "spec": {
            "restartPolicy": "Always",
            "dnsPolicy": "None", "dnsConfig": {"nameservers": ["127.0.0.1"]},
            "imagePullSecrets": [{"name": "ghcr-credentials"}],
            "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [
                {"name": "gluetun", "image": GLUETUN_IMAGE,
                 "securityContext": {"capabilities": {"add": ["NET_ADMIN", "SYS_MODULE"]}},
                 "env": [
                     {"name": "VPN_SERVICE_PROVIDER", "value": "custom"},
                     {"name": "VPN_TYPE", "value": "wireguard"},
                     {"name": "WIREGUARD_ENDPOINT_IP", "value": gw_endpoint_ip},
                     {"name": "WIREGUARD_ENDPOINT_PORT", "value": "51820"},
                     {"name": "WIREGUARD_PUBLIC_KEY", "value": gw_pub},
                     {"name": "WIREGUARD_ADDRESSES", "value": wg_ip + "/32"},
                     {"name": "FIREWALL_INPUT_PORTS", "value": "6080"},
                     {"name": "FIREWALL_OUTBOUND_SUBNETS", "value": "10.10.0.0/16,10.96.0.0/12"},
                     {"name": "WIREGUARD_PRIVATE_KEY",
                      "valueFrom": {"secretKeyRef": {"name": _br_name(userkey) + "-wg",
                                                     "key": "WIREGUARD_PRIVATE_KEY"}}},
                 ],
                 "resources": {"requests": {"cpu": "20m", "memory": "80Mi"}, "limits": {"memory": "256Mi"}}},
                {"name": "chrome", "image": BROWSER_IMAGE, "imagePullPolicy": "IfNotPresent",
                 "command": ["bash", "-c", chrome_cmd],
                 "securityContext": {"runAsUser": 1000, "runAsGroup": 1000},
                 "env": [{"name": "DISPLAY", "value": ":99"}, {"name": "HOME", "value": "/profile"}],
                 "volumeMounts": [{"name": "profile", "mountPath": "/profile"}],
                 "resources": {"requests": {"cpu": "250m", "memory": "1536Mi"}, "limits": {"memory": "3Gi"}}},
                {"name": "novnc", "image": NOVNC_IMAGE, "imagePullPolicy": "IfNotPresent",
                 "command": ["bash", "-c", "ulimit -n 65536; exec /entrypoint.sh"],
                 "securityContext": {"runAsUser": 1000, "runAsGroup": 1000},
                 "ports": [{"name": "http", "containerPort": 6080}],
                 "readinessProbe": {"tcpSocket": {"port": 6080}, "initialDelaySeconds": 5,
                                    "periodSeconds": 3, "failureThreshold": 60},
                 "resources": {"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}}},
            ],
            "volumes": [{"name": "profile", "persistentVolumeClaim": {"claimName": _pvc_name(userkey)}}],
        },
    }


def build_br_service(userkey):
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": _br_name(userkey), "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey}},
            "spec": {"selector": {"proxy/user": userkey},
                     "ports": [{"name": "novnc", "port": 6080, "targetPort": 6080}]}}


def build_br_ingress(userkey, token):
    return {"apiVersion": "networking.k8s.io/v1", "kind": "Ingress",
            "metadata": {"name": _br_name(userkey), "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey},
                         "annotations": {
                             "traefik.ingress.kubernetes.io/router.entrypoints": "websecure",
                             "traefik.ingress.kubernetes.io/router.middlewares": STRIP_MW,
                             "traefik.ingress.kubernetes.io/router.priority": "1000"}},
            "spec": {"ingressClassName": "traefik",
                     "tls": [{"hosts": [HOST], "secretName": TLS_SECRET}],
                     "rules": [{"host": HOST, "http": {"paths": [{
                         "path": "/s/" + token, "pathType": "Prefix",
                         "backend": {"service": {"name": _br_name(userkey), "port": {"number": 6080}}}}]}}]}}


# ------------------------------------------------------------------ state reads
def _list(kind, selector="app in (proxy-gateway,proxy-browser)"):
    st, obj = k8s("GET", "/api/v1/namespaces/%s/%s?labelSelector=%s" % (
        NS, kind, urllib.parse.quote(selector)))
    return obj.get("items", []) if isinstance(obj, dict) else []


def list_gateways():
    out = []
    for p in _list("pods", "app=proxy-gateway"):
        md = p.get("metadata", {})
        if md.get("deletionTimestamp"):
            continue
        an = md.get("annotations", {})
        out.append({"idx": int(md["labels"]["proxy/gw-idx"]),
                    "country": an.get("proxy/country-name"),
                    "pubkey": an.get("proxy/wg-pub"),
                    "last_used": int(an.get("proxy/last-used", "0"))})
    return out


def list_browsers():
    out = []
    for p in _list("pods", "app=proxy-browser"):
        md = p.get("metadata", {})
        if md.get("deletionTimestamp"):
            continue
        an = md.get("annotations", {})
        status = p.get("status", {})
        cs = status.get("containerStatuses", [])
        ready = bool(cs) and all(c.get("ready") for c in cs) and status.get("phase") == "Running"
        out.append({"userkey": md["labels"]["proxy/user"],
                    "gateway_idx": int(md["labels"].get("proxy/gw-idx", "0")),
                    "country": an.get("proxy/country-name"),
                    "wg_pub": an.get("proxy/wg-pub"), "wg_ip": an.get("proxy/wg-ip"),
                    "token": an.get("proxy/token"),
                    "started": int(an.get("proxy/started", "0")),
                    "phase": status.get("phase"), "ready": ready,
                    "dead": status.get("phase") in ("Failed", "Succeeded")})
    return out


def _gw_endpoint_ip(idx):
    st, svc = k8s("GET", "/api/v1/namespaces/%s/services/%s" % (NS, _gw_name(idx)))
    return svc.get("spec", {}).get("clusterIP") if st == 200 else None


# ------------------------------------------------------------------ gateway lifecycle
def update_gw_peers(idx):
    lines = ["%s %s/32" % (b["wg_pub"], b["wg_ip"])
             for b in list_browsers()
             if b["gateway_idx"] == idx and b["wg_pub"] and b["wg_ip"] and not b["dead"]]
    _apply("/api/v1/namespaces/%s/configmaps" % NS, _gw_name(idx) + "-peers",
           build_gw_peers_cm(idx, "\n".join(lines) + "\n"))


def _touch_gw(idx):
    k8s("PATCH", "/api/v1/namespaces/%s/pods/%s" % (NS, _gw_name(idx)),
        {"metadata": {"annotations": {"proxy/last-used": str(int(time.time()))}}},
        content_type="application/merge-patch+json")


def ensure_gateway(country):
    """Return {idx, pubkey, endpoint_ip} for `country`, creating the gateway if
    absent. Raises RuntimeError at the concurrent-country cap."""
    gateways = list_gateways()
    action, payload = pool.plan_gateway(country, gateways)
    if action == "reject":
        raise RuntimeError(payload["reason"])
    if action == "reuse":
        idx = payload["idx"]
        _touch_gw(idx)
        gw = next(g for g in gateways if g["idx"] == idx)
        return {"idx": idx, "pubkey": gw["pubkey"], "endpoint_ip": _gw_endpoint_ip(idx)}
    idx = payload["idx"]
    priv, pub = wgkeys.genkeypair()
    ensure_nordvpn_secret()
    _apply("/api/v1/namespaces/%s/secrets" % NS, _gw_name(idx) + "-wg", build_gw_secret(idx, priv))
    _apply("/api/v1/namespaces/%s/configmaps" % NS, _gw_name(idx) + "-peers", build_gw_peers_cm(idx, "\n"))
    _apply("/api/v1/namespaces/%s/services" % NS, _gw_name(idx), build_gw_service(idx))
    k8s("POST", "/api/v1/namespaces/%s/pods" % NS, build_gw_pod(idx, country, pub))
    return {"idx": idx, "pubkey": pub, "endpoint_ip": _gw_endpoint_ip(idx)}


def delete_gateway(idx):
    k8s("DELETE", "/api/v1/namespaces/%s/pods/%s" % (NS, _gw_name(idx)))
    k8s("DELETE", "/api/v1/namespaces/%s/services/%s" % (NS, _gw_name(idx)))
    k8s("DELETE", "/api/v1/namespaces/%s/configmaps/%s-peers" % (NS, _gw_name(idx)))
    k8s("DELETE", "/api/v1/namespaces/%s/secrets/%s-wg" % (NS, _gw_name(idx)))


# ------------------------------------------------------------------ browser lifecycle
def browser_for(userkey):
    for b in list_browsers():
        if b["userkey"] == userkey:
            return b
    return None


def create_browser(user, country):
    if country not in COUNTRIES:
        raise ValueError("unknown country")
    userkey = _userkey(user)
    token = _token(userkey)
    with _lock:
        existing = browser_for(userkey)
        if existing and existing["country"] == country and not existing["dead"]:
            return {"country": country, "url": _url(token), "token": token}
        if existing:                      # switching country / recovering a dead pod
            _delete_browser_pod(userkey)  # keep the PVC
        gw = ensure_gateway(country)
        used_ips = [b["wg_ip"] for b in list_browsers() if b["gateway_idx"] == gw["idx"] and b["wg_ip"]]
        wg_ip = pool.alloc_client_ip(gw["idx"], used_ips)
        priv, pub = wgkeys.genkeypair()
        _apply("/api/v1/namespaces/%s/persistentvolumeclaims" % NS, _pvc_name(userkey), build_pvc(userkey))
        _apply("/api/v1/namespaces/%s/secrets" % NS, _br_name(userkey) + "-wg", build_br_secret(userkey, priv))
        k8s("POST", "/api/v1/namespaces/%s/pods" % NS,
            build_br_pod(userkey, country, gw["idx"], wg_ip, gw["pubkey"], gw["endpoint_ip"], pub, token))
        _apply("/api/v1/namespaces/%s/services" % NS, _br_name(userkey), build_br_service(userkey))
        _apply("/apis/networking.k8s.io/v1/namespaces/%s/ingresses" % NS, _br_name(userkey),
               build_br_ingress(userkey, token))
        update_gw_peers(gw["idx"])
        _touch_gw(gw["idx"])
    return {"country": country, "url": _url(token), "token": token}


def _delete_browser_pod(userkey):
    """Delete the browser pod+svc+ingress+wg-secret; KEEP the profile PVC."""
    k8s("DELETE", "/apis/networking.k8s.io/v1/namespaces/%s/ingresses/%s" % (NS, _br_name(userkey)))
    k8s("DELETE", "/api/v1/namespaces/%s/services/%s" % (NS, _br_name(userkey)))
    k8s("DELETE", "/api/v1/namespaces/%s/secrets/%s-wg" % (NS, _br_name(userkey)))
    k8s("DELETE", "/api/v1/namespaces/%s/pods/%s" % (NS, _br_name(userkey)))


def delete_browser(userkey, drop_profile=False):
    _delete_browser_pod(userkey)
    if drop_profile:
        k8s("DELETE", "/api/v1/namespaces/%s/persistentvolumeclaims/%s" % (NS, _pvc_name(userkey)))


# ------------------------------------------------------------------ reaper
def reaper():
    while True:
        try:
            browsers = list_browsers()
            gateways = list_gateways()
            dead_gws, dead_browsers = pool.plan_reaping(
                [{"idx": g["idx"], "last_used": g["last_used"]} for g in gateways],
                [{"id": b["userkey"], "gateway_idx": b["gateway_idx"], "dead": b["dead"]}
                 for b in browsers],
                now=time.time(), gw_idle_seconds=GW_IDLE_SECONDS)
            for uk in dead_browsers:
                _delete_browser_pod(uk)
            for g in gateways:            # re-assert peers (recover restarts) then reap idle
                if g["idx"] not in dead_gws:
                    update_gw_peers(g["idx"])
            for idx in dead_gws:
                delete_gateway(idx)
        except Exception as e:
            print("reaper error:", e, flush=True)
        time.sleep(60)


# ------------------------------------------------------------------ http
def _page():
    with open(os.path.join(HERE, "index.html"), "rb") as f:
        return f.read()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _owner(self):
        return (self.headers.get("X-authentik-username")
                or self.headers.get("X-Authentik-Username") or "user")

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index.html"):
            return self._send(200, _page(), "text/html; charset=utf-8")
        if self.path == "/healthz":
            return self._send(200, b'{"ok":true}')
        if self.path == "/metrics":
            try:
                g, b = len(list_gateways()), len(list_browsers())
            except Exception:
                g, b = -1, -1
            body = ("# HELP proxy_gateways_active Active country gateways\n"
                    "# TYPE proxy_gateways_active gauge\nproxy_gateways_active %d\n"
                    "# HELP proxy_browsers_active Active user browsers\n"
                    "# TYPE proxy_browsers_active gauge\nproxy_browsers_active %d\n"
                    "# HELP proxy_max_countries Concurrent-country ceiling\n"
                    "# TYPE proxy_max_countries gauge\nproxy_max_countries %d\n"
                    % (g, b, pool.MAX_COUNTRIES - pool.RESERVED_SLOTS))
            return self._send(200, body, "text/plain; version=0.0.4")
        if self.path == "/api/countries":
            return self._send(200, json.dumps(
                {"countries": COUNTRIES, "max_countries": pool.MAX_COUNTRIES - pool.RESERVED_SLOTS}))
        if self.path == "/api/me":
            try:
                b = browser_for(_userkey(self._owner()))
                return self._send(200, json.dumps({"browser": (
                    {"country": b["country"], "ready": b["ready"], "phase": b["phase"],
                     "url": _url(b["token"])} if b else None)}))
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        if self.path == "/api/browser":
            n = int(self.headers.get("Content-Length", "0") or "0")
            try:
                req = json.loads(self.rfile.read(n) or "{}")
                return self._send(202, json.dumps(create_browser(self._owner(), req.get("country"))))
            except ValueError as e:
                return self._send(400, json.dumps({"error": str(e)}))
            except RuntimeError as e:
                return self._send(409, json.dumps({"error": str(e)}))
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')

    def do_DELETE(self):
        if self.path == "/api/browser":
            try:
                delete_browser(_userkey(self._owner()))
                return self._send(200, b'{"ok":true}')
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')


def main():
    try:
        ensure_nordvpn_secret()
        print("startup: nordvpn secret ensured", flush=True)
    except Exception as e:
        print("startup: ensure_nordvpn_secret failed (will retry on demand):", e, flush=True)
    threading.Thread(target=reaper, daemon=True).start()
    print("proxy-broker on :%d (ns=%s host=%s max_countries=%d)" % (
        PORT, NS, HOST, pool.MAX_COUNTRIES - pool.RESERVED_SLOTS), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
