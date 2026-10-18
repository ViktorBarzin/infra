"""Unit tests for gate.py. Run: python3 -m unittest discover -s stacks/android-emulator"""

import datetime
import unittest
import urllib.error

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

    def __init__(self, pods=(), replicas=1, ready=1, fail_pods=None, fail_patch=False):
        self.pods = list(pods)
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
        fake = FakeKube(pods=[pod("f1-stream-transcoder-abc")], replicas=1)
        self.assertEqual(self.run_once(fake), ["f1-stream-transcoder-abc"])
        self.assertEqual(fake.patches, [{"spec": {"replicas": 0}}])
        self.assertTrue(any("f1-stream-transcoder-abc" in line for line in self.logs))

    def test_reads_the_configured_namespace_and_selector(self):
        fake = FakeKube()
        self.run_once(fake)
        self.assertEqual(len(fake.pod_paths), 1)
        path = fake.pod_paths[0]
        self.assertTrue(path.startswith(f"/api/v1/namespaces/{gate.YIELD_NAMESPACE}/pods?"))
        self.assertIn("labelSelector=", path)
        self.assertIn("fieldSelector=status.phase%3DPending", path)

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


if __name__ == "__main__":
    unittest.main()
