#!/usr/bin/env python3
"""chrome-broker — session broker + FleetView backend for the chrome-service pool.

Stateless: session state is reconstructed from pod labels each request (no Redis).
Talks to the apiserver via the in-pod ServiceAccount token + CA (the android-emulator
gate.py pattern). The on-demand storage_state() seed is read from the master over raw
CDP (cdp_cookies.py, stdlib only). Serves the FleetView SPA (static/) + a JSON API +
/metrics.

Design: docs/plans/2026-07-13-chrome-service-pool-design.md
"""
import json
import os
import ssl
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cdp_cookies  # noqa: E402  (mounted beside broker.py in the same ConfigMap)

# ------------------------------------------------------------------ config
NS = os.environ.get("NAMESPACE", "chrome-service")
API = "https://%s:%s" % (
    os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc"),
    os.environ.get("KUBERNETES_SERVICE_PORT", "443"),
)
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
MASTER_CDP = os.environ.get("MASTER_CDP_URL", "http://chrome-service.chrome-service.svc:9222")
_HERE = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.environ.get("STATIC_DIR", _HERE)  # index.html sits beside broker.py
TEMPLATE_PATH = os.environ.get("WORKER_POD_TEMPLATE", os.path.join(_HERE, "worker_pod.json"))
PORT = int(os.environ.get("PORT", "8080"))

MAX_WORKERS = int(os.environ.get("MAX_WORKERS", "6"))       # burst ceiling (design D6)
IDLE_TTL = int(os.environ.get("IDLE_TTL_SECONDS", "1200"))  # 20m (design D7)
DEADLINE = int(os.environ.get("SESSION_DEADLINE_SECONDS", "3600"))  # 60m hard cap (D7)
SEED_TTL = int(os.environ.get("SEED_TTL_SECONDS", "10"))    # absorb an acquire burst (A7)
# How old the last good seed may be before a failing export stops serving it.
# The master goes away for a few minutes whenever its pod is recreated (three
# times in 90 minutes on 2026-09-19); without this every run in that window
# silently loses Viktor's logins instead of reusing cookies a few minutes old.
# The error counter still ticks and the alert still fires while this is in use.
SEED_STALE_MAX = int(os.environ.get("SEED_STALE_MAX_SECONDS", "900"))
# How long release waits for closed targets to actually disappear. /json/close
# is asynchronous, and a release that blocks for long would hold up the caller.
RESET_CONFIRM_SECONDS = float(os.environ.get("RESET_CONFIRM_SECONDS", "3"))
# How long a heartbeating caller may go quiet before its session is reclaimed.
# Only sessions that have sent at least one heartbeat are reclaimed this way, so
# a caller that never heartbeats keeps the DEADLINE behaviour and nothing that
# worked before can start being cut short.
HEARTBEAT_TIMEOUT = int(os.environ.get("HEARTBEAT_TIMEOUT_SECONDS", "120"))
POOL_LABEL = "app=chrome-worker"

_seed = {"at": 0.0, "json": None, "last_export_seconds": 0.0, "errors": 0}
_seed_lock = threading.Lock()
# Serializes the acquire pick-or-create decision (ThreadingHTTPServer → many
# threads). Without it two concurrent /acquire calls can pick the same free warm
# worker (TOCTOU) and collide sessions — breaking isolation.
_acquire_lock = threading.Lock()


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


def should_reclaim_session(pod: dict, now: float, *, heartbeat_timeout: int) -> bool:
    """Has a heartbeating caller stopped heartbeating?

    A caller killed without releasing leaves its chrome-pool/session label on the
    pod. pick_free_worker skips any pod carrying one, so a warm pod stays out of
    the pool until the reaper deletes it at DEADLINE, 60 minutes later, while the
    pool falls back to cold burst pods. Seen live 2026-09-19 on
    chrome-worker-warm-774955dff-zvl62, holding session 235f7f1d after its caller
    was killed.

    OPT-IN BY CONSTRUCTION: a session reclaims only once it has sent at least one
    heartbeat and then gone quiet. Callers that never heartbeat (f1-stream leases
    through its own try/finally, and anything else speaking to the broker
    directly) report no heartbeat at all and keep the DEADLINE behaviour
    unchanged, so this cannot start cutting short a session that works today.
    """
    if not pod.get("session"):
        return False
    heartbeat = pod.get("heartbeat_at", 0.0)
    if not heartbeat:
        return False
    return (now - heartbeat) > heartbeat_timeout


# Targets that belong to the worker image rather than to any session. The two
# stealth/Chrome extension service workers and their background pages live here,
# measured on a live worker 2026-09-19: closing them would take out the stealth
# the pool exists to provide.
RESET_KEEP_SCHEMES = ("chrome-extension://", "devtools://", "chrome://")


def plan_browser_reset(tabs: list) -> tuple:
    """What a released warm worker still has open that belonged to its session.

    `tabs` is /json/list output. Returns (close_ids, need_blank): the targets to
    close, and whether a fresh about:blank has to be opened afterwards because
    the session navigated the baseline page away.

    A burst pod is deleted on release so its browser dies with it. A warm pod is
    only relabelled and handed to the next caller, so whatever the last session
    left sits there until the pod is replaced. That is how an embed.st service
    worker held the single warm worker for 4d20h and broke `homelab browser run`
    for every user (infra #98).
    """
    pages, workers, kept_blank = [], [], False
    for t in tabs or []:
        tid, url = t.get("id"), t.get("url") or ""
        if not tid:
            continue
        if url.startswith(RESET_KEEP_SCHEMES):
            continue
        # Keep exactly one untouched about:blank: that is the page the worker
        # starts with, and leaving it means the reset never has to reopen one.
        if url in ("about:blank", "") and t.get("type") == "page" and not kept_blank:
            kept_blank = True
            continue
        (pages if t.get("type") == "page" else workers).append(tid)
    # Pages before workers. A service worker closed while a page it controls is
    # still open can be started straight back up by that page, so the client
    # goes first and the worker has nothing left to serve.
    return pages + workers, not kept_blank


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
    released_at, heartbeat_at, bare, started)."""
    resp = kube("GET", f"/api/v1/namespaces/{NS}/pods?labelSelector={POOL_LABEL}")
    out = []
    for p in resp.get("items", []):
        md, st = p["metadata"], p.get("status", {})
        labels, ann = md.get("labels", {}), md.get("annotations", {})
        cs = st.get("containerStatuses", [])
        ready = bool(cs) and all(c.get("ready") for c in cs) and st.get("phase") == "Running"
        released = ann.get("chrome-pool/released")
        heartbeat = ann.get("chrome-pool/heartbeat")
        out.append({
            "name": md["name"],
            "session": labels.get("chrome-pool/session", ""),
            "owner": labels.get("chrome-pool/owner", ""),
            "purpose": ann.get("chrome-pool/purpose", ""),
            "started": ann.get("chrome-pool/started", ""),
            "ready": ready,
            "phase": st.get("phase", ""),
            "ip": st.get("podIP", ""),
            "released_at": float(released) if released else 0.0,
            "heartbeat_at": float(heartbeat) if heartbeat else 0.0,
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
    # Deliberately NOT stamping a heartbeat here. The annotation is what marks a
    # session as reclaimable on silence, so writing it at claim time would opt in
    # every caller, including the ones that never heartbeat.


def heartbeat_worker(name):
    """Record that the caller holding this pod is still alive."""
    kube("PATCH", f"/api/v1/namespaces/{NS}/pods/{name}", {
        "metadata": {"annotations": {"chrome-pool/heartbeat": str(int(time.time()))}}})


def reset_browser(ip) -> int:
    """Close what the finished session left in a warm worker's browser.

    Best-effort and bounded: a worker that cannot be reset still goes back to
    standby, because refusing to release it would wedge the pool, which is worse
    than handing on a dirty browser. Returns (closed, stuck): how many
    targets were CONFIRMED gone, and how many reported themselves closed
    and stayed. A non-zero stuck count means this browser cannot be
    cleaned and the pod has to be replaced instead.

    Stays on the CDP HTTP endpoint so broker.py keeps its no-dependency rule.
    /json/close works on service workers as well as pages, verified against a
    live worker; disposing empty browser contexts would need the websocket, and
    Chrome already drops a context when its client disconnects.
    """
    if not ip:
        return 0, 0
    base = f"http://{ip}:9222"
    try:
        with urllib.request.urlopen(f"{base}/json/list", timeout=3) as r:
            tabs = json.load(r)
    except Exception:
        return 0, 0
    close_ids, need_blank = plan_browser_reset(tabs)
    for tid in close_ids:
        try:
            with urllib.request.urlopen(f"{base}/json/close/{tid}", timeout=3):
                pass
        except Exception:
            pass
    # /json/close answers "Target is closing" and returns before the target has
    # actually gone, so a 200 is not proof. Measured on a live worker: a service
    # worker was still listed in a snapshot taken right after its close
    # succeeded. Re-list until they are really gone, and report what survived
    # rather than counting the 200s.
    #
    # One case this cannot win, and does not need to: while a Playwright client
    # is still attached, its context restarts a service worker as fast as we
    # close it (measured 2026-09-19, 1 of 2 confirmed). Release runs after the
    # client has gone, and the same worker with no client attached confirmed
    # 2 of 2. A live client is the caller's own browser, not a leftover.
    wanted = set(close_ids)
    closed = 0
    deadline = time.time() + RESET_CONFIRM_SECONDS
    while wanted and time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{base}/json/list", timeout=3) as r:
                still = {t.get("id") for t in json.load(r)}
        except Exception:
            break
        gone = wanted - still
        closed += len(gone)
        wanted -= gone
        if wanted:
            time.sleep(0.2)
    if wanted:
        # A target that reports itself closed and stays in the list. This is
        # the embed.st shape: Target.closeTarget returns success, the target
        # survives, and the next connectOverCDP still dies on it. Say so, and
        # let the caller decide, which for a warm pod means recycling it.
        print("[broker] %d target(s) refused to close after %.0fs: %s"
              % (len(wanted), RESET_CONFIRM_SECONDS, ", ".join(sorted(wanted))),
              file=sys.stderr, flush=True)
    if need_blank and not wanted:
        # Every page was the session's, so leave the worker the blank tab it
        # started with rather than a browser with nothing open. Skipped when
        # something is stuck, because the pod is about to be replaced anyway.
        try:
            req = urllib.request.Request(f"{base}/json/new?about:blank", method="PUT")
            with urllib.request.urlopen(req, timeout=3):
                pass
        except Exception:
            pass
    return closed, len(wanted)


def release_worker(pod):
    """Bare pods are deleted; warm-pool (Deployment-owned) pods return to standby.

    Unless the browser could not be cleaned, in which case the warm pod is
    deleted too and the Deployment builds a fresh one.
    """
    if pod["bare"]:
        kube("DELETE", f"/api/v1/namespaces/{NS}/pods/{pod['name']}")
        return
    # A bare pod's browser dies with the pod. A warm one is reused as-is, so
    # it has to be cleaned here or the next caller inherits the last
    # session's pages, service workers and open tabs (infra #98).
    _, stuck = reset_browser(pod.get("ip"))
    if stuck:
        # RECYCLE, because closing the target demonstrably does not always
        # work and handing the browser on is the failure we are trying to end.
        #
        # Measured 2026-09-19 against the real embed.st orphan, after the
        # first version of this shipped claiming otherwise: closeTarget
        # returned success, the target stayed in /json/list through the
        # release, and the next caller's connectOverCDP died on that same
        # target after its own sweep had logged "cleared". Recycling the pod
        # was the only thing that fixed it, which is what emo did by hand
        # before filing #98. So the confirm loop's survivors are acted on
        # rather than logged: replacing the pod costs the next caller a ~30s
        # cold start, against a poisoned worker breaking every caller until a
        # human notices.
        print("[broker] %s: %d target(s) would not close — deleting the pod "
              "so the Deployment replaces it" % (pod["name"], stuck),
              file=sys.stderr, flush=True)
        kube("DELETE", f"/api/v1/namespaces/{NS}/pods/{pod['name']}")
        return
    # The heartbeat is cleared, not just left to go stale. A warm pod is
    # reused, so a heartbeat left behind by the last caller would make the
    # NEXT session look reclaimable the moment it is claimed, even one that
    # never heartbeats. null removes the key under a strategic merge patch.
    kube("PATCH", f"/api/v1/namespaces/{NS}/pods/{pod['name']}", {
        "metadata": {"labels": {"chrome-pool/session": ""},
                     "annotations": {"chrome-pool/released": str(int(time.time())),
                                     "chrome-pool/heartbeat": None}}})


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
def usable_stale_age(now: float, cached_at: float, has_cached: bool,
                     max_age: float = SEED_STALE_MAX):
    """Age of the last good seed if a failed export may serve it, else None."""
    if not has_cached:
        return None
    age = now - cached_at
    if age < 0 or age > max_age:
        return None
    return age


def storage_state():
    """The master's cookies, cached SEED_TTL seconds so an acquire-burst shares one read.

    Read over raw CDP (one Storage.getCookies on the browser endpoint) rather than
    through playwright. connect_over_cdp enumerates every target and asserts each
    carries a browserContextId; an orphaned service worker has none, which is what
    broke this path for ten hours on 2026-09-18. See files/cdp_cookies.py.

    Returns (state, stale_age) — stale_age is None for a fresh read, or the age in
    seconds of the last good seed being served because the export just failed.
    """
    with _seed_lock:
        now = time.time()
        if _seed["json"] is not None and now - _seed["at"] < SEED_TTL:
            return _seed["json"], None
        t0 = time.time()
        try:
            st = cdp_cookies.storage_state(MASTER_CDP)
            _seed.update(at=now, json=st, last_export_seconds=time.time() - t0)
            return st, None
        except Exception as e:
            _seed["errors"] += 1
            # The subprocess this used to run swallowed its own stderr, so a year's
            # worth of 502s said only "seed export failed" with no reason. Log it.
            print("[broker] seed export from %s failed: %s: %s" % (MASTER_CDP, type(e).__name__, e),
                  file=sys.stderr, flush=True)
            traceback.print_exc()
            age = usable_stale_age(time.time(), _seed["at"], _seed["json"] is not None)
            if age is None:
                raise
            print("[broker] serving the last good seed, %.0fs old" % age,
                  file=sys.stderr, flush=True)
            return _seed["json"], age


# ------------------------------------------------------------------ thumbnails
SCREENSHOT_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "screenshot.py")
_thumbs = {}          # session -> (ts, png_bytes)
_thumbs_lock = threading.Lock()
THUMB_TTL = 5         # seconds; bounds subprocess screenshots under FleetView polling


def thumbnail(session, ip):
    """PNG bytes for a session's active page, cached THUMB_TTL. best-effort → b'' on error.
    The screenshot subprocess runs OUTSIDE the lock so concurrent /thumb polls for
    different sessions aren't serialized behind one ≤15s capture."""
    import subprocess
    with _thumbs_lock:
        cached = _thumbs.get(session)
        if cached and time.time() - cached[0] < THUMB_TTL:
            return cached[1]
    if not ip:
        return b""
    try:
        png = subprocess.check_output(
            ["python3", SCREENSHOT_SCRIPT, f"http://{ip}:9222"],
            timeout=15, stderr=subprocess.DEVNULL)
    except Exception:
        png = b""
    with _thumbs_lock:
        _thumbs[session] = (time.time(), png)
    return png


# ------------------------------------------------------------------ reaper
def reaper_loop():
    while True:
        try:
            now = time.time()
            for w in list_workers():
                if w["bare"]:
                    # ephemeral bare burst pod: delete if terminal (Failed on
                    # activeDeadline/OOM/crash, or Succeeded) — nothing else GCs a
                    # bare Pod (restartPolicy Never, no owner), and a lingering
                    # Failed pod keeps its session label + counts toward capacity,
                    # eventually wedging the pool at MAX_WORKERS. Also delete once
                    # idle past the TTL.
                    if w["phase"] in ("Failed", "Succeeded") or should_reap(w, now, idle_ttl=IDLE_TTL):
                        release_worker(w)
                elif w["session"]:
                    # warm-pool pod (Deployment-owned, no activeDeadlineSeconds).
                    # Two ways a claim ends without a /release, cheapest first.
                    #
                    # A heartbeating caller that has gone quiet is reclaimed in
                    # place: release_worker resets the browser and clears the
                    # label, so the pod is back in the pool warm, in ~2 minutes
                    # instead of the 60 below. Only sessions that heartbeated are
                    # eligible, so a caller that never does is untouched here.
                    if should_reclaim_session(w, now, heartbeat_timeout=HEARTBEAT_TIMEOUT):
                        release_worker(w)
                        continue
                    # Otherwise the hard cap still applies: a claim that outlives
                    # it is deleted, and the Deployment recreates a fresh standby.
                    # This is the only backstop for a caller that never
                    # heartbeats, and it also catches a pod too broken to reset.
                    try:
                        started = float(w.get("started") or now)
                    except ValueError:
                        started = now
                    if now - started > DEADLINE:
                        kube("DELETE", f"/api/v1/namespaces/{NS}/pods/{w['name']}")
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
                state, stale_age = storage_state()
            except Exception as e:
                return self._send(502, {"error": f"seed export failed: {type(e).__name__}: {e}"})
            extra = {"X-Seed-Stale-Seconds": "%.0f" % stale_age} if stale_age is not None else None
            return self._send(200, state, extra=extra)
        if path == "/thumb":
            from urllib.parse import parse_qs, urlparse
            sess = parse_qs(urlparse(self.path).query).get("session", [""])[0]
            pod = next((w for w in list_workers() if w["session"] == sess and sess), None)
            png = thumbnail(sess, pod["ip"]) if pod else b""
            if not png:
                return self._send(204, b"", "image/png")
            return self._send(200, png, "image/png")
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
        if path == "/heartbeat":
            pod = next((w for w in list_workers() if w["session"] == body.get("session")), None)
            if pod:
                heartbeat_worker(pod["name"])
            # 200 either way: a caller heartbeating a session the reaper already
            # took should log and carry on, not crash on its way out.
            return self._send(200, {"alive": bool(pod)})
        return self._send(404, {"error": "not found"})

    def _acquire(self, body):
        owner = str(body.get("owner", "unknown"))[:63]
        purpose = str(body.get("purpose", ""))[:200]
        import secrets
        session = secrets.token_hex(4)
        # Pick-or-create under the lock so two concurrent acquires can't grab the
        # same free worker or both burst past MAX_WORKERS. The pod-ready WAIT is
        # done outside the lock (it's seconds — don't block other acquires on it).
        with _acquire_lock:
            workers = list_workers()
            free = pick_free_worker(workers)
            if free:
                claim_worker(free["name"], session, owner, purpose)
                # podIP lets an IN-CLUSTER caller dial CDP directly; the devvm
                # CLI keeps port-forwarding to pod/<name> as before. Deliberately
                # not added to /sessions, which redacts it for browser-facing
                # FleetView.
                return self._send(200, {"pod": free["name"], "cdpPort": 9222,
                                        "podIP": free.get("ip", ""),
                                        "session": session, "reused": True})
            # Count only NON-terminal pods toward capacity (Failed/Succeeded orphans
            # are GC'd by the reaper and must not wedge the pool).
            active = sum(1 for w in workers if w["phase"] not in ("Failed", "Succeeded"))
            if active >= MAX_WORKERS:
                return self._send(503, {"error": f"pool at capacity ({MAX_WORKERS}); retry shortly"})
            name = worker_name(session)
            try:
                create_worker(session, owner, purpose)
            except Exception as e:
                return self._send(500, {"error": f"create worker: {e}"})
        try:
            worker = wait_ready(name)
        except Exception as e:
            return self._send(500, {"error": f"worker not ready: {e}"})
        return self._send(200, {"pod": name, "cdpPort": 9222,
                                "podIP": worker.get("ip", ""),
                                "session": session, "reused": False})

    def _serve_static(self, path):
        # Allowlist static asset extensions — STATIC_DIR also holds broker.py,
        # cdp_cookies.py, screenshot.py, worker_pod.json (mounted in the same
        # ConfigMap dir); anything not an allowlisted asset → SPA fallback so the
        # broker's own source is never served.
        allowed = (".html", ".css", ".js", ".png", ".svg", ".ico", ".woff2")
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        full = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not (full.startswith(STATIC_DIR + os.sep) and rel.endswith(allowed) and os.path.isfile(full)):
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
