"""Unit tests for gate.py. Run: python3 -m unittest discover -s stacks/android-emulator"""

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


def pod(name, phase="Pending", reason="Unschedulable", message=GPUMEM_FULL, deleting=False):
    p = {"metadata": {"name": name}, "status": {"phase": phase}}
    if reason is not None:
        p["status"]["conditions"] = [
            {"type": "PodScheduled", "status": "False", "reason": reason, "message": message}
        ]
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


if __name__ == "__main__":
    unittest.main()
