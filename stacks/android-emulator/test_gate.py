"""Unit tests for gate.py. Run: python3 -m unittest discover -s stacks/android-emulator"""

import datetime
import http.client
import socket
import threading
import unittest
import urllib.error
from http.server import ThreadingHTTPServer

import gate

GPUMEM_FULL = (
    "0/6 nodes are available: 1 node(s) had untolerated taint(s), "
    "4 Insufficient nvidia.com/gpu, 5 Insufficient viktorbarzin.me/gpumem. "
    "no new claims to deallocate, preemption: 0/6 nodes are available: "
    "1 Insufficient viktorbarzin.me/gpumem, 5 Preemption is not helpful for scheduling."
)
CPU_FULL = "0/6 nodes are available: 6 Insufficient cpu."
NOW = datetime.datetime(2026, 10, 18, 12, 0, tzinfo=datetime.timezone.utc).timestamp()
MINUTE = 60.0


def stamp(epoch):
    t = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def pod(name, phase="Pending", reason="Unschedulable", message=GPUMEM_FULL, deleting=False, since=None):
    p = {"metadata": {"name": name}, "status": {"phase": phase}}
    if reason is not None:
        cond = {"type": "PodScheduled", "status": "False", "reason": reason, "message": message}
        if since is not None:
            cond["lastTransitionTime"] = stamp(since)
        p["status"]["conditions"] = [cond]
    if deleting:
        p["metadata"]["deletionTimestamp"] = "2026-10-17T01:00:00Z"
    return p


class FakeKube:
    """Answers the gate's three API calls from fixed state and records patches."""

    def __init__(self, pods=(), replicas=1, ready=1, fail_pods=None, fail_patch=False, fail_namespaces=(), pods_namespace=None):
        # The pods live in one namespace, the first configured one unless
        # pods_namespace says otherwise; every other namespace is empty.
        self.pods = list(pods)
        self.pods_namespace = pods_namespace
        self.fail_namespaces = set(fail_namespaces)
        self.replicas = replicas
        self.ready = ready
        self.fail_pods = fail_pods
        self.fail_patch = fail_patch
        self.patches = []
        self.pod_paths = []

    def __call__(self, method, path, body=None):
        if path.startswith("/api/v1/namespaces/") and "/pods" in path:
            self.pod_paths.append(path)
            if self.fail_pods is not None:
                raise self.fail_pods
            if path.split("/")[4] in self.fail_namespaces:
                raise urllib.error.HTTPError(path, 403, "Forbidden", None, None)
            if path.split("/")[4] != (self.pods_namespace or gate.YIELD_NAMESPACES[0]):
                return {"items": []}
            return {"items": self.pods}
        if method == "GET":
            return {"spec": {"replicas": self.replicas}, "status": {"readyReplicas": self.ready}}
        if method == "PATCH":
            if self.fail_patch:
                raise urllib.error.HTTPError(path, 403, "Forbidden", None, None)
            self.patches.append(body)
            self.replicas = body["spec"]["replicas"]
            return {}
        raise AssertionError(f"unexpected call {method} {path}")


class SeatWaitersTest(unittest.TestCase):
    def test_pending_on_gpumem_is_a_waiter(self):
        self.assertEqual(gate.seat_waiters([pod("t-new")]), ["t-new"])

    def test_running_pod_is_not_a_waiter(self):
        self.assertEqual(gate.seat_waiters([pod("t-old", phase="Running", reason=None)]), [])

    def test_pending_for_another_resource_is_not_a_waiter(self):
        # Sleeping the emulator frees GPU seats only, so a pod short of CPU
        # would gain nothing from it.
        self.assertEqual(gate.seat_waiters([pod("t-new", message=CPU_FULL)]), [])

    def test_pending_but_not_yet_considered_is_not_a_waiter(self):
        self.assertEqual(gate.seat_waiters([pod("t-new", reason=None)]), [])

    def test_pod_being_deleted_is_not_a_waiter(self):
        self.assertEqual(gate.seat_waiters([pod("t-new", deleting=True)]), [])


class YieldOnceTest(unittest.TestCase):
    def setUp(self):
        gate.reset_yield_state()
        self.logs = []

    def run_once(self, fake):
        return gate.yield_once(fake, self.logs.append)

    def test_awake_emulator_sleeps_for_a_seat_waiter(self):
        fake = FakeKube(pods=[pod("tv-transcoder-abc")], replicas=1)
        self.assertEqual(self.run_once(fake), ["tv-transcoder-abc"])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertTrue(any("tv-transcoder-abc" in line for line in self.logs))

    def test_reads_every_configured_namespace_and_selector(self):
        fake = FakeKube()
        self.run_once(fake)
        self.assertEqual(len(fake.pod_paths), len(gate.YIELD_NAMESPACES))
        for ns, path in zip(gate.YIELD_NAMESPACES, fake.pod_paths):
            self.assertTrue(path.startswith(f"/api/v1/namespaces/{ns}/pods?"))
            self.assertIn("labelSelector=", path)
            self.assertIn("fieldSelector=status.phase%3DPending", path)

    def test_default_namespace_is_the_tv_app(self):
        self.assertEqual(gate.parse_namespaces(None), ["tv"])
        self.assertEqual(gate.parse_namespaces("tv"), ["tv"])
        self.assertEqual(gate.parse_namespaces(" f1-stream , tv ,"), ["f1-stream", "tv"])

    def test_an_unreadable_namespace_does_not_hide_the_others(self):
        # A namespace that is gone, or has no Role for the gate, must not stop
        # the gate from seeing the one that is there.
        first, second = gate.YIELD_NAMESPACES[0], "second-ns"
        saved = gate.YIELD_NAMESPACES
        gate.YIELD_NAMESPACES = [first, second]
        try:
            fake = FakeKube(pods=[pod("t-new")], replicas=1, fail_namespaces={first}, pods_namespace=second)
            self.assertEqual(self.run_once(fake), ["t-new"])
            self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        finally:
            gate.YIELD_NAMESPACES = saved

    def test_asleep_emulator_is_not_patched_again(self):
        fake = FakeKube(pods=[pod("t-new")], replicas=0)
        self.assertEqual(self.run_once(fake), ["t-new"])
        self.assertEqual(fake.patches, [])

    def test_no_waiter_leaves_the_emulator_alone(self):
        fake = FakeKube(pods=[pod("t-new", message=CPU_FULL)], replicas=1)
        self.assertEqual(self.run_once(fake), [])
        self.assertEqual(fake.patches, [])

    def test_unreadable_pods_leave_the_emulator_alone(self):
        fake = FakeKube(fail_pods=urllib.error.HTTPError("p", 403, "Forbidden", None, None))
        self.assertEqual(self.run_once(fake), [])
        self.assertEqual(fake.patches, [])
        self.assertTrue(any("403" in line for line in self.logs))

    def test_failed_patch_is_logged_not_raised(self):
        fake = FakeKube(pods=[pod("t-new")], replicas=1, fail_patch=True)
        self.assertEqual(self.run_once(fake), ["t-new"])
        self.assertTrue(any("403" in line for line in self.logs))


class WakeTest(unittest.TestCase):
    def setUp(self):
        gate.reset_yield_state()

    def test_wake_scales_up_when_nothing_waits(self):
        fake = FakeKube(replicas=0, ready=0)
        self.assertEqual(gate.try_wake(fake), [])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])

    def test_wake_holds_off_while_a_pod_waits_for_a_seat(self):
        # Waking now would hand the freed seat back to the emulator and the
        # watcher would put it to sleep again on its next pass.
        fake = FakeKube(pods=[pod("t-new")], replicas=0, ready=0)
        self.assertEqual(gate.try_wake(fake), ["t-new"])
        self.assertEqual(fake.patches, [])

    def test_held_wake_happens_once_nothing_waits(self):
        # An agent that called /wake while the Transcoder waited keeps polling
        # /status for ready; the watcher does the wake it held back.
        fake = FakeKube(pods=[pod("t-new")], replicas=0, ready=0)
        gate.try_wake(fake)
        gate.yield_once(fake, lambda line: None)
        self.assertEqual(fake.patches, [])
        fake.pods = []
        gate.yield_once(fake, lambda line: None)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])
        gate.yield_once(fake, lambda line: None)
        self.assertEqual(len(fake.patches), 1)

    def test_status_reports_what_the_emulator_yields_to(self):
        fake = FakeKube(pods=[pod("t-new")], replicas=0, ready=0)
        gate.yield_once(fake, lambda line: None)
        self.assertEqual(gate.yielding_to(), ["t-new"])
        fake.pods = []
        gate.yield_once(fake, lambda line: None)
        self.assertEqual(gate.yielding_to(), [])

    def test_wake_proceeds_when_the_waiters_cannot_be_read(self):
        fake = FakeKube(replicas=0, ready=0, fail_pods=OSError("timeout"))
        self.assertEqual(gate.try_wake(fake), [])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])


class YieldLimitTest(unittest.TestCase):
    """A pod that still waits after YIELD_LIMIT_SECONDS stops holding the emulator asleep.

    Sleeping the emulator frees 800 gpumem. A pod that waits longer than the
    limit is short of more than that (another GPU tenant took the seat), so
    keeping the emulator down helps nobody.
    """

    def setUp(self):
        gate.reset_yield_state()
        self.logs = []

    def test_limit_defaults_to_fifteen_minutes(self):
        self.assertEqual(gate.YIELD_LIMIT_SECONDS, 15 * MINUTE)

    def test_waiter_within_the_limit_still_holds_the_emulator(self):
        fake = FakeKube(pods=[pod("w-new", since=NOW - 5 * MINUTE)], replicas=1)
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW), ["w-new"])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])

    def test_waiter_past_the_limit_does_not_sleep_the_emulator(self):
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 16 * MINUTE)], replicas=1)
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW), [])
        self.assertEqual(fake.patches, [])
        self.assertEqual(gate.yielding_to(), [])
        self.assertEqual(gate.gave_up_on(), ["w-stuck"])

    def test_giving_up_is_logged_once_with_the_reason(self):
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 16 * MINUTE)], replicas=0)
        gate.yield_once(fake, self.logs.append, now=NOW)
        gate.yield_once(fake, self.logs.append, now=NOW + 10)
        mentions = [line for line in self.logs if "w-stuck" in line]
        self.assertEqual(len(mentions), 1)
        self.assertIn("15 min", mentions[0])

    def test_limit_counts_from_first_sight_when_the_pod_has_no_timestamp(self):
        fake = FakeKube(pods=[pod("w-new")], replicas=1)
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW), ["w-new"])
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW + 14 * MINUTE), ["w-new"])
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW + 16 * MINUTE), [])

    def test_held_wake_happens_when_the_waiter_passes_the_limit(self):
        # Someone asked for the emulator while the pod waited; once the gate
        # stops waiting for that pod it does the wake it held back.
        fake = FakeKube(pods=[pod("w-stuck", since=NOW)], replicas=0, ready=0)
        self.assertEqual(gate.try_wake(fake, now=NOW), ["w-stuck"])
        gate.yield_once(fake, self.logs.append, now=NOW + 10 * MINUTE)
        self.assertEqual(fake.patches, [])
        gate.yield_once(fake, self.logs.append, now=NOW + 16 * MINUTE)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])

    def test_wake_is_not_held_for_a_waiter_past_the_limit(self):
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 20 * MINUTE)], replicas=0, ready=0)
        self.assertEqual(gate.try_wake(fake, now=NOW, log=self.logs.append), [])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])

    def test_a_new_waiter_gets_its_own_limit(self):
        # The next rollout makes a new pod, which the emulator yields to again.
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 20 * MINUTE), pod("w-next", since=NOW)], replicas=1)
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW), ["w-next"])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])

    def test_gave_up_list_clears_once_the_pod_stops_waiting(self):
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 20 * MINUTE)])
        gate.yield_once(fake, self.logs.append, now=NOW)
        fake.pods = []
        gate.yield_once(fake, self.logs.append, now=NOW + 10)
        self.assertEqual(gate.gave_up_on(), [])

    def test_failed_pod_list_on_wake_keeps_the_give_up_record(self):
        # try_wake wakes anyway when it cannot read the waiters, but that
        # must not forget which pods the gate already gave up on.
        fake = FakeKube(pods=[pod("w-stuck", since=NOW - 20 * MINUTE)], replicas=0, ready=0)
        gate.yield_once(fake, self.logs.append, now=NOW)
        fake.fail_pods = OSError("api down")
        self.assertEqual(gate.try_wake(fake, now=NOW + 5, log=self.logs.append), [])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 1}}])
        self.assertEqual(gate.gave_up_on(), ["w-stuck"])
        fake.fail_pods = None
        gate.yield_once(fake, self.logs.append, now=NOW + 10)
        mentions = [line for line in self.logs if "w-stuck" in line]
        self.assertEqual(len(mentions), 1)

    def test_failed_pod_list_on_wake_keeps_the_first_sight_clock(self):
        fake = FakeKube(pods=[pod("w-new")], replicas=1)
        gate.yield_once(fake, self.logs.append, now=NOW)
        fake.fail_pods = OSError("api down")
        gate.try_wake(fake, now=NOW + 10 * MINUTE, log=self.logs.append)
        fake.fail_pods = None
        self.assertEqual(gate.yield_once(fake, self.logs.append, now=NOW + 16 * MINUTE), [])


class HealthTest(unittest.TestCase):
    def test_live_watcher_is_healthy(self):
        code, body = gate.health_report(alive=True, last_pass=NOW - 5, now=NOW)
        self.assertEqual(code, 200)
        self.assertEqual(body["yield_watcher"], "alive")
        self.assertEqual(body["last_pass_s_ago"], 5)

    def test_watcher_before_its_first_pass_is_healthy(self):
        code, body = gate.health_report(alive=True, last_pass=None, now=NOW)
        self.assertEqual(code, 200)
        self.assertEqual(body["yield_watcher"], "alive")

    def test_dead_watcher_fails_health(self):
        code, body = gate.health_report(alive=False, last_pass=NOW - 5, now=NOW)
        self.assertEqual(code, 503)
        self.assertEqual(body["yield_watcher"], "dead")

    def test_watcher_with_no_pass_for_minutes_fails_health(self):
        code, body = gate.health_report(alive=True, last_pass=NOW - 10 * MINUTE, now=NOW)
        self.assertEqual(code, 503)
        self.assertEqual(body["yield_watcher"], "stuck")


class ProbeEndpointTest(unittest.TestCase):
    """Readiness must not depend on the watcher.

    The gate runs one replica. If readiness followed /healthz, a dead watcher
    would empty the Service and stop wakes until the liveness restart.
    """

    def setUp(self):
        self.saved = dict(gate._watcher)
        gate._watcher["thread"] = None  # no watcher thread: /healthz says dead
        gate._watcher["last_pass"] = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), gate.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        gate._watcher.update(self.saved)

    def get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        conn.close()
        return resp.status

    def test_readyz_answers_ok_while_the_watcher_is_dead(self):
        self.assertEqual(self.get("/readyz"), 200)

    def test_healthz_still_fails_while_the_watcher_is_dead(self):
        self.assertEqual(self.get("/healthz"), 503)


class FakeMysql:
    """A one-connection MySQL server speaking just enough of the protocol for
    gate.mysql_query: handshake, an optional auth switch, one COM_QUERY."""

    def __init__(self, rows=(), columns=5, query_error=None, auth_switch=False, auth_error=None):
        self.rows = list(rows)
        self.columns = columns
        self.query_error = query_error
        self.auth_switch = auth_switch
        self.auth_error = auth_error
        self.login = None
        self.query = None
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    @staticmethod
    def send(conn, seq, payload):
        conn.sendall(len(payload).to_bytes(3, "little") + bytes([seq]) + payload)

    @staticmethod
    def recv(conn):
        head = b""
        while len(head) < 4:
            head += conn.recv(4 - len(head))
        n = int.from_bytes(head[:3], "little")
        body = b""
        while len(body) < n:
            body += conn.recv(n - len(body))
        return head[3], body

    @staticmethod
    def lenenc_str(value):
        if value is None:
            return b"\xfb"
        data = value.encode()
        assert len(data) < 0xFB
        return bytes([len(data)]) + data

    @staticmethod
    def error(code, message):
        return b"\xff" + code.to_bytes(2, "little") + b"#HY000" + message.encode()

    def serve(self):
        conn, _ = self.listener.accept()
        with conn:
            hello = (
                b"\x0a" + b"8.0.33\x00" + (1).to_bytes(4, "little") + b"abcdefgh" + b"\x00"
                + (0xFFFF).to_bytes(2, "little") + b"\x21" + b"\x02\x00" + (0x81FF).to_bytes(2, "little")
                + b"\x15" + bytes(10) + b"ijklmnopqrst\x00" + b"mysql_native_password\x00"
            )
            self.send(conn, 0, hello)
            seq, login = self.recv(conn)
            self.login = login
            if self.auth_switch:
                self.send(conn, seq + 1, b"\xfe" + b"mysql_native_password\x00" + b"abcdefghijklmnopqrst\x00")
                seq, _ = self.recv(conn)
            if self.auth_error:
                self.send(conn, seq + 1, self.error(1045, self.auth_error))
                return
            self.send(conn, seq + 1, b"\x00\x00\x00\x02\x00\x00\x00")
            _, query = self.recv(conn)
            self.query = query
            if self.query_error:
                self.send(conn, 1, self.error(1146, self.query_error))
                return
            seq = 1
            self.send(conn, seq, bytes([self.columns]))
            for i in range(self.columns):
                seq += 1
                self.send(conn, seq, b"\x03def" + self.lenenc_str(f"c{i}"))
            seq += 1
            self.send(conn, seq, b"\xfe\x00\x00\x02\x00")
            for row in self.rows:
                seq += 1
                self.send(conn, seq, b"".join(self.lenenc_str(v) for v in row))
            seq += 1
            self.send(conn, seq, b"\xfe\x00\x00\x02\x00")
            try:
                self.recv(conn)  # COM_QUIT
            except OSError:
                pass

    def close(self):
        self.listener.close()


ALICE = ["wizard@devvm@1234", "wizard", "devvm", "testing the TV pairing screen", "2026-11-02 22:30:00.000"]


class MysqlQueryTest(unittest.TestCase):
    """gate.mysql_query reads the presence board from Dolt with the stdlib only."""

    def run_query(self, server, query="SELECT 1"):
        try:
            return gate.mysql_query("127.0.0.1", server.port, "beads", "beads", query)
        finally:
            server.thread.join(5)
            server.close()

    def test_returns_each_row_as_strings_and_none(self):
        server = FakeMysql(rows=[ALICE, ["s2", "emo", "devvm", None, "2026-11-02 22:31:00.000"]])
        rows = self.run_query(server, "SELECT x FROM presence_claims")
        self.assertEqual(rows, [ALICE, ["s2", "emo", "devvm", None, "2026-11-02 22:31:00.000"]])
        self.assertEqual(server.query, b"\x03SELECT x FROM presence_claims")

    def test_logs_in_as_the_user_without_a_password_on_the_database(self):
        server = FakeMysql()
        self.assertEqual(self.run_query(server), [])
        self.assertIn(b"beads\x00\x00beads\x00", server.login)

    def test_follows_an_auth_switch(self):
        server = FakeMysql(rows=[ALICE], auth_switch=True)
        self.assertEqual(self.run_query(server), [ALICE])

    def test_a_refused_login_raises(self):
        with self.assertRaises(gate.ClaimStoreError):
            self.run_query(FakeMysql(auth_error="Access denied"))

    def test_a_failed_query_raises(self):
        with self.assertRaises(gate.ClaimStoreError):
            self.run_query(FakeMysql(query_error="table not found: presence_claims"))

    def test_nothing_listening_raises(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        with self.assertRaises(OSError):
            gate.mysql_query("127.0.0.1", port, "beads", "beads", "SELECT 1")

    def test_the_claim_query_covers_both_labels_and_only_live_claims(self):
        self.assertIn("'service:android-emulator'", gate.CLAIM_QUERY)
        self.assertIn("'infra:android-emulator'", gate.CLAIM_QUERY)
        self.assertIn("expires_at > NOW(3)", gate.CLAIM_QUERY)

    def test_holders_name_the_user_host_purpose_and_start(self):
        self.assertEqual(
            gate.describe_holders([gate.claim_from_row(ALICE)]),
            "wizard@devvm (testing the TV pairing screen, since 2026-11-02 22:30 UTC)",
        )

    def test_a_purpose_is_one_short_line(self):
        row = ALICE[:3] + ["line one\nline two\t" + "x" * 300, ALICE[4]]
        purpose = gate.claim_from_row(row)["purpose"]
        self.assertNotIn("\n", purpose)
        self.assertLessEqual(len(purpose), 200)


class Claims:
    """Stands in for read_claims: a list of claims, or an exception to raise."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = 0

    def __call__(self):
        self.calls += 1
        answer = self.answers[0] if len(self.answers) == 1 else self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


HELD = [gate.claim_from_row(ALICE)]


#: The gate's claim wait in whole minutes, so the tests follow the setting.
WAIT = int(gate.CLAIM_WAIT_SECONDS // 60)


class ClaimHoldsOffTest(unittest.TestCase):
    """An active presence claim on the emulator holds off the yield-sleep for
    at most CLAIM_WAIT_SECONDS, so whoever is testing is not cut off without
    warning, and nothing keeps the waiting pod off its seat for long."""

    def setUp(self):
        gate.reset_yield_state()
        self.logs = []
        self.posts = []

    def run_once(self, fake, claims, now):
        return gate.yield_once(fake, self.logs.append, now=now, claims_fn=claims, notify=self.posts.append)

    def test_the_wait_defaults_to_twenty_minutes(self):
        self.assertEqual(gate.CLAIM_WAIT_SECONDS, 8 * MINUTE)

    def test_a_claimed_emulator_stays_awake_and_says_so_once(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        claims = Claims(HELD)
        self.assertEqual(self.run_once(fake, claims, NOW), ["t-new"])
        self.assertEqual(self.run_once(fake, claims, NOW + 5 * MINUTE), ["t-new"])
        self.assertEqual(fake.patches, [])
        self.assertEqual(len(self.posts), 1)
        self.assertIn("wizard@devvm", self.posts[0])
        self.assertIn("testing the TV pairing screen", self.posts[0])
        self.assertIn("t-new", self.posts[0])
        self.assertIn(f"{WAIT} min", self.posts[0])

    def test_a_claim_released_mid_wait_lets_the_emulator_sleep(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        claims = Claims(HELD, HELD, [])
        self.run_once(fake, claims, NOW)
        self.run_once(fake, claims, NOW + 1 * MINUTE)
        self.assertEqual(fake.patches, [])
        self.run_once(fake, claims, NOW + 2 * MINUTE)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertTrue(any("released" in line for line in self.logs))

    def test_a_claim_still_held_at_the_bound_does_not_keep_the_emulator_awake(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        claims = Claims(HELD)
        self.run_once(fake, claims, NOW)
        self.run_once(fake, claims, NOW + (WAIT - 1) * MINUTE)
        self.assertEqual(fake.patches, [])
        self.run_once(fake, claims, NOW + WAIT * MINUTE)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertEqual(len(self.posts), 2)
        self.assertIn("anyway", self.posts[1])
        self.assertIn("wizard@devvm", self.posts[1])

    def test_an_unreadable_claim_store_sleeps_the_emulator_as_before(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        self.run_once(fake, Claims(ConnectionRefusedError("refused")), NOW)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertTrue(any("could not read" in line for line in self.logs))
        self.assertEqual(self.posts, [])

    def test_no_claim_sleeps_the_emulator_at_once_and_quietly(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        self.run_once(fake, Claims([]), NOW)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertEqual(self.posts, [])

    def test_an_asleep_emulator_does_not_read_the_claims(self):
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=0)
        claims = Claims(HELD)
        self.run_once(fake, claims, NOW)
        self.assertEqual(claims.calls, 0)
        self.assertEqual(self.posts, [])

    def test_nothing_waiting_does_not_read_the_claims(self):
        claims = Claims(HELD)
        self.run_once(FakeKube(replicas=1), claims, NOW)
        self.assertEqual(claims.calls, 0)

    def test_the_yield_limit_counts_from_the_end_of_the_wait(self):
        # The pod waited the whole claim wait; its 15 min with the emulator
        # asleep start once the gate puts it to sleep.
        fake = FakeKube(pods=[pod("t-new", since=NOW)], replicas=1)
        claims = Claims(HELD)
        for minute in range(0, WAIT + 1):
            self.run_once(fake, claims, NOW + minute * MINUTE)
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertEqual(self.run_once(fake, claims, NOW + (WAIT + 10) * MINUTE), ["t-new"])
        self.assertEqual(gate.gave_up_on(), [])
        self.assertEqual(self.run_once(fake, claims, NOW + (WAIT + 16) * MINUTE), [])
        self.assertEqual(gate.gave_up_on(), ["t-new"])

    def test_the_next_rollout_waits_for_a_claim_again(self):
        fake = FakeKube(pods=[pod("t-one", since=NOW)], replicas=1)
        claims = Claims(HELD)
        self.run_once(fake, claims, NOW)
        self.run_once(fake, claims, NOW + WAIT * MINUTE)
        self.assertEqual(len(fake.patches), 1)
        fake.pods = []
        self.run_once(fake, claims, NOW + (WAIT + 1) * MINUTE)
        fake.pods = [pod("t-two", since=NOW + 60 * MINUTE)]
        fake.replicas = 1
        self.run_once(fake, claims, NOW + 60 * MINUTE)
        self.assertEqual(len(fake.patches), 1)
        self.assertEqual(len(self.posts), 3)


class ClaimEndpointTest(unittest.TestCase):
    """GET /claim tells the tv deploy pipeline who holds the emulator: one line
    per claim, an empty body when nobody does, 503 when Dolt cannot be read."""

    def setUp(self):
        self.saved = gate.read_claims
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), gate.Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        gate.read_claims = self.saved
        self.server.shutdown()
        self.server.server_close()

    def get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=5)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read().decode()
        conn.close()
        return resp.status, body

    def test_names_each_holder(self):
        gate.read_claims = Claims(HELD)
        status, body = self.get("/claim")
        self.assertEqual(status, 200)
        self.assertEqual(body, "wizard@devvm (testing the TV pairing screen, since 2026-11-02 22:30 UTC)\n")

    def test_empty_when_nobody_holds_it(self):
        gate.read_claims = Claims([])
        self.assertEqual(self.get("/claim"), (200, ""))

    def test_unreadable_store_is_a_503(self):
        gate.read_claims = Claims(ConnectionRefusedError("refused"))
        status, body = self.get("/claim")
        self.assertEqual(status, 503)
        self.assertIn("refused", body)


if __name__ == "__main__":
    unittest.main()
