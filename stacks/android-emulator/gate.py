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

A pod that still waits after YIELD_LIMIT_SECONDS is short of more than the
emulator's 800, so the gate stops holding the emulator asleep for it, logs
why, and wakes it as usual. /healthz reports whether the watcher thread is
alive and fails when it is not.
"""
import datetime
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
# How long one pod may keep the emulator asleep. With the emulator asleep a
# Transcoder surge pod schedules within seconds; one that still waits after
# this is short of more than the emulator's 800 gpumem.
YIELD_LIMIT_SECONDS = float(os.environ.get("YIELD_LIMIT_SECONDS", "900"))
# The scheduler's FailedScheduling message names the resource a pod is short
# of; only this one is something the emulator can give back.
GPU_SEAT_SHORTAGE = "Insufficient viktorbarzin.me/gpumem"

# What the watcher saw last, whether a /wake was held back for it, when each
# waiting pod was first seen, and which pods passed the limit. The handler
# threads and the watcher thread share it.
_yield_lock = threading.Lock()
_yield_state = {"waiters": [], "wake_held": False, "first_seen": {}, "gave_up": []}
# The watcher thread and the wall-clock time its last pass finished, for /healthz.
_watcher = {"thread": None, "last_pass": None}


def reset_yield_state():
    with _yield_lock:
        _yield_state["waiters"] = []
        _yield_state["wake_held"] = False
        _yield_state["first_seen"] = {}
        _yield_state["gave_up"] = []


def yielding_to():
    with _yield_lock:
        return list(_yield_state["waiters"])


def gave_up_on():
    with _yield_lock:
        return list(_yield_state["gave_up"])


def log_line(line):
    print(line, flush=True)

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


def parse_time(value):
    """Epoch seconds from a Kubernetes timestamp, or None."""
    try:
        t = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError):
        return None
    return t.replace(tzinfo=datetime.timezone.utc).timestamp()


def seat_waiters(pods):
    """Names of the pods the scheduler left Pending for want of gpumem."""
    return [name for name, _ in seat_waits(pods)]


def seat_waits(pods):
    """(name, waiting since) for each pod left Pending for want of gpumem.

    Waiting since is the PodScheduled condition's lastTransitionTime in epoch
    seconds, or None when the pod does not carry one.
    """
    waits = []
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
                waits.append((meta.get("name", "?"), parse_time(c.get("lastTransitionTime"))))
                break
    return waits


def list_seat_waiters(kube_fn):
    query = urllib.parse.urlencode(
        {"labelSelector": YIELD_SELECTOR, "fieldSelector": "status.phase=Pending"}
    )
    pods = kube_fn("GET", f"/api/v1/namespaces/{YIELD_NAMESPACE}/pods?{query}")
    return seat_waits(pods.get("items") or [])


def within_limit(waits, now, log):
    """The waiting pods the emulator still yields to.

    A pod that has waited YIELD_LIMIT_SECONDS or longer, counted from its
    PodScheduled timestamp (or from when the gate first saw it), is dropped
    and recorded in gave_up; the reason is logged once per pod.
    """
    holding, expired, newly = [], [], []
    with _yield_lock:
        first_seen = _yield_state["first_seen"]
        current = {name for name, _ in waits}
        for name in list(first_seen):
            if name not in current:
                del first_seen[name]
        for name, since in waits:
            seen = first_seen.setdefault(name, now)
            waited = now - (since if since is not None else seen)
            if waited >= YIELD_LIMIT_SECONDS:
                expired.append(name)
                if name not in _yield_state["gave_up"]:
                    newly.append((name, waited))
            else:
                holding.append(name)
        _yield_state["gave_up"] = expired
    for name, waited in newly:
        log(
            f"yield: {name} in {YIELD_NAMESPACE} has waited {int(waited // 60)} min for a GPU seat, "
            f"past the {int(YIELD_LIMIT_SECONDS // 60)} min limit. The emulator's 800 gpumem is not "
            "what it lacks (another GPU tenant on k8s-node1, or a request that cannot fit), so the "
            "gate stops holding the emulator asleep for it and wakes it as usual; the "
            "PodUnschedulable alert reports the pod"
        )
    return holding


def yield_once(kube_fn, log, now=None):
    """One pass of the yield watcher. Returns the waiting pods it yields to.

    Never raises: a failed read leaves the emulator as it is, and a failed
    patch is logged and retried on the next pass.
    """
    try:
        waits = list_seat_waiters(kube_fn)
    except Exception as e:
        log(f"yield: could not list pods in {YIELD_NAMESPACE} ({describe(e)}); leaving the emulator as it is")
        return []
    waiters = within_limit(waits, time.time() if now is None else now, log)
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


def try_wake(kube_fn, now=None, log=log_line):
    """Scale the emulator up unless a pod is waiting for its GPU seat.

    Returns the waiting pods; empty means it woke the emulator. A held-back
    wake is done by the watcher once nothing waits, so an agent polling
    /status still sees the emulator come up. If the waiters cannot be read,
    it wakes anyway, so a broken grant never locks people out.
    """
    try:
        waits = list_seat_waiters(kube_fn)
    except Exception:
        waits = []
    waiters = within_limit(waits, time.time() if now is None else now, log)
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
        yield_once(kube, log_line)
        _watcher["last_pass"] = time.time()
        time.sleep(YIELD_INTERVAL_SECONDS)


def health_report(alive, last_pass, now):
    """(HTTP code, body) for /healthz.

    Unhealthy when the watcher thread has died, or when it is alive but has
    not finished a pass for longer than a pass can take (four API calls with a
    10 s timeout each, plus the interval).
    """
    stuck_after = max(120.0, 6 * YIELD_INTERVAL_SECONDS)
    body = {"yield_watcher": "alive" if alive else "dead"}
    if last_pass is not None:
        age = now - last_pass
        body["last_pass_s_ago"] = int(age)
        if alive and age > stuck_after:
            body["yield_watcher"] = "stuck"
    body["ok"] = body["yield_watcher"] == "alive"
    return (200 if body["ok"] else 503), body


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
            thread = _watcher["thread"]
            code, body = health_report(
                alive=thread is not None and thread.is_alive(),
                last_pass=_watcher["last_pass"],
                now=time.time(),
            )
            return self._respond(code, json.dumps(body).encode(), "application/json")
        try:
            spec, ready = deployment_state()
            if self.path.startswith("/status"):
                body = {"replicas": spec, "ready": ready}
                waiting = yielding_to()
                if waiting:
                    body["yielding_to"] = waiting
                stuck = gave_up_on()
                if stuck:
                    body["gave_up_on"] = stuck
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
    _watcher["thread"] = threading.Thread(target=yield_loop, name="yield", daemon=True)
    _watcher["thread"].start()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
