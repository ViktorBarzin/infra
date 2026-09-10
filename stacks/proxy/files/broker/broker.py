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
  * Gateway index pool.PERMANENT_IDX is the always-on cluster VPN egress gateway
    (pool.PERMANENT_COUNTRY), declared in Terraform as a Deployment plus its
    Services and key Secret: the broker reuses it, keeps writing its peers
    ConfigMap, and never creates, reaps or deletes it. Because it is a Deployment,
    every gateway lookup here keys off the `proxy/gw-idx` LABEL — its pods carry
    generated name suffixes, so name-keyed calls would silently 404.
    Design: docs/plans/2026-08-16-cluster-vpn-egress-service-design.md

Peer wiring is ConfigMap-driven (the vpn-portal pattern, memory #9732): the
broker maintains a per-gateway peers ConfigMap; the gateway sidecar reconciles
wg0 from it, so peers survive a gateway restart and no `kubectl exec` is needed.
Pure stdlib on python:3.12-slim (ConfigMap-mounted, no custom image) — the
decision logic lives in pool.py, key generation in wgkeys.py (both unit-tested).
Design: docs/plans/2026-07-25-proxy-scale-design.md
"""
import base64
import datetime
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
# The NordLynx key is account-wide and rotates on multi-device login (memory
# #8307). The broker used to re-fetch it only at startup and on the gateway-create
# path — which the permanent gateway never takes — so the Deployment's
# `secret.reloader.stakater.com/reload: nordvpn-wg` annotation had nothing to
# react to. Re-fetching on a slow timer gives Reloader its trigger; an unchanged
# key is a no-op write (the apiserver skips identical updates), so a quiet account
# never restarts the gateway.
NORDVPN_KEY_REFRESH_SECONDS = int(os.environ.get("NORDVPN_KEY_REFRESH_SECONDS", "21600"))
# Re-home a browser whose gateway has vanished (delete the wedged pod, recreate it
# on a live gateway, profile PVC kept). Set to 0 to only surface them — the log
# line and the proxy_browsers_stranded gauge are emitted either way.
STRANDED_REHOME = os.environ.get("STRANDED_REHOME", "1") == "1"
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
# (screen-size menu, any value via xrandr). GPU/NVENC hardware-encodes it, so
# 1440p is smooth (~0.9 core, ~230 MiB VRAM); admins can push to 4K live.
NEKO_SCREEN = os.environ.get("NEKO_SCREEN", "2560x1440@30")
# GPU hardware-H.264 (NVENC) capture pipeline — offloads the encode from CPU x264
# (~4.4 cores at 1440p) to the T4 (~0.9 core). Verified end-to-end (memory #10279):
# the stock nvidia-chromium image runs once GLX is disabled in Xorg (initContainer
# below; we only need the GPU for encode, not render).
NEKO_GPU = os.environ.get("NEKO_GPU", "1") == "1"
NEKO_PIPELINE = os.environ.get(
    "NEKO_PIPELINE",
    "ximagesrc display-name={display} show-pointer=true use-damage=false "
    "! videoconvert ! queue ! video/x-raw,format=NV12 "
    "! nvh264enc name=encoder preset=2 gop-size=25 spatial-aq=true temporal-aq=true "
    "bitrate=8000 vbv-buffer-size=8000 rc-mode=6 "
    "! h264parse config-interval=-1 ! video/x-h264,stream-format=byte-stream ! appsink name=appsink")
# per-browser T4 VRAM budget slot (measured ~311 MiB actual). 384 fits the current
# ~400 MiB free budget without a gpumem_total_mib bump; a 2nd GPU browser needs the
# budget raised (stacks/nvidia gpumem_total_mib) or a smaller per-slot value.
GPUMEM_MIB = os.environ.get("GPUMEM_MIB", "384")
# The shared T4 fits ~1 proxy browser alongside the other GPU tenants. A new
# browser beyond this cap is rejected up-front (clean "at capacity") so it never
# creates a WaitForFirstConsumer PVC that can't schedule (-> PVCStuckPending).
# Bump if the GPU budget frees up. The reaper is the backstop either way.
GPU_BROWSERS_MAX = int(os.environ.get("GPU_BROWSERS_MAX", "1"))
# coturn: neko (in-cluster, gluetun netns whose DNS can't resolve cluster names)
# reaches coturn for its BACKEND relay allocation via an IP in gluetun's
# FIREWALL_OUTBOUND_SUBNETS (the LB IP, added there). The user's real browser
# reaches coturn's FRONTEND (STUN + TURN) via the public domain (WAN NAT). coturn
# advertises relay candidates on its external-ip=WAN either way.
COTURN_BACKEND_URL = os.environ.get("COTURN_BACKEND_URL", "turn:10.0.20.205:3478")
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
# Serialises capacity-check + create (TOCTOU). Re-entrant because the reaper's
# re-home path holds it across ensure_gateway() AND the create_browser() that
# follows — create_browser takes the same lock, and a plain Lock would deadlock
# the reaper thread on itself. Every other caller behaves exactly as before.
_lock = threading.RLock()
_stranded_browsers = 0    # last reaper tick's count, exported on /metrics


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
    if st != 409:
        return st, resp
    st, resp = k8s("PUT", kind_path + "/" + name, body)
    if st == 422:
        # A full replace is rejected when it would clear an immutable field — a
        # Service's spec.clusterIP, which these bodies deliberately never carry.
        # Without this fallback an EXISTING Service silently keeps its old spec,
        # so e.g. the gateway selector fix would only ever reach freshly created
        # Services. A merge patch touches only the keys we send (ownerReferences
        # included, since they are absent from the body).
        st, resp = k8s("PATCH", kind_path + "/" + name, body,
                       content_type="application/merge-patch+json")
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
    # The selector MUST include app=proxy-gateway: browser pods carry the same
    # proxy/gw-idx label (build_br_pod), so selecting on the index alone puts a
    # browser behind its own gateway's ClusterIP. Live, that made a browser dial
    # ITSELF on :51820 for four days while the Service still looked healthy —
    # one endpoint, just the wrong pod, so no "service has no endpoints" check fired.
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": _gw_name(idx), "namespace": NS,
                         "labels": {"app": "proxy-gateway", "proxy/gw-idx": str(idx)}},
            "spec": {"selector": {"app": "proxy-gateway", "proxy/gw-idx": str(idx)},
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
    env = [
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
    if NEKO_GPU:
        env += [
            {"name": "NEKO_CAPTURE_VIDEO_CODEC", "value": "h264"},
            {"name": "NEKO_CAPTURE_VIDEO_PIPELINE", "value": NEKO_PIPELINE},
            {"name": "NVIDIA_VISIBLE_DEVICES", "value": "all"},
            {"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "all"},
        ]
    return env


def build_br_pod(userkey, country, gw_idx, wg_ip, gw_pub, gw_endpoint_ip, pubkey, token, owner=""):
    neko_mounts = [
        {"name": "profile", "mountPath": "/home/neko/.config/chromium"},
        {"name": "shm", "mountPath": "/dev/shm"},
        {"name": "chrome-policy", "mountPath": "/etc/chromium/policies/managed", "readOnly": True},
        # visit tracking (spec infra#83): source a one-line /etc/chromium.d file
        # that appends --remote-debugging-port=9222 so the visit-collector
        # sidecar can read page navigations over CDP on loopback.
        {"name": "visit-collector", "mountPath": "/etc/chromium.d/50-remote-debug",
         "subPath": "50-remote-debug", "readOnly": True}]
    volumes = [
        {"name": "profile", "persistentVolumeClaim": {"claimName": _pvc_name(userkey)}},
        {"name": "shm", "emptyDir": {"medium": "Memory", "sizeLimit": "1Gi"}},
        {"name": "chrome-policy", "configMap": {"name": "proxy-chrome-policy"}},
        {"name": "visit-collector", "configMap": {"name": "proxy-visit-collector"}}]
    init_containers = []
    # Software x264 default: ~1.2 cores at 1080p (bursts, no CPU limit). Spread
    # browsers across the node2-5 workers.
    neko_resources = {"requests": {"cpu": "1", "memory": "2560Mi"}, "limits": {"memory": "2560Mi"}}
    placement = {"affinity": {"podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{
        "weight": 100, "podAffinityTerm": {"topologyKey": "kubernetes.io/hostname",
            "labelSelector": {"matchLabels": {"app": "proxy-browser"}}}}]}}}
    if NEKO_GPU:
        # NVENC hardware encode on the T4 (memory #10279): pin to the GPU node with
        # a time-sliced GPU slice + a gpumem budget slot, and fix the stock nvidia
        # image's Xorg crash via an initContainer that prepends a GLX-disabling
        # Module section to /etc/neko/xorg.conf (we only need the GPU for ENCODE).
        init_containers = [{
            "name": "xorg-glx-fix", "image": NEKO_IMAGE, "imagePullPolicy": "IfNotPresent",
            "command": ["sh", "-c",
                        'printf \'Section "Module"\\n  Disable "glx"\\nEndSection\\n\' '
                        '| cat - /etc/neko/xorg.conf > /xorg/xorg.conf'],
            "volumeMounts": [{"name": "xorg", "mountPath": "/xorg"}],
            "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"memory": "64Mi"}}}]
        neko_mounts.append({"name": "xorg", "mountPath": "/etc/neko/xorg.conf", "subPath": "xorg.conf"})
        volumes.append({"name": "xorg", "emptyDir": {}})
        neko_resources = {
            "requests": {"cpu": "1", "memory": "3584Mi",
                         "nvidia.com/gpu": "1", "viktorbarzin.me/gpumem": GPUMEM_MIB},
            "limits": {"memory": "3584Mi",
                       "nvidia.com/gpu": "1", "viktorbarzin.me/gpumem": GPUMEM_MIB}}
        placement = {"nodeSelector": {"nvidia.com/gpu.present": "true"},
                     "tolerations": [{"key": "nvidia.com/gpu", "operator": "Equal",
                                      "value": "true", "effect": "NoSchedule"}]}
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": _br_name(userkey), "namespace": NS,
                     "labels": {"app": "proxy-browser", "proxy/user": userkey,
                                "proxy/gw-idx": str(gw_idx), "proxy/country": _label(country)},
                     "annotations": {"proxy/country-name": country, "proxy/wg-pub": pubkey,
                                     "proxy/wg-ip": wg_ip, "proxy/token": token, "proxy/owner": owner,
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
                     {"name": "FIREWALL_OUTBOUND_SUBNETS", "value": "10.10.0.0/16,10.96.0.0/12,10.0.20.205/32"},
                     {"name": "WIREGUARD_PRIVATE_KEY",
                      "valueFrom": {"secretKeyRef": {"name": _br_name(userkey) + "-wg",
                                                     "key": "WIREGUARD_PRIVATE_KEY"}}},
                 ],
                 "resources": {"requests": {"cpu": "20m", "memory": "80Mi"}, "limits": {"memory": "256Mi"}}},
                # neko: headful Chromium streamed via WebRTC (H.264 video + Opus
                # audio) — smooth video KasmVNC can't do. Signaling/UI on :8080
                # (behind the per-user subdomain ingress); media relays through
                # coturn so authenticated users reach it from anywhere. The token
                # is neko's member ADMIN password (?usr=proxy&pwd=<token> auto-login).
                # Chromium profile persists on the PVC; a memory /dev/shm + the
                # infobar-suppressing managed policy are mounted in. On GPU (below)
                # the video is NVENC-hardware-encoded on the T4.
                {"name": "neko", "image": NEKO_IMAGE, "imagePullPolicy": "IfNotPresent",
                 "env": _neko_env(userkey, token),
                 "ports": [{"name": "http", "containerPort": NEKO_PORT},
                           {"name": "media", "containerPort": NEKO_UDPMUX, "protocol": "UDP"}],
                 "readinessProbe": {"tcpSocket": {"port": NEKO_PORT}, "initialDelaySeconds": 8,
                                    "periodSeconds": 3, "failureThreshold": 90},
                 "volumeMounts": neko_mounts,
                 "resources": neko_resources},
                # visit-collector (spec infra#83): reads Chromium's CDP on
                # loopback (shared pod netns) and logs page visits (URL + title)
                # to stdout -> Alloy -> Loki, attributed to this user by the pod
                # name. Observe-only; never touches the egress/traffic path.
                {"name": "visit-collector",
                 "image": "docker.io/library/python:3.12-alpine",
                 "imagePullPolicy": "IfNotPresent",
                 "command": ["python3", "/app/visit_collector.py"],
                 "env": [{"name": "PROXY_USER", "value": owner},
                         {"name": "CDP_URL", "value": "http://127.0.0.1:9222"}],
                 "volumeMounts": [{"name": "visit-collector",
                                   "mountPath": "/app/visit_collector.py",
                                   "subPath": "visit_collector.py", "readOnly": True}],
                 "resources": {"requests": {"cpu": "10m", "memory": "32Mi"},
                               "limits": {"memory": "96Mi"}}},
            ],
            "initContainers": init_containers,
            "volumes": volumes,
            **placement,
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


def _idx_label(obj):
    """Gateway index from the proxy/gw-idx LABEL, or None if absent/unparseable.

    Every gateway lookup keys off this label rather than the object name: the
    permanent gateway is a Deployment, so its pod is `proxy-gw-1-<rs>-<suffix>`
    and any name-keyed pod call would silently 404. A bare dict index here used to
    take down the whole reaper tick (and every create_browser) with a KeyError if
    a pod carried app=proxy-gateway without the index label.
    """
    raw = (obj.get("metadata", {}).get("labels") or {}).get("proxy/gw-idx")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def list_gateways():
    out = []
    for p in _list("pods", "app=proxy-gateway"):
        md = p.get("metadata", {})
        if md.get("deletionTimestamp"):
            continue
        idx = _idx_label(p)
        if idx is None:
            print("gateway pod %s has no usable proxy/gw-idx label — ignored"
                  % md.get("name"), flush=True)
            continue
        an = md.get("annotations", {})
        out.append({"idx": idx, "name": md.get("name"),
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
                    # the login the browser was created for — the reaper needs it
                    # to recreate a stranded browser under the same userkey/URL
                    "owner": an.get("proxy/owner", ""),
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


def _gw_pods(idx):
    """Live gateway pods for `idx`, resolved from the LABEL, not the object name.

    The permanent gateway is a Deployment, so its pod is `proxy-gw-1-<rs>-<sfx>`
    and any name-keyed pod call silently 404s.
    """
    return [p for p in _list("pods", "app=proxy-gateway,proxy/gw-idx=%d" % idx)
            if not (p.get("metadata") or {}).get("deletionTimestamp")]


def _gw_pod_names(idx):
    """Live pod names for gateway `idx`."""
    return [n for n in ((p.get("metadata") or {}).get("name") for p in _gw_pods(idx)) if n]


def _gw_pod_ready(idx):
    """True when gateway `idx` has a pod that is Running with all containers Ready.

    Used to gate the PERMANENT gateway's reuse path. Its identity comes from
    Terraform rather than from a listed pod, so `plan_gateway` answers "reuse"
    for its country whether or not the pod exists — deliberately, since falling
    through to "create" during a rollout would open a SECOND tunnel to the same
    country on the account-wide NordLynx key. The consequence is that everything
    else `ensure_gateway` checks (the wg Secret, the Service's ClusterIP) exists
    independently of the pod, so a gateway that is scaled to zero, unschedulable
    or stuck in a NordVPN cooldown would still look complete and a browser wired
    to it would dial a VIP with no endpoint behind it. This is the check that
    distinguishes "momentarily absent" from "not running", so the request fails
    with a retryable message instead.
    """
    for p in _gw_pods(idx):
        st = p.get("status", {})
        cs = st.get("containerStatuses", [])
        if st.get("phase") == "Running" and cs and all(c.get("ready") for c in cs):
            return True
    return False


def _touch_gw(idx):
    for name in _gw_pod_names(idx):
        k8s("PATCH", "/api/v1/namespaces/%s/pods/%s" % (NS, name),
            {"metadata": {"annotations": {"proxy/last-used": str(int(time.time()))}}},
            content_type="application/merge-patch+json")


def _stamp_gw_last_used_if_absent(idx):
    """Give a gateway pod a `proxy/last-used` annotation if it has none — once.

    The permanent gateway is a Deployment and its pod template deliberately
    carries no timestamp (a literal one in a template is stale the moment it is
    written, and generating one per apply would roll the tunnel on every apply).
    This broker never reads it for PERMANENT_IDX — `plan_reaping` skips that index
    outright — but a broker build that predates PERMANENT_IDX reads a missing
    annotation as `0`, i.e. idle since the epoch, and its `delete_gateway` would
    strip the Service, peers ConfigMap and WireGuard Secret out from under a
    running pod. Terraform orders the broker rollout ahead of this Deployment
    (see the checksum annotation in main.tf), so no such broker should be alive
    when the pod appears; stamping the annotation once is the cheap second line
    of defence — one write per gateway pod, nothing recurring.
    """
    for p in _gw_pods(idx):
        md = p.get("metadata", {})
        if (md.get("annotations") or {}).get("proxy/last-used"):
            continue
        name = md.get("name")
        if not name:
            continue
        k8s("PATCH", "/api/v1/namespaces/%s/pods/%s" % (NS, name),
            {"metadata": {"annotations": {"proxy/last-used": str(int(time.time()))}}},
            content_type="application/merge-patch+json")
        print("stamped proxy/last-used on gateway pod %s" % name, flush=True)


def _gw_pubkey_from_secret(idx):
    """Derive the gateway's WireGuard public key from its private-key Secret.

    The pod annotation is the usual source, but the permanent gateway is a
    Deployment: during a rollout no pod is listed while a browser still needs its
    public key to build a working peer. The Secret is the same file the wg-server
    sidecar loads into wg0 (`wg set wg0 private-key /gw-wg/privkey`), so a key
    derived from it cannot disagree with what the gateway actually holds.
    """
    st, sec = k8s("GET", "/api/v1/namespaces/%s/secrets/%s-wg" % (NS, _gw_name(idx)))
    if st != 200:
        return None
    b64 = (sec.get("data") or {}).get("privkey")
    if not b64:
        return None
    try:
        return wgkeys.public_from_private(base64.b64decode(b64).decode().strip())
    except Exception as e:
        print("gateway %d: cannot derive public key from its Secret: %s" % (idx, e), flush=True)
        return None


def ensure_permanent_gateway_secret():
    """Create the permanent gateway's WireGuard server-key Secret IF IT IS ABSENT.

    Terraform declares that gateway's Deployment and Services but cannot generate
    an X25519 keypair, and the only code that ever wrote `proxy-gw-1-wg` was
    `ensure_gateway`'s create branch — which is now refused for the permanent
    index (and unreachable anyway, since plan_gateway never returns "create" for
    its country). Today the Secret survives only as a leftover from the retired
    on-demand gateway at that index. On a fresh cluster, a namespace rebuild, a DR
    restore, or after anyone tidies up "the old gateway", the pod would sit in
    ContainerCreating forever (the volume is deliberately non-optional) and every
    request for that country would fail with "no WireGuard key available", with no
    code path able to recover it. This closes that gap.

    CREATE-ONLY, never replace: the wg-server sidecar reads /gw-wg/privkey once at
    container start, so writing a new key under a running pod would leave browsers
    handing out a public key the gateway no longer holds — handshakes then fail
    silently on both sides. A 409 (another broker replica won the race) is success.

    Returns True only when this call created the Secret.
    """
    idx = pool.PERMANENT_IDX
    name = "%s-wg" % _gw_name(idx)
    st, _ = k8s("GET", "/api/v1/namespaces/%s/secrets/%s" % (NS, name))
    if st == 200:
        return False
    if st != 404:
        raise RuntimeError("cannot read Secret %s (HTTP %s)" % (name, st))
    priv, _pub = wgkeys.genkeypair()
    st, resp = k8s("POST", "/api/v1/namespaces/%s/secrets" % NS, build_gw_secret(idx, priv))
    if st == 409:
        return False
    if st not in (200, 201):
        raise RuntimeError("cannot create Secret %s (HTTP %s): %s" % (
            name, st, (resp or {}).get("message", "")))
    print("created permanent gateway key Secret %s (was absent)" % name, flush=True)
    return True


def _create_gw_pod(idx, country, pubkey):
    """POST the gateway pod and CHECK the result; returns the created object.

    The POST used to be fire-and-forget, so a 409 against a same-name pod still
    Terminating from a reap was discarded and ensure_gateway happily returned a
    {idx, pubkey, endpoint_ip} for a gateway that did not exist — which
    create_browser then baked into a browser's immutable gluetun env. The retry
    mirrors the browser path (which has always had it) and any other non-2xx now
    surfaces as a 409/500 to the caller instead of a phantom gateway.
    """
    body = build_gw_pod(idx, country, pubkey)
    st, resp = 0, {}
    for _ in range(30):
        st, resp = k8s("POST", "/api/v1/namespaces/%s/pods" % NS, body)
        if st != 409:
            break
        time.sleep(1)
    if st not in (200, 201, 202):
        raise RuntimeError("gateway %d pod create failed (HTTP %s): %s" % (
            idx, st, (resp or {}).get("message", "")))
    return resp


def _own_gateway_objects(idx, pod):
    """Make the gateway Pod the OWNER of its Service, peers ConfigMap and Secret.

    Those three carried no ownerReferences, and delete_gateway issues four
    independent DELETEs — so one transient apiserver error mid-sequence stranded
    whatever came after it, permanently invisible (every broker read starts from
    the gateway POD). With the pod as owner, kube's garbage collector removes the
    whole set the moment the pod goes, whatever happens to the broker.

    blockOwnerDeletion stays false: setting it needs `delete` on pods/finalizers,
    which the broker's Role deliberately does not grant.
    """
    if idx == pool.PERMANENT_IDX:
        return                                  # Terraform owns the permanent set
    uid = (pod.get("metadata") or {}).get("uid")
    if not uid:
        return
    patch = {"metadata": {"ownerReferences": [
        {"apiVersion": "v1", "kind": "Pod", "name": _gw_name(idx), "uid": uid,
         "controller": False, "blockOwnerDeletion": False}]}}
    for path in ("services/%s" % _gw_name(idx),
                 "configmaps/%s-peers" % _gw_name(idx),
                 "secrets/%s-wg" % _gw_name(idx)):
        k8s("PATCH", "/api/v1/namespaces/%s/%s" % (NS, path), patch,
            content_type="application/merge-patch+json")


def ensure_gateway(country):
    """Return {idx, pubkey, endpoint_ip} for `country`, creating the gateway if
    absent. Raises RuntimeError at the concurrent-country cap, or when the
    gateway is not usable yet (no Ready pod at the permanent index, no key, no
    ClusterIP) — a browser wired to half a gateway looks alive and never connects.

    Callers hold `_lock` across this and the create that follows: it serialises
    the capacity-check-then-allocate sequence, which is not safe to run twice
    concurrently (both sides would pick the same lowest-free index).
    """
    gateways = list_gateways()
    action, payload = pool.plan_gateway(country, gateways)
    if action == "reject":
        raise RuntimeError(payload["reason"])
    idx = payload["idx"]
    if action == "reuse":
        # The permanent gateway is reused BY COUNTRY, not by listing (pool.py
        # short-circuits it so a rollout can never start a second tunnel to the
        # same country). Everything else below then reads objects that outlive the
        # pod — the wg Secret and the Terraform-owned Service's ClusterIP — so
        # without this check a gateway that is scaled to zero, unschedulable, or
        # in a NordVPN over-limit cooldown would still return a complete-looking
        # {idx, pubkey, endpoint_ip} and the caller would bake it into a browser's
        # immutable gluetun env: a Running pod, a loading UI and no internet, with
        # no self-healing (plan_stranded_browsers treats this index as always
        # serving its country, and a user's retry is a no-op for a Running pod).
        # Fail closed with a retryable message instead; a rollout clears in
        # seconds, and a genuinely down gateway is what VPNEgressGatewayDown is for.
        if idx == pool.PERMANENT_IDX and not _gw_pod_ready(idx):
            raise RuntimeError(
                "gateway %d (%s) is not ready yet — the permanent gateway has no "
                "Ready pod (rolling out, or its tunnel is down); try again shortly"
                % (idx, country))
        _touch_gw(idx)
        gw = next((g for g in gateways if g["idx"] == idx), None)
        # The permanent gateway is reused by country, not by listing — its pod is
        # absent during any rollout, so fall back to the Secret for its key.
        pubkey = (gw or {}).get("pubkey") or _gw_pubkey_from_secret(idx)
        if not pubkey:
            raise RuntimeError(
                "gateway %d (%s) is not ready yet — no WireGuard key available"
                % (idx, country))
        endpoint_ip = _gw_endpoint_ip(idx)
        if not endpoint_ip:
            raise RuntimeError(
                "gateway %d (%s) is not ready yet — Service %s has no ClusterIP"
                % (idx, country, _gw_name(idx)))
        return {"idx": idx, "pubkey": pubkey, "endpoint_ip": endpoint_ip}
    if idx == pool.PERMANENT_IDX:
        # Unreachable via plan_gateway (it short-circuits the permanent country to
        # reuse); kept as the last guard before we would PUT-replace the
        # Terraform-declared Service and blank the peers ConfigMap.
        raise RuntimeError("refusing to create gateway %d — reserved for the "
                           "permanent Terraform-declared gateway" % idx)
    priv, pub = wgkeys.genkeypair()
    ensure_nordvpn_secret()
    _apply("/api/v1/namespaces/%s/secrets" % NS, _gw_name(idx) + "-wg", build_gw_secret(idx, priv))
    _apply("/api/v1/namespaces/%s/configmaps" % NS, _gw_name(idx) + "-peers", build_gw_peers_cm(idx, "\n"))
    _apply("/api/v1/namespaces/%s/services" % NS, _gw_name(idx), build_gw_service(idx))
    _own_gateway_objects(idx, _create_gw_pod(idx, country, pub))
    endpoint_ip = _gw_endpoint_ip(idx)
    if not endpoint_ip:
        raise RuntimeError("gateway %d: Service %s has no ClusterIP" % (idx, _gw_name(idx)))
    return {"idx": idx, "pubkey": pub, "endpoint_ip": endpoint_ip}


def delete_gateway(idx):
    """Delete a gateway pod and its Service / peers ConfigMap / wg Secret.

    Refuses the permanent index independently of plan_reaping: those two are pure
    logic, this is the destructive edge. The broker's Role grants no access to
    Deployments, so a stray delete here could not remove the permanent gateway
    itself — it would strip the Service, peers and key out from under a running
    pod, which is worse.
    """
    if idx == pool.PERMANENT_IDX:
        print("refusing to delete gateway %d — permanent, Terraform-owned" % idx, flush=True)
        return
    for name in _gw_pod_names(idx) or [_gw_name(idx)]:
        k8s("DELETE", "/api/v1/namespaces/%s/pods/%s" % (NS, name))
    k8s("DELETE", "/api/v1/namespaces/%s/services/%s" % (NS, _gw_name(idx)))
    k8s("DELETE", "/api/v1/namespaces/%s/configmaps/%s-peers" % (NS, _gw_name(idx)))
    k8s("DELETE", "/api/v1/namespaces/%s/secrets/%s-wg" % (NS, _gw_name(idx)))


# ------------------------------------------------------------------ browser lifecycle
def browser_for(userkey):
    for b in list_browsers():
        if b["userkey"] == userkey:
            return b
    return None


def create_browser(user, country, force=False):
    """Create (or recreate) this user's browser and return its URL.

    `force` recreates even when a live browser for the same country already
    exists — the reaper's re-home path, where the pod is Running but wired to a
    gateway that can no longer carry it, so the usual early return would make the
    re-home a no-op.
    """
    if country not in COUNTRIES:
        raise ValueError("unknown country")
    userkey = _userkey(user)
    token = _token(userkey)
    with _lock:
        existing = browser_for(userkey)
        if existing and not force and existing["country"] == country and not existing["dead"]:
            return {"country": country, "url": _url(token), "token": token}
        if not existing and NEKO_GPU and len(
                [b for b in list_browsers() if not b.get("dead")]) >= GPU_BROWSERS_MAX:
            # Brand-new browser but the GPU browser slot(s) are taken: reject
            # cleanly instead of creating a PVC+pod that can't schedule. A
            # WaitForFirstConsumer PVC whose pod never schedules sits Pending and
            # fires PVCStuckPending at 10m (infra#83 follow-up). Retry when free.
            raise RuntimeError("at capacity — the browser GPU is fully in use; try again in a few minutes")
        # Resolve the gateway BEFORE touching the user's existing pod. This used
        # to run after the delete, so a country-tunnel rejection (or a gateway
        # that is not ready) destroyed the browser they had and then failed,
        # leaving them with nothing until they noticed and retried.
        gw = ensure_gateway(country)
        if existing:                      # switching country / recovering / re-homing
            _delete_browser_pod(userkey)  # keep the PVC (reuses this user's slot)
        used_ips = [b["wg_ip"] for b in list_browsers() if b["gateway_idx"] == gw["idx"] and b["wg_ip"]]
        wg_ip = pool.alloc_client_ip(gw["idx"], used_ips)
        priv, pub = wgkeys.genkeypair()
        _apply("/api/v1/namespaces/%s/persistentvolumeclaims" % NS, _pvc_name(userkey), build_pvc(userkey))
        _apply("/api/v1/namespaces/%s/secrets" % NS, _br_name(userkey) + "-wg", build_br_secret(userkey, priv))
        body = build_br_pod(userkey, country, gw["idx"], wg_ip, gw["pubkey"], gw["endpoint_ip"], pub, token, owner=user)
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


def _ts(iso):
    """RFC3339 timestamp -> epoch seconds; 0 on failure."""
    if not iso:
        return 0.0
    try:
        return datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def _reap_orphan_pvcs():
    """Remove profile PVCs stuck Pending. A browser pod that can't schedule leaves
    its WaitForFirstConsumer PVC unbound (Pending), which fires PVCStuckPending at
    10m. After a 5-min grace (a schedulable browser binds in seconds) we delete the
    stuck pod + the unbound PVC. BOUND PVCs hold the user's Chromium profile and
    are NEVER touched — an unbound PVC has never been written, so this is
    data-safe. Belt-and-suspenders behind the create-time capacity check."""
    now = time.time()
    for pvc in _list("persistentvolumeclaims", "app=proxy-browser"):
        md = pvc.get("metadata", {})
        if pvc.get("status", {}).get("phase") != "Pending":
            continue
        if now - _ts(md.get("creationTimestamp")) < 300:
            continue
        userkey = md.get("labels", {}).get("proxy/user", "")
        if userkey:
            k8s("DELETE", "/api/v1/namespaces/%s/pods/%s" % (NS, _br_name(userkey)))
        k8s("DELETE", "/api/v1/namespaces/%s/persistentvolumeclaims/%s" % (NS, md.get("name")))
        print("reaped stuck Pending profile PVC:", md.get("name"), flush=True)


def _reap_orphan_browser_routing(state):
    """Delete Service+Ingress+wg-secret left behind by a browser pod that vanished.

    plan_reaping() only reaps browsers it can still SEE as pods, so a pod removed
    outside delete_browser (eviction, node drain, GC of a Failed pod) strands its
    routing objects: the hostname 503s and the auto-discovered external monitor
    goes red until someone notices (one pair sat that way for 13 days). The
    profile PVC is deliberately untouched — it holds the user's Chromium profile
    and is reused when they next open a browser.
    """
    live = {md.get("name") for md in
            (p.get("metadata", {}) for p in _list("pods", "app=proxy-browser"))
            if md.get("name")}
    routes = []
    for svc in _list("services", "app=proxy-browser"):
        md = svc.get("metadata", {})
        userkey = md.get("labels", {}).get("proxy/user")
        if userkey and md.get("name"):
            routes.append({"userkey": userkey, "name": md["name"]})
    orphans, new_state = pool.plan_orphan_routing_reaping(routes, live, state)
    for userkey in orphans:
        name = _br_name(userkey)
        k8s("DELETE", "/apis/networking.k8s.io/v1/namespaces/%s/ingresses/%s" % (NS, name))
        k8s("DELETE", "/api/v1/namespaces/%s/services/%s" % (NS, name))
        k8s("DELETE", "/api/v1/namespaces/%s/secrets/%s-wg" % (NS, name))
        new_state.pop(userkey, None)
        print("reaped orphaned browser routing (pod gone):", name, flush=True)
    return new_state


def _reap_orphan_gateways(state):
    """Delete a gateway's Service + peers ConfigMap + wg Secret when its pod is gone.

    The gateway-side mirror of _reap_orphan_browser_routing, and the backstop
    behind the ownerReferences stamped in _own_gateway_objects (which only cover
    gateways created since). Without it, a delete_gateway interrupted mid-sequence
    leaves objects that NOTHING can ever see again — every broker read starts from
    the gateway pod — so the Service keeps a ClusterIP that browsers dial into a
    black hole. That is the four-day outage this fixes.
    """
    live = {g["idx"] for g in list_gateways()}
    found = set()
    for kind in ("services", "configmaps", "secrets"):
        for obj in _list(kind, "app=proxy-gateway"):
            idx = _idx_label(obj)
            if idx is not None:
                found.add(idx)
    orphans, new_state = pool.plan_orphan_gateway_reaping(sorted(found), live, state)
    for idx in orphans:
        delete_gateway(idx)
        new_state.pop(idx, None)
        print("reaped orphaned gateway objects (pod gone): idx", idx, flush=True)
    return new_state


def _rehome_stranded_browsers(browsers, gateways, state):
    """Recreate browsers whose gateway has vanished (or now serves another country).

    plan_reaping has no case for this: it walks gateways, so a browser pointing at
    nothing is invisible to it, and the user's own retry is a no-op too
    (create_browser returns early for a Running pod). The browser therefore
    reconnects to a dead ClusterIP indefinitely — observed for four days.

    The gateway is confirmed to exist BEFORE the wedged pod is deleted, so a
    capacity rejection leaves the user's browser exactly where it was. The profile
    PVC is kept, and the token (hence the URL) is derived from the userkey, so a
    re-home is invisible to the user beyond a restart.

    The whole ensure-then-recreate runs under `_lock`, the same lock create_browser
    takes: it exists to serialise the capacity-check-then-create sequence, and a
    reaper tick racing an HTTP create would otherwise have both sides allocate the
    SAME lowest-free gateway index — the loser's Secret PUT-replacing the winner's
    keypair while the winner's wgserver has already loaded the old key, so every
    browser wired from that Secret handshakes into silence.
    """
    global _stranded_browsers
    stranded, new_state = pool.plan_stranded_browsers(
        [{"id": b["userkey"], "gateway_idx": b["gateway_idx"],
          "country": b["country"], "dead": b["dead"]} for b in browsers],
        [{"idx": g["idx"], "country": g["country"]} for g in gateways], state)
    _stranded_browsers = len(stranded)
    by_key = {b["userkey"]: b for b in browsers}
    for userkey in stranded:
        b = by_key.get(userkey, {})
        owner, country = b.get("owner") or "", b.get("country")
        print("stranded browser %s: gateway idx %s no longer serves %s"
              % (userkey, b.get("gateway_idx"), country), flush=True)
        if not STRANDED_REHOME:
            continue
        if not country or not owner or _userkey(owner) != userkey:
            print("  not re-homing %s automatically: no usable proxy/owner "
                  "annotation to recreate it under" % userkey, flush=True)
            continue
        with _lock:
            try:
                ensure_gateway(country)   # fail here and the wedged pod is untouched
            except Exception as e:
                print("  cannot re-home %s yet: %s" % (userkey, e), flush=True)
                continue
            try:
                # force=True: the pod is Running and already carries this country,
                # so the ordinary early return would make the re-home a no-op.
                # create_browser deletes the old pod itself, AFTER it has a usable
                # gateway in hand and while still holding this lock — the profile
                # PVC survives and there is no window with the user left podless.
                create_browser(owner, country, force=True)
                new_state.pop(userkey, None)
                print("  re-homed %s onto a live %s gateway" % (userkey, country), flush=True)
            except Exception as e:
                print("  re-home of %s failed: %s" % (userkey, e), flush=True)
    return new_state


# ------------------------------------------------------------------ reaper
def reaper():
    orphan_routing_state = {}
    orphan_gateway_state = {}
    stranded_state = {}
    last_key_refresh = time.time()        # main() has just fetched it
    while True:
        try:
            # Self-heals a permanent gateway whose key Secret is missing (fresh
            # cluster / DR restore / manual cleanup): without it the pod never
            # leaves ContainerCreating and nothing in the system can recover.
            ensure_permanent_gateway_secret()
            # One-shot per pod; closes the window in which a broker older than
            # PERMANENT_IDX would read the annotation-less pod as idle forever.
            _stamp_gw_last_used_if_absent(pool.PERMANENT_IDX)
        except Exception as e:
            print("permanent-gateway upkeep error:", e, flush=True)
        try:
            _reap_orphan_pvcs()
        except Exception as e:
            print("orphan-pvc reap error:", e, flush=True)
        try:
            orphan_routing_state = _reap_orphan_browser_routing(orphan_routing_state)
        except Exception as e:
            print("orphan-routing reap error:", e, flush=True)
        try:
            orphan_gateway_state = _reap_orphan_gateways(orphan_gateway_state)
        except Exception as e:
            print("orphan-gateway reap error:", e, flush=True)
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
            # Re-assert peers (recovers a gateway restart), then reap the idle ones.
            # The permanent gateway is added unconditionally: it still serves
            # browsers over WireGuard, and driving this off the listed pods alone
            # would skip it on every tick of a Deployment rollout.
            keep = {g["idx"] for g in gateways if g["idx"] not in dead_gws}
            keep.add(pool.PERMANENT_IDX)
            for idx in sorted(keep):
                update_gw_peers(idx)
            for idx in dead_gws:
                delete_gateway(idx)
            stranded_state = _rehome_stranded_browsers(browsers, gateways, stranded_state)
        except Exception as e:
            print("reaper error:", e, flush=True)
        if time.time() - last_key_refresh >= NORDVPN_KEY_REFRESH_SECONDS:
            # Gives the gateway Deployment's Reloader annotation something to fire
            # on when the account-wide NordLynx key rotates; a no-op otherwise.
            try:
                ensure_nordvpn_secret()
                last_key_refresh = time.time()
            except Exception as e:
                print("nordvpn key refresh error:", e, flush=True)
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
                    "# HELP proxy_browsers_stranded Browsers whose gateway is gone "
                    "or now serves another country\n"
                    "# TYPE proxy_browsers_stranded gauge\nproxy_browsers_stranded %d\n"
                    "# HELP proxy_max_countries Concurrent-country ceiling\n"
                    "# TYPE proxy_max_countries gauge\nproxy_max_countries %d\n"
                    % (g, b, _stranded_browsers, pool.MAX_COUNTRIES - pool.RESERVED_SLOTS))
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
    try:
        ensure_permanent_gateway_secret()
        print("startup: permanent gateway key present", flush=True)
    except Exception as e:
        # Not fatal: the reaper retries every tick, and the gateway pod stays in
        # ContainerCreating (visible as PodStuckPending) until it lands.
        print("startup: ensure_permanent_gateway_secret failed (reaper will retry):", e, flush=True)
    threading.Thread(target=reaper, daemon=True).start()
    print("proxy-broker on :%d (ns=%s host=%s max_countries=%d)" % (
        PORT, NS, HOST, pool.MAX_COUNTRIES - pool.RESERVED_SLOTS), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
