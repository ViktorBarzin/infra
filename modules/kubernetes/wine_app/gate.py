"""Wake gate for one wine_app deployment (modules/kubernetes/wine_app, ADR-0035).

Owns `/` on the app's hostname: if the app is up, redirect to the noVNC screen;
if it is scaled to zero, scale it to 1 and show a self-refreshing "waking up"
page. GET /status (JSON) reports without waking, GET /wake wakes and answers
JSON. Pure stdlib, runs on a stock python image with no installs.

A copy of stacks/android-emulator/gate.py without the GPU-seat yield logic,
which Windows apps under Wine do not need.
"""
import html
import json
import os
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = os.environ.get("NAMESPACE", "wine-app")
DEPLOY = os.environ.get("DEPLOYMENT", "wine-app")
APP_TITLE = os.environ.get("APP_TITLE", "the app")
# Use the injected env vars, not DNS: kubernetes.default.svc failed to
# resolve from the emulator's alpine/musl gate (ndots + injected dns_config).
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
VNC_PATH = "/vnc.html?autoconnect=1&resize=scale&reconnect=1"

WAKING_PAGE = """<!doctype html><html><head><title>{title}</title>
<meta http-equiv="refresh" content="10">
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
height:100vh;margin:0;padding:0 16px;background:#111;color:#eee}div{text-align:center}</style></head>
<body><div><h1>Starting {title}&hellip;</h1>
<p>It sleeps when nobody is using it. Starting takes one to two minutes,
longer the first time while it installs.</p>
<p>This page refreshes by itself and opens the app when it is ready.</p>
<p style="color:#888">state: {state}</p></div></body></html>"""


def kube(method, path, body=None):
    with open(TOKEN_PATH) as f:
        token = f.read()
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/strategic-merge-patch+json")
    ctx = ssl.create_default_context(cafile=CA_PATH)
    with urllib.request.urlopen(req, data=data, context=ctx, timeout=10) as r:
        return json.load(r)


def deployment_path():
    return f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}"


def deployment_state(kube_fn):
    d = kube_fn("GET", deployment_path())
    return d["spec"].get("replicas") or 0, d["status"].get("readyReplicas") or 0


def wake(kube_fn):
    # A replicas patch on the named deployment, the same call the idle sleeper
    # makes to scale down, so the Role needs only `deployments` patch.
    kube_fn("PATCH", deployment_path(), {"spec": {"replicas": 1}})


def handle(path, kube_fn):
    """Return (status, headers, body) for a GET of `path`."""
    if path == "/healthz":
        return 200, {"Content-Type": "text/plain"}, b"ok"
    try:
        spec, ready = deployment_state(kube_fn)
        if path.startswith("/status"):
            body = json.dumps({"replicas": spec, "ready": ready}).encode()
            return 200, {"Content-Type": "application/json"}, body
        woke = False
        if spec == 0:
            wake(kube_fn)
            woke = True
        if path.startswith("/wake"):
            body = json.dumps({"replicas": 1, "ready": ready, "woke": woke}).encode()
            return 200, {"Content-Type": "application/json"}, body
        if ready >= 1:
            return 302, {"Content-Type": "text/plain", "Location": VNC_PATH}, b""
        state = "scaled up just now" if woke else "starting"
        page = WAKING_PAGE.replace("{title}", html.escape(APP_TITLE)).replace("{state}", state)
        return 200, {"Content-Type": "text/html"}, page.encode()
    except urllib.error.HTTPError as e:
        return 502, {"Content-Type": "text/plain"}, f"kube api error: {e.code}".encode()
    except Exception as e:  # surface anything else readably
        return 500, {"Content-Type": "text/plain"}, f"gate error: {e}".encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (stdlib naming)
        code, headers, body = handle(self.path, kube)
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
