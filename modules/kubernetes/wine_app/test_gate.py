"""Unit tests for gate.py. Run: python3 -m unittest discover -s modules/kubernetes/wine_app"""

import unittest
import urllib.error

import gate


class FakeKube:
    """Answers the gate's deployment GET and replicas PATCH, records patches."""

    def __init__(self, replicas=0, ready=0, fail_get=None):
        self.replicas = replicas
        self.ready = ready
        self.fail_get = fail_get
        self.patches = []

    def __call__(self, method, path, body=None):
        if not path.endswith(f"/deployments/{gate.DEPLOY}"):
            raise AssertionError(f"unexpected path {path}")
        if method == "GET":
            if self.fail_get is not None:
                raise self.fail_get
            return {"spec": {"replicas": self.replicas}, "status": {"readyReplicas": self.ready}}
        if method == "PATCH":
            self.patches.append(body)
            self.replicas = body["spec"]["replicas"]
            return {}
        raise AssertionError(f"unexpected call {method} {path}")


class HandleTest(unittest.TestCase):
    def test_ready_pod_redirects_to_vnc(self):
        kube = FakeKube(replicas=1, ready=1)
        code, headers, _ = gate.handle("/", kube)
        self.assertEqual(code, 302)
        self.assertEqual(headers["Location"], gate.VNC_PATH)
        self.assertEqual(kube.patches, [])

    def test_sleeping_pod_is_woken_and_shown_the_waiting_page(self):
        kube = FakeKube(replicas=0, ready=0)
        code, headers, body = gate.handle("/", kube)
        self.assertEqual(code, 200)
        self.assertEqual(headers["Content-Type"], "text/html")
        self.assertIn(b"refresh", body)
        self.assertEqual(kube.patches, [{"spec": {"replicas": 1}}])

    def test_starting_pod_is_not_patched_again(self):
        kube = FakeKube(replicas=1, ready=0)
        code, _, body = gate.handle("/", kube)
        self.assertEqual(code, 200)
        self.assertIn(b"starting", body)
        self.assertEqual(kube.patches, [])

    def test_status_reports_without_waking(self):
        kube = FakeKube(replicas=0, ready=0)
        code, headers, body = gate.handle("/status", kube)
        self.assertEqual(code, 200)
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(body, b'{"replicas": 0, "ready": 0}')
        self.assertEqual(kube.patches, [])

    def test_wake_endpoint_wakes_and_answers_json(self):
        kube = FakeKube(replicas=0, ready=0)
        code, _, body = gate.handle("/wake", kube)
        self.assertEqual(code, 200)
        self.assertEqual(body, b'{"replicas": 1, "ready": 0, "woke": true}')
        self.assertEqual(kube.patches, [{"spec": {"replicas": 1}}])

    def test_wake_on_running_pod_does_nothing(self):
        kube = FakeKube(replicas=1, ready=1)
        _, _, body = gate.handle("/wake", kube)
        self.assertEqual(body, b'{"replicas": 1, "ready": 1, "woke": false}')
        self.assertEqual(kube.patches, [])

    def test_healthz_does_not_call_the_api(self):
        kube = FakeKube(fail_get=AssertionError("must not be called"))
        code, _, body = gate.handle("/healthz", kube)
        self.assertEqual((code, body), (200, b"ok"))

    def test_waiting_page_names_the_app_escaped(self):
        old = gate.APP_TITLE
        gate.APP_TITLE = "iVMS <4200>"
        try:
            _, _, body = gate.handle("/", FakeKube(replicas=0, ready=0))
        finally:
            gate.APP_TITLE = old
        self.assertIn(b"Starting iVMS &lt;4200&gt;", body)

    def test_api_error_is_a_readable_502(self):
        err = urllib.error.HTTPError("x", 403, "Forbidden", None, None)
        code, _, body = gate.handle("/", FakeKube(fail_get=err))
        self.assertEqual(code, 502)
        self.assertIn(b"403", body)


if __name__ == "__main__":
    unittest.main()
