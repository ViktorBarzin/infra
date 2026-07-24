#!/usr/bin/env python3
"""geo-browser broker — on-demand per-country NordVPN browser sessions.

Serves an Authentik-gated country-picker UI and, per request, creates an
ephemeral Pod (gluetun WireGuard tunnel + headful Chromium + noVNC, all sharing
one netns so the browser egresses through the tunnel) plus a per-session
Service + Ingress. Reaps sessions at a hard deadline and enforces a concurrency
ceiling. Pure stdlib; talks to the apiserver via the in-pod ServiceAccount
token (the chrome-broker pattern). Design:
docs/plans/2026-07-24-geo-browser-nordvpn-design.md
"""
import base64
import json
import os
import re
import secrets
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ config
NS = os.environ.get("NAMESPACE", "geo-browser")
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
HERE = os.path.dirname(os.path.abspath(__file__))

HOST = os.environ.get("HOST", "geo.viktorbarzin.me")
TLS_SECRET = os.environ.get("TLS_SECRET", "geo-browser-tls")
STRIP_MW = os.environ.get("STRIP_MIDDLEWARE", "%s-geo-strip-session@kubernetescrd" % NS)
NORDVPN_TOKEN = os.environ.get("NORDVPN_TOKEN", "")
MAX_SESSIONS = int(os.environ.get("MAX_SESSIONS", "4"))
DEADLINE = int(os.environ.get("SESSION_DEADLINE_SECONDS", "3600"))  # hard cap
PORT = int(os.environ.get("PORT", "8080"))
GLUETUN_IMAGE = os.environ.get("GLUETUN_IMAGE", "ghcr.io/qdm12/gluetun:latest")
BROWSER_IMAGE = os.environ.get("BROWSER_IMAGE", "ghcr.io/viktorbarzin/chrome-service-browser:latest")
NOVNC_IMAGE = os.environ.get("NOVNC_IMAGE", "ghcr.io/viktorbarzin/chrome-service-novnc:19d0f0933a8ec75be6cfa077db88e0f8c3760f40")

# NordVPN country names accepted by gluetun's SERVER_COUNTRIES.
COUNTRIES = [
    "Japan", "United States", "United Kingdom", "Germany", "Netherlands",
    "France", "Canada", "Australia", "Switzerland", "Sweden", "Singapore",
    "Spain", "Italy", "Brazil", "India", "South Korea", "Poland", "Norway",
    "Ireland", "Finland", "Denmark", "Belgium", "Austria", "Portugal",
    "Hong Kong", "Taiwan", "Mexico", "New Zealand", "South Africa", "Turkey",
]

_TOKEN = open(_TOKEN_PATH).read().strip() if os.path.exists(_TOKEN_PATH) else ""
_SSL = ssl.create_default_context(cafile=_CA_PATH) if os.path.exists(_CA_PATH) else ssl.create_default_context()
_create_lock = threading.Lock()  # serialise capacity-check + create (TOCTOU)


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


# ------------------------------------------------------------------ nordvpn
def nordvpn_wg_key():
    """Fetch the account's current NordLynx private key via the access token."""
    req = urllib.request.Request("https://api.nordvpn.com/v1/users/services/credentials")
    req.add_header("Authorization", "Basic " + base64.b64encode(("token:" + NORDVPN_TOKEN).encode()).decode())
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())["nordlynx_private_key"]


def ensure_wg_secret():
    """Upsert the ns Secret holding the current NordLynx key (re-fetched via the
    durable token, so account-side key rotation is picked up)."""
    key = nordvpn_wg_key()
    body = {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "geo-nord-wg", "namespace": NS},
        "type": "Opaque", "stringData": {"wg_key": key},
    }
    st, _ = k8s("POST", "/api/v1/namespaces/%s/secrets" % NS, body)
    if st == 409:
        k8s("PATCH", "/api/v1/namespaces/%s/secrets/geo-nord-wg" % NS,
            {"stringData": {"wg_key": key}}, content_type="application/merge-patch+json")


# ------------------------------------------------------------------ helpers
def _label(s):
    return re.sub(r"[^a-z0-9-]", "-", (s or "").lower()).strip("-")[:63] or "x"


def _name(sid):
    return "geo-" + sid


def build_pod(sid, country, owner):
    chrome_cmd = (
        "set -e\n"
        "Xvfb :99 -screen 0 1920x1080x24 -listen tcp -ac &\n"
        "sleep 2\n"
        "exec /opt/google/chrome/chrome --no-sandbox --disable-dev-shm-usage "
        "--no-first-run --no-default-browser-check --password-store=basic "
        "--use-mock-keychain --user-data-dir=/tmp/chrome-data "
        "--window-size=1920,1080 --start-maximized about:blank\n"
    )
    return {
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {
            "name": _name(sid), "namespace": NS,
            "labels": {"app": "geo-session", "geo/session": sid,
                       "geo/country": _label(country), "geo/owner": _label(owner)},
            "annotations": {"geo/started": str(int(time.time())), "geo/country-name": country},
        },
        "spec": {
            "restartPolicy": "Never",
            "activeDeadlineSeconds": DEADLINE,
            "dnsPolicy": "None",
            "dnsConfig": {"nameservers": ["127.0.0.1"]},
            "imagePullSecrets": [{"name": "ghcr-credentials"}],
            "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [
                {
                    "name": "gluetun", "image": GLUETUN_IMAGE,
                    "securityContext": {"capabilities": {"add": ["NET_ADMIN", "SYS_MODULE"]}},
                    "env": [
                        {"name": "VPN_SERVICE_PROVIDER", "value": "nordvpn"},
                        {"name": "VPN_TYPE", "value": "wireguard"},
                        {"name": "SERVER_COUNTRIES", "value": country},
                        {"name": "DOT", "value": "on"},
                        {"name": "FIREWALL_OUTBOUND_SUBNETS", "value": "10.10.0.0/16,10.96.0.0/12"},
                        # Allow inbound to the noVNC port from cluster clients
                        # (Traefik) — gluetun's kill-switch drops unsolicited
                        # INPUT otherwise, so the noVNC WS/HTTP would hang.
                        {"name": "FIREWALL_INPUT_PORTS", "value": "6080"},
                        {"name": "WIREGUARD_PRIVATE_KEY",
                         "valueFrom": {"secretKeyRef": {"name": "geo-nord-wg", "key": "wg_key"}}},
                    ],
                    "resources": {"requests": {"memory": "64Mi"}, "limits": {"memory": "192Mi"}},
                },
                {
                    "name": "chrome", "image": BROWSER_IMAGE, "imagePullPolicy": "IfNotPresent",
                    "command": ["bash", "-c", chrome_cmd],
                    "securityContext": {"runAsUser": 1000, "runAsGroup": 1000},
                    "env": [{"name": "DISPLAY", "value": ":99"}, {"name": "HOME", "value": "/tmp"}],
                    "resources": {"requests": {"cpu": "250m", "memory": "1536Mi"}, "limits": {"memory": "3Gi"}},
                },
                {
                    "name": "novnc", "image": NOVNC_IMAGE, "imagePullPolicy": "IfNotPresent",
                    "command": ["bash", "-c", "ulimit -n 65536; exec /entrypoint.sh"],
                    "securityContext": {"runAsUser": 1000, "runAsGroup": 1000},
                    "ports": [{"name": "http", "containerPort": 6080}],
                    "resources": {"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"memory": "256Mi"}},
                },
            ],
        },
    }


def build_service(sid):
    return {
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": _name(sid), "namespace": NS,
                     "labels": {"app": "geo-session", "geo/session": sid}},
        "spec": {"selector": {"geo/session": sid},
                 "ports": [{"name": "novnc", "port": 6080, "targetPort": 6080}]},
    }


def build_ingress(sid):
    return {
        "apiVersion": "networking.k8s.io/v1", "kind": "Ingress",
        "metadata": {
            "name": _name(sid), "namespace": NS,
            "labels": {"app": "geo-session", "geo/session": sid},
            "annotations": {
                "traefik.ingress.kubernetes.io/router.entrypoints": "websecure",
                # static stripPrefixRegex middleware (^/s/<token>) — keeps the
                # noVNC assets/WS at the container's root path. auth=none: an
                # Authentik forward-auth would break the noVNC WebSocket
                # (android-emulator lesson); the unguessable /s/<token> IS the gate.
                "traefik.ingress.kubernetes.io/router.middlewares": STRIP_MW,
                # Beat the UI ingress's "/" router so /s/<token> always wins.
                "traefik.ingress.kubernetes.io/router.priority": "1000",
            },
        },
        "spec": {
            "ingressClassName": "traefik",
            "tls": [{"hosts": [HOST], "secretName": TLS_SECRET}],
            "rules": [{"host": HOST, "http": {"paths": [{
                "path": "/s/" + sid, "pathType": "Prefix",
                "backend": {"service": {"name": _name(sid), "port": {"number": 6080}}},
            }]}}]},
    }


# ------------------------------------------------------------------ sessions
def list_sessions():
    st, obj = k8s("GET", "/api/v1/namespaces/%s/pods?labelSelector=app%%3Dgeo-session" % NS)
    out = []
    for p in obj.get("items", []):
        md = p.get("metadata", {})
        if md.get("deletionTimestamp"):
            continue
        labels = md.get("labels", {})
        status = p.get("status", {})
        cs = status.get("containerStatuses", [])
        ready = bool(cs) and all(c.get("ready") for c in cs) and status.get("phase") == "Running"
        out.append({
            "session": labels.get("geo/session"),
            "country": md.get("annotations", {}).get("geo/country-name", labels.get("geo/country")),
            "owner": labels.get("geo/owner"),
            "started": int(md.get("annotations", {}).get("geo/started", "0")),
            "phase": status.get("phase"),
            "ready": ready,
            "url": "/s/%s/vnc.html?path=s/%s/websockify&autoconnect=true&resize=remote" % (
                labels.get("geo/session"), labels.get("geo/session")),
        })
    return out


def create_session(country, owner):
    if country not in COUNTRIES:
        raise ValueError("unknown country")
    with _create_lock:
        sessions = list_sessions()
        # concurrency ceiling: evict the oldest to free a cluster slot (NOT a
        # NordVPN cap — that's 10; 4 is our resource ceiling well under it).
        while len(sessions) >= MAX_SESSIONS:
            oldest = min(sessions, key=lambda s: s["started"])
            delete_session(oldest["session"])
            sessions = [s for s in sessions if s["session"] != oldest["session"]]
        ensure_wg_secret()
        sid = secrets.token_hex(16)  # DNS-safe (lowercase hex) AND unguessable
        k8s("POST", "/api/v1/namespaces/%s/pods" % NS, build_pod(sid, country, owner))
        k8s("POST", "/api/v1/namespaces/%s/services" % NS, build_service(sid))
        k8s("POST", "/apis/networking.k8s.io/v1/namespaces/%s/ingresses" % NS, build_ingress(sid))
    return {"session": sid, "country": country,
            "url": "/s/%s/vnc.html?path=s/%s/websockify&autoconnect=true&resize=remote" % (sid, sid)}


def delete_session(sid):
    if not re.fullmatch(r"[0-9a-f]{6,64}", sid or ""):
        raise ValueError("bad session id")
    k8s("DELETE", "/apis/networking.k8s.io/v1/namespaces/%s/ingresses/%s" % (NS, _name(sid)))
    k8s("DELETE", "/api/v1/namespaces/%s/services/%s" % (NS, _name(sid)))
    k8s("DELETE", "/api/v1/namespaces/%s/pods/%s" % (NS, _name(sid)))


def reaper():
    """Delete finished/expired sessions and clean up their Service+Ingress.
    activeDeadlineSeconds fails the pod at DEADLINE; we then reap the trio."""
    while True:
        try:
            now = time.time()
            for s in list_sessions():
                expired = s["phase"] in ("Failed", "Succeeded") or (now - s["started"]) > DEADLINE + 30
                if expired and s["session"]:
                    delete_session(s["session"])
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
        return self.headers.get("X-authentik-username") or self.headers.get("X-Authentik-Username") or "user"

    def log_message(self, *a):
        pass  # quiet

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index.html"):
            return self._send(200, _page(), "text/html; charset=utf-8")
        if self.path == "/healthz":
            return self._send(200, b'{"ok":true}')
        if self.path == "/metrics":
            try:
                n = len(list_sessions())
            except Exception:
                n = -1
            body = ("# HELP geo_sessions_active Active geo-browser sessions\n"
                    "# TYPE geo_sessions_active gauge\ngeo_sessions_active %d\n"
                    "# HELP geo_max_sessions Concurrency ceiling\n"
                    "# TYPE geo_max_sessions gauge\ngeo_max_sessions %d\n" % (n, MAX_SESSIONS))
            return self._send(200, body, "text/plain; version=0.0.4")
        if self.path == "/api/countries":
            return self._send(200, json.dumps({"countries": COUNTRIES, "max": MAX_SESSIONS}))
        if self.path == "/api/sessions":
            try:
                return self._send(200, json.dumps({"sessions": list_sessions()}))
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')

    def do_POST(self):
        if self.path == "/api/session":
            n = int(self.headers.get("Content-Length", "0") or "0")
            try:
                req = json.loads(self.rfile.read(n) or "{}")
                res = create_session(req.get("country"), self._owner())
                return self._send(202, json.dumps(res))
            except ValueError as e:
                return self._send(400, json.dumps({"error": str(e)}))
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')

    def do_DELETE(self):
        m = re.fullmatch(r"/api/session/([0-9a-f]{6,64})", self.path)
        if m:
            try:
                delete_session(m.group(1))
                return self._send(200, b'{"ok":true}')
            except Exception as e:
                return self._send(500, json.dumps({"error": str(e)}))
        return self._send(404, b'{"error":"not found"}')


def main():
    try:
        ensure_wg_secret()
        print("startup: wg secret ensured", flush=True)
    except Exception as e:
        print("startup: ensure_wg_secret failed (will retry on demand):", e, flush=True)
    threading.Thread(target=reaper, daemon=True).start()
    print("geo-broker listening on :%d (ns=%s host=%s max=%d)" % (PORT, NS, HOST, MAX_SESSIONS), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()


if __name__ == "__main__":
    main()
