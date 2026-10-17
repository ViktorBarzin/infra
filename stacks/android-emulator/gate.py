"""Wake gate for the android-emulator deployment.

Owns `/` on the emulator hostnames: if the emulator is up, redirect to the
noVNC screen; if it is scaled to zero, scale it to 1 and show a self-refreshing
"waking up" page. Agents use GET /status (JSON) + GET /wake. Pure stdlib —
runs on a stock python image with no installs.

It also makes the emulator yield its GPU seat. A background thread lists the
pods labelled YIELD_SELECTOR in YIELD_NAMESPACE (the f1-stream Transcoder) and,
when one waits Pending because k8s-node1 has no gpumem left, scales the
emulator to 0, so the waiting pod gets the 800 the emulator held. While a pod
waits, /wake does not scale the emulator up again. This covers every way that
Transcoder rolls (its deploy pipeline, Reloader, a Terraform apply), not only
the pipeline that sleeps the emulator itself.
"""
import json
import os
import ssl
import threading
import time
import urllib.error
import urllib.parse
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
VNC_PATH = "/vnc.html?autoconnect=1&resize=scale"
YIELD_NAMESPACE = os.environ.get("YIELD_NAMESPACE", "f1-stream")
YIELD_SELECTOR = os.environ.get("YIELD_SELECTOR", "android-emulator-yields-to=gpu-seat")
YIELD_INTERVAL_SECONDS = float(os.environ.get("YIELD_INTERVAL_SECONDS", "10"))
# The scheduler's FailedScheduling message names the resource a pod is short
# of; only this one is something the emulator can give back.
GPU_SEAT_SHORTAGE = "Insufficient viktorbarzin.me/gpumem"

# What the watcher saw last, and whether a /wake was held back for it. The
# handler threads and the watcher thread share it.
_yield_lock = threading.Lock()
_yield_state = {"waiters": [], "wake_held": False}


def reset_yield_state():
    with _yield_lock:
        _yield_state["waiters"] = []
        _yield_state["wake_held"] = False


def yielding_to():
    with _yield_lock:
        return list(_yield_state["waiters"])

WAKING_PAGE = """<!doctype html><html><head><title>Android emulator</title>
<meta http-equiv="refresh" content="10">
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;
height:100vh;background:#111;color:#eee}div{text-align:center}</style></head>
<body><div><h1>&#128241; Waking the emulator&hellip;</h1>
<p>Boot takes about 90 seconds from a warm disk.</p>
<p>This page refreshes automatically and will hand over to the screen when ready.</p>
<p>{note}</p>
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


def deployment_state(kube_fn=None):
    d = (kube_fn or kube)("GET", f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}")
    spec = d["spec"].get("replicas") or 0
    ready = d["status"].get("readyReplicas") or 0
    return spec, ready


def wake(kube_fn=None):
    # Direct replicas patch on the named deployment — same path the idle
    # sleeper uses to scale DOWN; needs only `deployments` patch, not
    # `deployments/scale`. Idle is now measured from dumpsys power, so there
    # is no idle-counter annotation to reset here.
    (kube_fn or kube)(
        "PATCH",
        f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}",
        {"spec": {"replicas": 1}},
    )


def sleep_emulator(kube_fn):
    kube_fn(
        "PATCH",
        f"/apis/apps/v1/namespaces/{NS}/deployments/{DEPLOY}",
        {"spec": {"replicas": 0}},
    )


def seat_waiters(pods):
    """Names of the pods the scheduler left Pending for want of gpumem."""
    names = []
    for p in pods:
        meta = p.get("metadata") or {}
        status = p.get("status") or {}
        if meta.get("deletionTimestamp") or status.get("phase") != "Pending":
            continue
        for c in status.get("conditions") or []:
            if (
                c.get("type") == "PodScheduled"
                and c.get("status") == "False"
                and c.get("reason") == "Unschedulable"
                and GPU_SEAT_SHORTAGE in (c.get("message") or "")
            ):
                names.append(meta.get("name", "?"))
                break
    return names


def list_seat_waiters(kube_fn):
    query = urllib.parse.urlencode(
        {"labelSelector": YIELD_SELECTOR, "fieldSelector": "status.phase=Pending"}
    )
    pods = kube_fn("GET", f"/api/v1/namespaces/{YIELD_NAMESPACE}/pods?{query}")
    return seat_waiters(pods.get("items") or [])


def yield_once(kube_fn, log):
    """One pass of the yield watcher. Returns the waiting pods it saw.

    Never raises: a failed read leaves the emulator as it is, and a failed
    patch is logged and retried on the next pass.
    """
    try:
        waiters = list_seat_waiters(kube_fn)
    except Exception as e:
        log(f"yield: could not list pods in {YIELD_NAMESPACE} ({describe(e)}); leaving the emulator as it is")
        return []
    with _yield_lock:
        _yield_state["waiters"] = list(waiters)
        wake_held = _yield_state["wake_held"] and not waiters
        if wake_held:
            _yield_state["wake_held"] = False
    if wake_held:
        log("yield: nothing waits for a GPU seat any more; doing the wake that was held back")
        try:
            wake(kube_fn)
        except Exception as e:
            log(f"yield: could not wake the emulator ({describe(e)}); the next visit to the gate wakes it")
    if not waiters:
        return []
    try:
        spec, _ = deployment_state(kube_fn)
        if spec:
            log(
                f"yield: {', '.join(waiters)} in {YIELD_NAMESPACE} is waiting for a GPU seat; "
                "putting the emulator to sleep (replicas -> 0). Whoever is using it is cut off; "
                "the gate wakes it on the next visit once nothing waits"
            )
            sleep_emulator(kube_fn)
    except Exception as e:
        log(f"yield: could not put the emulator to sleep ({describe(e)}); retrying next pass")
    return waiters


def try_wake(kube_fn):
    """Scale the emulator up unless a pod is waiting for its GPU seat.

    Returns the waiting pods; empty means it woke the emulator. A held-back
    wake is done by the watcher once nothing waits, so an agent polling
    /status still sees the emulator come up. If the waiters cannot be read,
    it wakes anyway, so a broken grant never locks people out.
    """
    try:
        waiters = list_seat_waiters(kube_fn)
    except Exception:
        waiters = []
    if waiters:
        with _yield_lock:
            _yield_state["waiters"] = list(waiters)
            _yield_state["wake_held"] = True
        return waiters
    wake(kube_fn)
    return []


def describe(e):
    if isinstance(e, urllib.error.HTTPError):
        return f"kube api error {e.code}"
    return f"{type(e).__name__}: {e}"


def yield_loop():
    while True:
        yield_once(kube, lambda line: print(line, flush=True))
        time.sleep(YIELD_INTERVAL_SECONDS)


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
                body = {"replicas": spec, "ready": ready}
                waiting = yielding_to()
                if waiting:
                    body["yielding_to"] = waiting
                return self._respond(200, json.dumps(body).encode(), "application/json")
            woke = False
            waiting = []
            if spec == 0:
                waiting = try_wake(kube)
                woke = not waiting
            if self.path.startswith("/wake"):
                body = {"replicas": 1 if (spec or woke) else 0, "ready": ready, "woke": woke}
                if waiting:
                    body["yielding_to"] = waiting
                return self._respond(200, json.dumps(body).encode(), "application/json")
            # default: human path
            if ready >= 1:
                return self._respond(302, b"", "text/plain", {"Location": VNC_PATH})
            if waiting:
                state = "asleep, giving its GPU seat to " + ", ".join(waiting)
                note = (
                    "Another workload on the GPU node is waiting for the seat the emulator "
                    "uses. The emulator wakes by itself once that pod has started, usually "
                    "within a couple of minutes."
                )
            else:
                state = "starting" if not woke else "scaled up just now"
                note = ""
            page = WAKING_PAGE.replace("{state}", state).replace("{note}", note)
            return self._respond(200, page.encode(), "text/html")
        except urllib.error.HTTPError as e:
            return self._respond(502, f"kube api error: {e.code}".encode(), "text/plain")
        except Exception as e:  # surface anything else readably
            return self._respond(500, f"gate error: {e}".encode(), "text/plain")

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    threading.Thread(target=yield_loop, name="yield", daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
