"""Wake gate for the android-emulator deployment.

Owns `/` on the emulator hostnames: if the emulator is up, redirect to the
noVNC screen; if it is scaled to zero, scale it to 1 and show a self-refreshing
"waking up" page. Agents use GET /status (JSON) + GET /wake. Pure stdlib —
runs on a stock python image with no installs.

It also makes the emulator yield its GPU seat. A background thread lists the
pods labelled YIELD_SELECTOR in each YIELD_NAMESPACE (the app's Transcoder) and,
when one waits Pending because k8s-node1 has no gpumem left, scales the
emulator to 0, so the waiting pod gets the 800 the emulator held. While a pod
waits, /wake does not scale the emulator up again. This covers every way that
Transcoder rolls (its deploy pipeline, Reloader, a Terraform apply), not only
the pipeline that sleeps the emulator itself.

A pod that still waits after YIELD_LIMIT_SECONDS is short of more than the
emulator's 800, so the gate stops holding the emulator asleep for it, logs
why, and wakes it as usual. /healthz reports whether the watcher thread is
alive and fails when it is not.

Someone testing on the emulator claims it on the presence board
(`presence claim service:android-emulator`). Before the gate puts an awake
emulator to sleep for a waiting pod, it reads those claims from Dolt; while
one is active it waits, for at most CLAIM_WAIT_SECONDS, and posts to #alerts
when it starts waiting and when it gives up waiting. A claim store it cannot
read does not hold anything up. GET /claim answers the same question for the
tv deploy pipeline, which waits the same way before its own sleep.
"""
import datetime
import json
import os
import socket
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


def parse_namespaces(value):
    """YIELD_NAMESPACE is a comma-separated list, the tv app's namespace by
    default; a namespace that cannot be read is skipped."""
    if value is None:
        value = "tv"
    return [ns.strip() for ns in value.split(",") if ns.strip()]


YIELD_NAMESPACES = parse_namespaces(os.environ.get("YIELD_NAMESPACE"))
YIELD_NAMESPACE = ",".join(YIELD_NAMESPACES)
YIELD_SELECTOR = os.environ.get("YIELD_SELECTOR", "android-emulator-yields-to=gpu-seat")
YIELD_INTERVAL_SECONDS = float(os.environ.get("YIELD_INTERVAL_SECONDS", "10"))
# How long one pod may keep the emulator asleep. With the emulator asleep a
# Transcoder surge pod schedules within seconds; one that still waits after
# this is short of more than the emulator's 800 gpumem.
YIELD_LIMIT_SECONDS = float(os.environ.get("YIELD_LIMIT_SECONDS", "900"))
# The scheduler's FailedScheduling message names the resource a pod is short
# of; only this one is something the emulator can give back.
GPU_SEAT_SHORTAGE = "Insufficient viktorbarzin.me/gpumem"

# The presence board (/usr/local/bin/presence on the devvm, infra
# playbooks/files/devvm/presence) keeps claims in Dolt's `beads` database. The
# board's own user has no password and is reachable only in-cluster.
CLAIM_DB_HOST = os.environ.get("CLAIM_DB_HOST", "dolt.beads-server.svc.cluster.local")
CLAIM_DB_PORT = int(os.environ.get("CLAIM_DB_PORT", "3306"))
CLAIM_DB_USER = os.environ.get("CLAIM_DB_USER", "beads")
CLAIM_DB_NAME = os.environ.get("CLAIM_DB_NAME", "beads")
CLAIM_DB_TIMEOUT_SECONDS = 3.0
# service:android-emulator is the label; notes before 2026-10-31 used
# infra:android-emulator. A claim is active until its expires_at, which the
# holder's hooks push 15 min ahead on every tool call.
CLAIM_QUERY = (
    "SELECT session_id, user, host, purpose, claimed_at FROM presence_claims"
    " WHERE resource_label IN ('service:android-emulator', 'infra:android-emulator')"
    " AND expires_at > NOW(3) ORDER BY claimed_at"
)
# How long an active claim holds off the yield-sleep (Viktor, 2026-11-02:
# a bounded wait, not a veto, since the emulator yields to deploys).
CLAIM_WAIT_SECONDS = float(os.environ.get("CLAIM_WAIT_SECONDS", "480"))
# The #alerts incoming webhook; without it the gate only logs.
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK", "")

# What the watcher saw last, whether a /wake was held back for it, when each
# waiting pod was first seen, and which pods passed the limit. claim_wait is
# the current wait for a presence claim: when it started, and whether it is
# over for this set of waiting pods; held_until is the last pass that held
# off for a claim, from which the yield limit counts. The handler threads and
# the watcher thread share it.
_yield_lock = threading.Lock()
_yield_state = {
    "waiters": [],
    "wake_held": False,
    "first_seen": {},
    "gave_up": [],
    "claim_wait": {"since": None, "over": False},
    "held_until": None,
}
# The watcher thread and the wall-clock time its last pass finished, for /healthz.
_watcher = {"thread": None, "last_pass": None}


def reset_yield_state():
    with _yield_lock:
        _yield_state["waiters"] = []
        _yield_state["wake_held"] = False
        _yield_state["first_seen"] = {}
        _yield_state["gave_up"] = []
        _yield_state["claim_wait"] = {"since": None, "over": False}
        _yield_state["held_until"] = None


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
    # A namespace that cannot be read (absent, or no Role there yet) is
    # skipped as long as another one answers; when none does, the first error
    # is raised, which is what callers treat as "could not list".
    waits, errors = [], []
    for ns in YIELD_NAMESPACES:
        try:
            pods = kube_fn("GET", f"/api/v1/namespaces/{ns}/pods?{query}")
        except Exception as e:
            errors.append(e)
            continue
        waits.extend(seat_waits(pods.get("items") or []))
    if errors and len(errors) == len(YIELD_NAMESPACES):
        raise errors[0]
    return waits


def within_limit(waits, now, log):
    """The waiting pods the emulator still yields to.

    A pod that has waited YIELD_LIMIT_SECONDS or longer, counted from its
    PodScheduled timestamp (or from when the gate first saw it, or from the
    last pass that held off for a presence claim, whichever is latest), is
    dropped and recorded in gave_up; the reason is logged once per pod.
    """
    holding, expired, newly = [], [], []
    with _yield_lock:
        first_seen = _yield_state["first_seen"]
        current = {name for name, _ in waits}
        for name in list(first_seen):
            if name not in current:
                del first_seen[name]
        wait = _yield_state["claim_wait"]
        if wait["since"] is not None and not wait["over"]:
            held_until = now  # a claim is holding the emulator awake right now
        else:
            held_until = _yield_state["held_until"] or 0
        for name, since in waits:
            seen = first_seen.setdefault(name, now)
            # Time spent awake for a presence claim does not count.
            waited = now - max(since if since is not None else seen, held_until)
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


def yield_once(kube_fn, log, now=None, claims_fn=None, notify=None):
    """One pass of the yield watcher. Returns the waiting pods it yields to.

    claims_fn reads the active presence claims on the emulator (read_claims);
    without it no claim holds anything off. notify posts one line to #alerts.

    Never raises: a failed read leaves the emulator as it is, and a failed
    patch is logged and retried on the next pass.
    """
    now = time.time() if now is None else now
    try:
        waits = list_seat_waiters(kube_fn)
    except Exception as e:
        log(f"yield: could not list pods in {YIELD_NAMESPACE} ({describe(e)}); leaving the emulator as it is")
        return []
    waiters = within_limit(waits, now, log)
    with _yield_lock:
        _yield_state["waiters"] = list(waiters)
        wake_held = _yield_state["wake_held"] and not waiters
        if wake_held:
            _yield_state["wake_held"] = False
        if not waiters:
            _yield_state["claim_wait"] = {"since": None, "over": False}
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
            if claims_fn is not None and claim_holds_off(claims_fn, waiters, now, log, notify or (lambda _: None)):
                return waiters
            log(
                f"yield: {', '.join(waiters)} in {YIELD_NAMESPACE} is waiting for a GPU seat; "
                "putting the emulator to sleep (replicas -> 0). Whoever is using it is cut off; "
                "the gate wakes it on the next visit once nothing waits"
            )
            sleep_emulator(kube_fn)
    except Exception as e:
        log(f"yield: could not put the emulator to sleep ({describe(e)}); retrying next pass")
    return waiters


def claim_holds_off(claims_fn, waiters, now, log, notify):
    """True while an active presence claim keeps the awake emulator up.

    The wait starts the first time a claim is seen for this set of waiting
    pods and lasts at most CLAIM_WAIT_SECONDS. Once the claim is released or
    the wait runs out, the emulator sleeps and this set of pods is not held
    off again. A claim store that cannot be read holds nothing off.
    """
    with _yield_lock:
        wait = _yield_state["claim_wait"]
        if wait["over"]:
            return False
    try:
        claims = claims_fn()
    except Exception as e:
        log(f"yield: could not read the emulator's presence claims ({describe(e)}); putting it to sleep as before")
        claims = []
    pods = ", ".join(waiters)
    limit = int(CLAIM_WAIT_SECONDS // 60)
    if not claims:
        if wait["since"] is not None:
            log("yield: the presence claim on the emulator was released; putting it to sleep now")
        with _yield_lock:
            if wait["since"] is not None:
                _yield_state["held_until"] = now
            wait["over"] = True
        return False
    holders = describe_holders(claims)
    if wait["since"] is None:
        with _yield_lock:
            wait["since"] = now
            _yield_state["held_until"] = now
        line = (
            f"Android emulator: {pods} in {YIELD_NAMESPACE} is waiting for the emulator's GPU seat, "
            f"but {holders} holds a presence claim on the emulator. The gate waits up to {limit} min "
            "for the claim to be released before it puts the emulator to sleep."
        )
        log("yield: " + line)
        notify(line)
        return True
    if now - wait["since"] >= CLAIM_WAIT_SECONDS:
        with _yield_lock:
            wait["over"] = True
            _yield_state["held_until"] = now
        line = (
            f"Android emulator: {holders} still holds the presence claim after {limit} min; "
            f"the gate is putting the emulator to sleep anyway so {pods} can start."
        )
        log("yield: " + line)
        notify(line)
        return False
    with _yield_lock:
        _yield_state["held_until"] = now
    return True


class ClaimStoreError(Exception):
    """The claim store answered, but not with rows."""


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ClaimStoreError("connection closed by the server")
        buf += chunk
    return buf


def _read_packet(sock):
    head = _recv_exact(sock, 4)
    return head[3], _recv_exact(sock, int.from_bytes(head[:3], "little"))


def _send_packet(sock, seq, payload):
    sock.sendall(len(payload).to_bytes(3, "little") + bytes([seq & 0xFF]) + payload)


def _lenenc(data, pos):
    """A length-encoded integer at data[pos]: (value or None for NULL, next pos)."""
    first = data[pos]
    if first < 0xFB:
        return first, pos + 1
    if first == 0xFB:
        return None, pos + 1
    size = {0xFC: 2, 0xFD: 3, 0xFE: 8}[first]
    return int.from_bytes(data[pos + 1 : pos + 1 + size], "little"), pos + 1 + size


def _server_error(payload):
    code = int.from_bytes(payload[1:3], "little")
    message = payload[9:] if payload[3:4] == b"#" else payload[3:]
    return ClaimStoreError(f"mysql error {code}: {message.decode('utf-8', 'replace')}")


def mysql_query(host, port, user, database, query, timeout=CLAIM_DB_TIMEOUT_SECONDS):
    """Rows of one text-protocol query, each a list of str or None.

    Just enough of the MySQL client protocol for a passwordless login, so the
    gate stays on a stock python image: handshake, an auth switch answered
    with an empty password, one COM_QUERY, COM_QUIT. Raises OSError or
    ClaimStoreError.
    """
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        seq, hello = _read_packet(sock)
        if hello[:1] == b"\xff":
            raise _server_error(hello)
        if hello[:1] != b"\x0a":
            raise ClaimStoreError("not a MySQL v10 handshake")
        # LONG_PASSWORD | CONNECT_WITH_DB | PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH
        caps = 0x1 | 0x8 | 0x200 | 0x8000 | 0x80000
        login = (
            caps.to_bytes(4, "little")
            + (1 << 24).to_bytes(4, "little")
            + bytes([45])  # utf8mb4_general_ci
            + bytes(23)
            + user.encode() + b"\x00"
            + b"\x00"  # empty auth response
            + database.encode() + b"\x00"
            + b"mysql_native_password\x00"
        )
        _send_packet(sock, seq + 1, login)
        seq, reply = _read_packet(sock)
        while reply[:1] in (b"\xfe", b"\x01"):
            if reply[:1] == b"\xfe":
                # Auth switch: an empty password answers with nothing.
                _send_packet(sock, seq + 1, b"")
            seq, reply = _read_packet(sock)
        if reply[:1] == b"\xff":
            raise _server_error(reply)
        if reply[:1] != b"\x00":
            raise ClaimStoreError("unexpected reply to the login")
        _send_packet(sock, 0, b"\x03" + query.encode())
        _, first = _read_packet(sock)
        if first[:1] == b"\xff":
            raise _server_error(first)
        if first[:1] == b"\x00":
            return []
        columns, _ = _lenenc(first, 0)
        for _ in range(columns):
            _read_packet(sock)
        _, eof = _read_packet(sock)
        if eof[:1] != b"\xfe":
            raise ClaimStoreError("no end marker after the column definitions")
        rows = []
        while True:
            _, row = _read_packet(sock)
            if row[:1] == b"\xfe" and len(row) < 9:
                break
            if row[:1] == b"\xff":
                raise _server_error(row)
            values, pos = [], 0
            for _ in range(columns):
                n, pos = _lenenc(row, pos)
                if n is None:
                    values.append(None)
                else:
                    values.append(row[pos : pos + n].decode("utf-8", "replace"))
                    pos += n
            rows.append(values)
        try:
            _send_packet(sock, 0, b"\x01")
        except OSError:
            pass
        return rows


def _one_line(text, limit):
    return " ".join((text or "").split())[:limit]


def claim_from_row(row):
    session, user, host, purpose, claimed_at = row
    return {
        "session": session,
        "user": _one_line(user, 64),
        "host": _one_line(host, 64),
        "purpose": _one_line(purpose, 200),
        # Dolt answers "2026-11-02 22:30:00.000"; minutes are enough.
        "since": _one_line(claimed_at, 16),
    }


def read_claims():
    """The active presence claims on the emulator, oldest first."""
    rows = mysql_query(CLAIM_DB_HOST, CLAIM_DB_PORT, CLAIM_DB_USER, CLAIM_DB_NAME, CLAIM_QUERY)
    return [claim_from_row(r) for r in rows]


def describe_holder(claim):
    return f"{claim['user']}@{claim['host']} ({claim['purpose']}, since {claim['since']} UTC)"


def describe_holders(claims):
    return "; ".join(describe_holder(c) for c in claims)


def post_slack(text, webhook=None):
    """Post one line to #alerts. Logged, never raised."""
    webhook = SLACK_WEBHOOK if webhook is None else webhook
    if not webhook:
        return
    req = urllib.request.Request(
        webhook, data=json.dumps({"text": text}).encode(), headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            r.read()
    except Exception as e:
        log_line(f"yield: could not post to Slack ({describe(e)})")


def try_wake(kube_fn, now=None, log=log_line):
    """Scale the emulator up unless a pod is waiting for its GPU seat.

    Returns the waiting pods; empty means it woke the emulator. A held-back
    wake is done by the watcher once nothing waits, so an agent polling
    /status still sees the emulator come up. If the waiters cannot be read,
    it wakes anyway, so a broken grant never locks people out. A failed read
    leaves the yield limit's record alone, as yield_once does, so a pod
    already given up on is not logged again and a pod with no timestamp
    keeps its first-sight clock.
    """
    try:
        waits = list_seat_waiters(kube_fn)
    except Exception:
        wake(kube_fn)
        return []
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
        yield_once(kube, log_line, claims_fn=read_claims, notify=post_slack)
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
        if self.path == "/readyz":
            # Readiness: the HTTP server answers. It leaves out the watcher,
            # so a dead watcher does not take the gate out of its Service
            # (one replica) while the liveness probe restarts it.
            return self._respond(200, b"ok", "text/plain")
        if self.path == "/healthz":
            thread = _watcher["thread"]
            code, body = health_report(
                alive=thread is not None and thread.is_alive(),
                last_pass=_watcher["last_pass"],
                now=time.time(),
            )
            return self._respond(code, json.dumps(body).encode(), "application/json")
        if self.path == "/claim":
            # For the tv deploy pipeline: who holds the emulator, one line
            # each, empty when nobody does; 503 when Dolt cannot be read.
            try:
                claims = read_claims()
            except Exception as e:
                return self._respond(503, f"claim store unreadable: {describe(e)}\n".encode(), "text/plain")
            body = "".join(describe_holder(c) + "\n" for c in claims)
            return self._respond(200, body.encode(), "text/plain; charset=utf-8")
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
