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
# Per-browser subdomain base: each browser is served at proxy-<token>.<BASE_DOMAIN>
# (rides the zone-wide * wildcard DNS + wildcard TLS). A dedicated subdomain per
# browser keeps each neko's signaling WebSocket + assets at its own root (the
# unguessable token IS the subdomain and the gate).
BASE_DOMAIN = os.environ.get("BASE_DOMAIN", HOST.split(".", 1)[1] if "." in HOST else HOST)
TLS_SECRET = os.environ.get("TLS_SECRET", "proxy-tls")
STRIP_MW = os.environ.get("STRIP_MIDDLEWARE", "%s-strip-session@kubernetescrd" % NS)
NORDVPN_TOKEN = os.environ.get("NORDVPN_TOKEN", "")
DEADLINE = int(os.environ.get("SESSION_DEADLINE_SECONDS", "0"))  # 0 = persistent
GW_IDLE_SECONDS = int(os.environ.get("GW_IDLE_SECONDS", "600"))  # reap empty gateways
PORT = int(os.environ.get("PORT", "8080"))
GLUETUN_IMAGE = os.environ.get("GLUETUN_IMAGE", "ghcr.io/qdm12/gluetun:latest")
WGTOOLS_IMAGE = os.environ.get("WGTOOLS_IMAGE", "ghcr.io/linuxserver/wireguard:latest")
# neko (WebRTC H.264 + Opus audio) streams headful Chromium — smooth video +
# audio, unlike KasmVNC's software WebP tiles (infra#81). One container; serves
# the signaling/UI on HTTP :8080 (behind the per-user subdomain ingress) and
# streams WebRTC media relayed through coturn so authenticated users reach it
# from anywhere. Upstream image, digest-pinned (house SHA rule).
NEKO_IMAGE = os.environ.get(
    "NEKO_IMAGE", "ghcr.io/m1k1o/neko/chromium:latest")
NEKO_PORT = int(os.environ.get("NEKO_PORT", "8080"))
# Fixed per-pod WebRTC media mux port — no cross-pod collision since each browser
# is in its own gluetun netns, and no per-user NodePort is needed (external reach
# is via the coturn relay candidate, not this host candidate).
NEKO_UDPMUX = int(os.environ.get("NEKO_UDPMUX", "59000"))
# Default virtual-desktop resolution. neko admins can change it LIVE from the UI
# (screen-size menu, any value via xrandr); higher = sharper but more x264 CPU +
# bandwidth (1080p ~1.2 cores, 1440p ~2-3, 4K ~4-5; no GPU encode here).
NEKO_SCREEN = os.environ.get("NEKO_SCREEN", "2560x1440@30")
# coturn: neko (in-cluster, gluetun netns whose DNS can't resolve cluster names)
# reaches coturn for its BACKEND relay allocation via an IP in gluetun's
# FIREWALL_OUTBOUND_SUBNETS (the LB IP, added there). The user's real browser
# reaches coturn's FRONTEND (STUN + TURN) via the public domain (WAN NAT). coturn
# advertises relay candidates on its external-ip=WAN either way.
COTURN_BACKEND_URL = os.environ.get("COTURN_BACKEND_URL", "turn:10.0.20.200:3478")
COTURN_FRONTEND_URL = os.environ.get("COTURN_FRONTEND_URL", "turn:turn.viktorbarzin.me:3478")
COTURN_STUN_URL = os.environ.get("COTURN_STUN_URL", "stun:turn.viktorbarzin.me:3478")
COTURN_REALM = os.environ.get("COTURN_REALM", "viktorbarzin.me")
# TURN-REST ephemeral cred (coturn use-auth-secret). The cred is embedded in the
# neko env at browser-creation time; a later client connection re-allocates with
# it, so the TTL must exceed the browser's lifetime. Browsers are persistent, so
# mint long (30d); a browser outliving the TTL needs a recreate to re-mint
# (reaper-driven in-place rotation is a follow-up — neko env is static).
TURN_SECRET = os.environ.get("TURN_SECRET", "")
TURN_TTL = int(os.environ.get("TURN_TTL", str(30 * 24 * 3600)))  # 30 days
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


def mint_turn_cred(name):
    """coturn use-auth-secret ephemeral credential (TURN REST API):
    username = "<unix-expiry>:<name>", password = base64(HMAC-SHA1(secret, username)).
    Returns (username, password); ("","") if no TURN_SECRET (relay disabled)."""
    if not TURN_SECRET:
        return "", ""
    username = "%d:%s" % (int(time.time()) + TURN_TTL, name)
    pwd = base64.b64encode(
        hmac.new(TURN_SECRET.encode(), username.encode(), hashlib.sha1).digest()
    ).decode()
    return username, pwd


def _gw_name(idx):
    return "proxy-gw-%d" % idx


def _br_name(userkey):
    return "proxy-br-" + userkey


def _pvc_name(userkey):
    return "proxy-profile-" + userkey


def _br_host(token):
    return "proxy-%s.%s" % (token, BASE_DOMAIN)


def _url(token):
    # Each browser gets its own subdomain so neko's WebSocket signaling + assets
    # resolve to that browser. The unguessable token IS the subdomain AND neko's
    # member password, so ?usr=proxy&pwd=<token> auto-connects with no prompt
    # (the token is already the subdomain — no new secret exposed). Rides the *
    # wildcard DNS + wildcard TLS. Entry is Authentik-gated upstream at the broker.
    return "https://%s/?usr=proxy&pwd=%s" % (_br_host(token), token)


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


def _neko_env(userkey, token):
    """neko v3 env. The token is the member ADMIN password (?pwd auto-login) — it's
    the owner's own single-user browser, so they get full control (change the live
    resolution, etc.); the user-role password is a derived locked value (unused).
    WebRTC media
    relays through coturn: BACKEND = coturn LB IP (neko in-cluster reaches it
    direct via gluetun FIREWALL_OUTBOUND_SUBNETS; the relay it gets is on coturn's
    external-ip=WAN), FRONTEND = coturn public domain + STUN for the user's
    browser. Ephemeral TURN-REST creds; FRONTEND always keeps STUN (an empty
    frontend makes Chrome emit an unresolvable mDNS candidate → no connection)."""
    u, p = mint_turn_cred(_br_name(userkey))
    ice_backend = []
    ice_frontend = [{"urls": [COTURN_STUN_URL]}]
    if u:
        ice_backend.append({"urls": [COTURN_BACKEND_URL], "username": u, "credential": p})
        ice_frontend.insert(0, {"urls": [COTURN_FRONTEND_URL], "username": u, "credential": p})
    locked_pw = hmac.new(TOKEN_SALT, (userkey + ":locked").encode(), hashlib.sha256).hexdigest()[:24]
    return [
        {"name": "NEKO_DESKTOP_SCREEN", "value": NEKO_SCREEN},
        {"name": "NEKO_MEMBER_PROVIDER", "value": "multiuser"},
        {"name": "NEKO_MEMBER_MULTIUSER_USER_PASSWORD", "value": locked_pw},
        {"name": "NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD", "value": token},
        {"name": "NEKO_SESSION_IMPLICIT_HOSTING", "value": "true"},
        {"name": "NEKO_SESSION_MERCIFUL_RECONNECT", "value": "true"},
        {"name": "NEKO_SERVER_BIND", "value": "0.0.0.0:%d" % NEKO_PORT},
        {"name": "NEKO_SERVER_PROXY", "value": "true"},
        {"name": "NEKO_WEBRTC_ICELITE", "value": "false"},
        {"name": "NEKO_WEBRTC_UDPMUX", "value": str(NEKO_UDPMUX)},
        {"name": "NEKO_WEBRTC_ICESERVERS_BACKEND", "value": json.dumps(ice_backend)},
        {"name": "NEKO_WEBRTC_ICESERVERS_FRONTEND", "value": json.dumps(ice_frontend)},
    ]


def build_br_pod(userkey, country, gw_idx, wg_ip, gw_pub, gw_endpoint_ip, pubkey, token):
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
            # neko runs as UID 1000 (its chromium uses --no-sandbox, so no setuid
            # sandbox / privileged needed); fsGroup 1000 owns the profile PVC.
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
                     # 8080 signaling (from Traefik) + the WebRTC media mux port.
                     {"name": "FIREWALL_INPUT_PORTS", "value": "%d,%d" % (NEKO_PORT, NEKO_UDPMUX)},
                     # Cluster CIDRs + the coturn LB IP so neko reaches coturn DIRECT
                     # (not through the NordVPN tunnel) for its relay allocation.
                     {"name": "FIREWALL_OUTBOUND_SUBNETS", "value": "10.10.0.0/16,10.96.0.0/12,10.0.20.200/32"},
                     {"name": "WIREGUARD_PRIVATE_KEY",
                      "valueFrom": {"secretKeyRef": {"name": _br_name(userkey) + "-wg",
                                                     "key": "WIREGUARD_PRIVATE_KEY"}}},
                 ],
                 "resources": {"requests": {"cpu": "20m", "memory": "80Mi"}, "limits": {"memory": "256Mi"}}},
                # neko: headful Chromium streamed via WebRTC (H.264 video + Opus
                # audio) — smooth video KasmVNC can't do. Signaling/UI on :8080
                # (behind the per-user subdomain ingress); media relays through
                # coturn so authenticated users reach it from anywhere. The token
                # is neko's member USER password (?usr=proxy&pwd=<token> auto-login).
                # Chromium profile persists on the PVC; a memory /dev/shm + the
                # infobar-suppressing managed policy are mounted in.
                {"name": "neko", "image": NEKO_IMAGE, "imagePullPolicy": "IfNotPresent",
                 "env": _neko_env(userkey, token),
                 "ports": [{"name": "http", "containerPort": NEKO_PORT},
                           {"name": "media", "containerPort": NEKO_UDPMUX, "protocol": "UDP"}],
                 "readinessProbe": {"tcpSocket": {"port": NEKO_PORT}, "initialDelaySeconds": 8,
                                    "periodSeconds": 3, "failureThreshold": 90},
                 "volumeMounts": [
                     {"name": "profile", "mountPath": "/home/neko/.config/chromium"},
                     {"name": "shm", "mountPath": "/dev/shm"},
                     {"name": "chrome-policy", "mountPath": "/etc/chromium/policies/managed", "readOnly": True}],
                 # ~2-3 cores while 1440p video plays (~0 idle) — request 1.5 so the
                 # scheduler reserves enough that the encoder isn't CFS-throttled
                 # under contention; no CPU limit (house policy) so it still bursts
                 # to the node's free cores. Mem 2.5Gi: neko + Chromium + memory shm.
                 "resources": {"requests": {"cpu": "1500m", "memory": "2560Mi"}, "limits": {"memory": "2560Mi"}}},
            ],
            # Spread browsers across the (node2-5) workers so several active-video
            # streams don't pile onto one node.
            "affinity": {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{
                "weight": 100, "podAffinityTerm": {"topologyKey": "kubernetes.io/hostname",
                    "labelSelector": {"matchLabels": {"app": "proxy-browser"}}}}]}},
            "volumes": [
                {"name": "profile", "persistentVolumeClaim": {"claimName": _pvc_name(userkey)}},
                {"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": "1Gi"}},
                {"name": "chrome-policy", "configMap": {"name": "proxy-chrome-policy"}}],
        },
    }


def build_br_service(userkey):
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": _br_name(userkey), "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey}},
            "spec": {"selector": {"proxy/user": userkey},
                     "ports": [{"name": "http", "port": NEKO_PORT, "targetPort": NEKO_PORT}]}}


def build_br_ingress(userkey, token):
    host = _br_host(token)
    return {"apiVersion": "networking.k8s.io/v1", "kind": "Ingress",
            "metadata": {"name": _br_name(userkey), "namespace": NS,
                         "labels": {"app": "proxy-browser", "proxy/user": userkey},
                         # No auth middleware: an Authentik forward-auth breaks the
                         # neko signaling WebSocket, so the unguessable per-user
                         # subdomain (+ the token as neko's member password) is the
                         # gate. Entry is Authentik-gated upstream at the broker UI.
                         "annotations": {
                             "traefik.ingress.kubernetes.io/router.entrypoints": "websecure"}},
            "spec": {"ingressClassName": "traefik",
                     "tls": [{"hosts": [host], "secretName": TLS_SECRET}],
                     "rules": [{"host": host, "http": {"paths": [{
                         "path": "/", "pathType": "Prefix",
                         "backend": {"service": {"name": _br_name(userkey), "port": {"number": NEKO_PORT}}}}]}}]}}


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
        body = build_br_pod(userkey, country, gw["idx"], wg_ip, gw["pubkey"], gw["endpoint_ip"], pub, token)
        for _ in range(30):   # wait out a terminating same-name pod (switch-country / recreate race)
            st, _ = k8s("POST", "/api/v1/namespaces/%s/pods" % NS, body)
            if st != 409:
                break
            time.sleep(1)
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
