"""Wake gate for the android-emulator deployment.

Owns `/` on the emulator hostnames: if the emulator is up, redirect to the
noVNC screen; if it is scaled to zero, scale it to 1 and show a self-refreshing
"waking up" page. Agents use GET /status (JSON) + GET /wake. Pure stdlib —
runs on a stock python image with no installs.
"""
import json
import os
import ssl
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NS = os.environ.get("NAMESPACE", "android-emulator")
DEPLOY = os.environ.get("DEPLOYMENT", "android-emulator")
# Use the injected env vars, not DNS: kubernetes.default.svc failed to
# resolve from this alpine/musl pod (ndots + injected dns_config quirk).
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
IDLE_ANNOTATION = "emulator.viktorbarzin.me/idle-checks"
VNC_PATH = "/vnc.html?autoconnect=1&resize=scale"

WAKING_PAGE = """<!doctype html><html><head><title>Android emulator</title>
<meta http-equiv="refresh" content="10">
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
height:100vh;background:#111;color:#eee}div{text-align:center}</style></head>
<body><div><h1>&#128241; Waking the emulator&hellip;</h1>
<p>Boot takes about 90 seconds from a warm disk.</p>
<p>This page refreshes automatically and will hand over to the screen when ready.</p>
<p style="color:#888">state: {state}</p></div></body></html>"""


def kube(method: str, path: str, body=None):
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


def deployment_state():
    d = kube("GET", f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}")
    spec = d["spec"].get("replicas") or 0
    ready = d["status"].get("readyReplicas") or 0
    return spec, ready


def wake():
    kube(
        "PATCH",
        f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}",
        {
            "spec": {"replicas": 1},
            "metadata": {"annotations": {IDLE_ANNOTATION: "0"}},
        },
    )


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code: int, body: bytes, ctype: str, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (stdlib naming)
        if self.path == "/healthz":
            return self._respond(200, b"ok", "text/plain")
        try:
            spec, ready = deployment_state()
            if self.path.startswith("/status"):
                return self._respond(
                    200,
                    json.dumps({"replicas": spec, "ready": ready}).encode(),
                    "application/json",
                )
            woke = False
            if spec == 0:
                wake()
                woke = True
            if self.path.startswith("/wake"):
                return self._respond(
                    200,
                    json.dumps({"replicas": 1, "ready": ready, "woke": woke}).encode(),
                    "application/json",
                )
            # default: human path
            if ready >= 1:
                return self._respond(302, b"", "text/plain", {"Location": VNC_PATH})
            state = "starting" if not woke else "scaled up just now"
            page = WAKING_PAGE.replace("{state}", state)
            return self._respond(200, page.encode(), "text/html")
        except urllib.error.HTTPError as e:
            return self._respond(502, f"kube api error: {e.code}".encode(), "text/plain")
        except Exception as e:  # surface anything else readably
            return self._respond(500, f"gate error: {e}".encode(), "text/plain")

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
