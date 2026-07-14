#!/usr/bin/env python3
"""chrome-broker — session broker + FleetView backend for the chrome-service pool.

Stateless: session state is reconstructed from pod labels each request (no Redis).
Talks to the apiserver via the in-pod ServiceAccount token + CA (the android-emulator
gate.py pattern). Uses Playwright over CDP ONLY (no local browser) for the on-demand
storage_state() seed. Serves the FleetView SPA (static/) + a JSON API + /metrics.

Design: docs/plans/2026-07-13-chrome-service-pool-design.md
"""
import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ------------------------------------------------------------------ config
NS = os.environ.get("NAMESPACE", "chrome-service")
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
MASTER_CDP = os.environ.get("MASTER_CDP_URL", "http://chrome-service.chrome-service.svc:9222")
STATIC_DIR = os.environ.get("STATIC_DIR", "/app/static")
TEMPLATE_PATH = os.environ.get("WORKER_POD_TEMPLATE", "/app/worker_pod.json")
PORT = int(os.environ.get("PORT", "8080"))

MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "6"))       # burst ceiling (design D6)
IDLE_TTL = int(os.environ.get("IDLE_TTL_SECONDS", "1200"))  # 20m (design D7)
DEADLINE = int(os.environ.get("SESSION_DEADLINE_SECONDS", "3600"))  # 60m hard cap (D7)
SEED_TTL = int(os.environ.get("SEED_TTL_SECONDS", "10"))    # absorb an acquire burst (A7)
POOL_LABEL = "app=chrome-worker"

_seed = {"at": 0.0, "json": None, "last_export_seconds": 0.0, "errors": 0}
_seed_lock = threading.Lock()


# --------------------------------------------------------------- pure logic
# (unit-tested in test_broker.py — no I/O here)
def worker_name(session: str) -> str:
    """DNS-safe, unique pod name for a session id."""
    return ("chrome-worker-" + session).lower()[:63]


def build_pod_spec(template: dict, *, name, owner, purpose, session, started, deadline) -> dict:
    """Substitute the worker_pod.json placeholders. Does NOT mutate `template`."""
    s = json.dumps(template)
    for k, v in {
        "__NAME__": name, "__OWNER__": owner, "__PURPOSE__": purpose,
        "__SESSION__": session, "__STARTED__": str(started),
    }.items():
        s = s.replace(k, v)
    spec = json.loads(s)
    spec["spec"]["activeDeadlineSeconds"] = int(deadline)  # numeric, k8s rejects a string
    return spec


def pick_free_worker(pods: list):
    """First ready worker with no claimed session, else None."""
    return next((p for p in pods if not p.get("session") and p.get("ready")), None)


def should_reap(pod: dict, now: float, *, idle_ttl: int) -> bool:
    """A claimed session is never idle-reaped (its hard cap is activeDeadlineSeconds).
    An idle worker is reaped once it has sat unclaimed longer than idle_ttl."""
    if pod.get("session"):
        return False
    return (now - pod.get("released_at", now)) > idle_ttl


# ------------------------------------------------------------------ k8s I/O
def kube(method: str, path: str, body=None):
    with open(TOKEN_PATH) as f:
        token = f.read()
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/strategic-merge-patch+json"
                       if method == "PATCH" else "application/json")
    ctx = ssl.create_default_context(cafile=CA_PATH)
    with urllib.request.urlopen(req, data=data, context=ctx, timeout=15) as r:
        return json.load(r) if r.status != 204 and r.length != 0 else {}


def list_workers() -> list:
    """All pool pods as normalized dicts (name, session, owner, purpose, ready, ip,
    released_at, bare, started)."""
    resp = kube("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={POOL_LABEL}")
    out = []
    for p in resp.get("items", []):
        md, st = p["metadata"], p.get("status", {})
        labels, ann = md.get("labels", {}), md.get("annotations", {})
        cs = st.get("containerStatuses", [])
        ready = bool(cs) and all(c.get("ready") for c in cs) and st.get("phase") == "Running"
        released = ann.get("chrome-pool/released")
        out.append({
            "name": md["name"],
            "session": labels.get("chrome-pool/session", ""),
            "owner": labels.get("chrome-pool/owner", ""),
            "purpose": ann.get("chrome-pool/purpose", ""),
            "started": ann.get("chrome-pool/started", ""),
            "ready": ready,
            "phase": st.get("phase", ""),
            "ip": st.get("podIP", ""),
            "released_at": float(released) if released else md["creationTimestamp"] and 0.0,
            "bare": not md.get("ownerReferences"),  # broker-created pods have no owner
        })
    return out


def create_worker(session, owner, purpose):
    tpl = json.load(open(TEMPLATE_PATH))
    spec = build_pod_spec(tpl, name=worker_name(session), owner=owner, purpose=purpose,
                          session=session, started=int(time.time()), deadline=DEADLINE)
    kube("POST", f"/api/v1/namespaces/{NS}/pods", spec)


def claim_worker(name, session, owner, purpose):
    kube("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}", {
        "metadata": {"labels": {"chrome-pool/session": session, "chrome-pool/owner": owner},
                     "annotations": {"chrome-pool/purpose": purpose,
                                     "chrome-pool/started": str(int(time.time()))}}})


def release_worker(pod):
    """Bare pods are deleted; warm-pool (Deployment-owned) pods return to standby."""
    if pod["bare"]:
        kube("DELETE", f"/api/v1/namespaces/{NS}/pods/{pod['name']}")
    else:
        kube("PATCH", f"/api/v1/namespaces/{NS}/pods/{pod['name']}", {
            "metadata": {"labels": {"chrome-pool/session": ""},
                         "annotations": {"chrome-pool/released": str(int(time.time()))}}})


def wait_ready(name, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for w in list_workers():
            if w["name"] == name and w["ready"]:
                return w
        time.sleep(1.5)
    raise TimeoutError(f"worker {name} not ready in {timeout}s")


def current_url(ip):
    """The page a worker is driving (FleetView 'what is it doing'). Best-effort."""
    if not ip:
        return ""
    try:
        with urllib.request.urlopen(f"http://{ip}:9222/json/list", timeout=3) as r:
            tabs = json.load(r)
        pages = [t for t in tabs if t.get("type") == "page"]
        return (pages[0].get("url") or "") if pages else ""
    except Exception:
        return ""


# ------------------------------------------------------------------ seed
def storage_state():
    """Fresh cookies+localStorage from the LIVE master, cached SEED_TTL seconds so an
    acquire-burst shares one export. connect_over_cdp().close() only disconnects the CDP
    client — it never kills the master (verified: same semantics as browser_runner.js)."""
    with _seed_lock:
        now = time.time()
        if _seed["json"] is not None and now - _seed["at"] < SEED_TTL:
            return _seed["json"]
        t0 = time.time()
        try:
            from playwright.sync_api import sync_playwright
            with sync_playwright() as p:
                b = p.chromium.connect_over_cdp(MASTER_CDP, timeout=20000)
                try:
                    st = b.contexts[0].storage_state()
                finally:
                    b.close()
            _seed.update(at=now, json=st, last_export_seconds=time.time() - t0)
            return st
        except Exception:
            _seed["errors"] += 1
            raise


# ------------------------------------------------------------------ reaper
def reaper_loop():
    while True:
        try:
            now = time.time()
            for w in list_workers():
                if w["bare"] and should_reap(w, now, idle_ttl=IDLE_TTL):
                    release_worker(w)
        except Exception:
            pass
        time.sleep(30)


# ------------------------------------------------------------------ metrics
def render_metrics() -> bytes:
    workers = list_workers()
    busy = sum(1 for w in workers if w["session"])
    warm = sum(1 for w in workers if not w["session"] and w["ready"])
    lines = [
        "# HELP browser_active_sessions Claimed pool sessions.",
        "# TYPE browser_active_sessions gauge",
        f"browser_active_sessions {busy}",
        "# HELP browser_pool_workers Pool worker pods by state.",
        "# TYPE browser_pool_workers gauge",
        f'browser_pool_workers{{state="busy"}} {busy}',
        f'browser_pool_workers{{state="warm"}} {warm}',
        f'browser_pool_workers{{state="total"}} {len(workers)}',
        "# HELP browser_seed_export_seconds Duration of the last storage_state export.",
        "# TYPE browser_seed_export_seconds gauge",
        f'browser_seed_export_seconds {_seed["last_export_seconds"]:.4f}',
        "# HELP browser_seed_export_errors_total storage_state export failures.",
        "# TYPE browser_seed_export_errors_total counter",
        f'browser_seed_export_errors_total {_seed["errors"]}',
    ]
    # per-owner active sessions (low cardinality: <= MAX_WORKERS)
    by_owner = {}
    for w in workers:
        if w["session"]:
            by_owner[w["owner"]] = by_owner.get(w["owner"], 0) + 1
    for owner, n in by_owner.items():
        lines.append(f'browser_active_sessions_by_owner{{owner="{owner}"}} {n}')
    return ("\n".join(lines) + "\n").encode()


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self._send(200, b"ok", "text/plain")
        if path == "/metrics":
            return self._send(200, render_metrics(), "text/plain; version=0.0.4")
        if path == "/sessions":
            ws = list_workers()
            for w in ws:
                w["url"] = current_url(w["ip"]) if w["session"] else ""
                w.pop("ip", None)
            return self._send(200, {"sessions": ws})
        if path == "/seed":
            try:
                return self._send(200, storage_state())
            except Exception as e:
                return self._send(502, {"error": f"seed export failed: {e}"})
        # static FleetView SPA
        return self._serve_static(path)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            body = self._body()
        except Exception:
            return self._send(400, {"error": "invalid JSON body"})
        if path == "/acquire":
            return self._acquire(body)
        if path == "/release":
            pod = next((w for w in list_workers() if w["session"] == body.get("session")), None)
            if pod:
                release_worker(pod)
            return self._send(200, {"released": bool(pod)})
        return self._send(404, {"error": "not found"})

    def _acquire(self, body):
        owner = str(body.get("owner", "unknown"))[:63]
        purpose = str(body.get("purpose", ""))[:200]
        import secrets
        session = secrets.token_hex(4)
        workers = list_workers()
        free = pick_free_worker(workers)
        if free:
            claim_worker(free["name"], session, owner, purpose)
            return self._send(200, {"pod": free["name"], "cdpPort": 9222, "session": session,
                                    "reused": True})
        if sum(1 for w in workers) >= MAX_WORKERS:
            return self._send(503, {"error": f"pool at capacity ({MAX_WORKERS}); retry shortly"})
        name = worker_name(session)
        try:
            create_worker(session, owner, purpose)
            wait_ready(name)
        except Exception as e:
            return self._send(500, {"error": f"create worker: {e}"})
        return self._send(200, {"pod": name, "cdpPort": 9222, "session": session, "reused": False})

    def _serve_static(self, path):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not full.startswith(STATIC_DIR) or not os.path.isfile(full):
            full = os.path.join(STATIC_DIR, "index.html")  # SPA fallback
        if not os.path.isfile(full):
            return self._send(404, {"error": "not found"})
        ctype = ("text/html" if full.endswith(".html") else
                 "application/javascript" if full.endswith(".js") else
                 "text/css" if full.endswith(".css") else "application/octet-stream")
        with open(full, "rb") as f:
            self._send(200, f.read(), ctype)


def main():
    threading.Thread(target=reaper_loop, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
