"""Tests for the Alertmanager-to-Apprise adapter. Run: python3 -m unittest test_adapter"""

import json
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

import adapter

PAGE = "https://notify.example"


def payload(status="firing", alerts=None, **group):
    alerts = alerts or [alert(status)]
    labels = {"alertname": "R730OnBackupUplink", **group}
    return {"status": status, "groupLabels": labels, "commonLabels": labels, "alerts": alerts}


def alert(status="firing", labels=None, **annotations):
    return {
        "status": status,
        "labels": {"alertname": "R730OnBackupUplink", "severity": "warning", **(labels or {})},
        "annotations": annotations or {"summary": "R730 is on its backup uplink"},
    }


class BuildTest(unittest.TestCase):
    def test_firing_uses_summary_and_description(self):
        n = adapter.build(payload(alerts=[alert(summary="S", description="D")]))
        self.assertEqual(n, {"title": "S", "body": "D", "type": "warning"})

    def test_notification_annotations_win(self):
        a = alert(summary="S", description="D", notification_title="T", notification_body="B")
        n = adapter.build(payload(alerts=[a]))
        self.assertEqual((n["title"], n["body"]), ("T", "B"))

    def test_body_falls_back_to_summary(self):
        n = adapter.build(payload(alerts=[alert(summary="S")]))
        self.assertEqual(n["body"], "S")

    def test_critical_is_failure_type(self):
        n = adapter.build(payload(alerts=[alert(labels={"severity": "critical"}, summary="S")]))
        self.assertEqual(n["type"], "failure")

    def test_resolved_default_wording(self):
        n = adapter.build(payload("resolved", alerts=[alert("resolved", summary="S")]))
        self.assertEqual((n["title"], n["body"], n["type"]), ("Resolved: S", "This is no longer happening.", "success"))

    def test_resolved_annotations_win(self):
        a = alert("resolved", summary="S", notification_resolved_title="RT", notification_resolved_body="RB")
        n = adapter.build(payload("resolved", alerts=[a]))
        self.assertEqual((n["title"], n["body"]), ("RT", "RB"))

    def test_several_alerts_count_in_title_and_list_in_body(self):
        n = adapter.build(payload(alerts=[alert(summary="A", description="dA"), alert(summary="B", description="dB")]))
        self.assertEqual(n["title"], "A (+1 more)")
        self.assertEqual(n["body"], "dA\n\ndB")

    def test_firing_group_ignores_its_resolved_members(self):
        n = adapter.build(payload("firing", alerts=[alert("resolved", summary="old"), alert("firing", summary="new")]))
        self.assertEqual(n["title"], "new")


class RouteTest(unittest.TestCase):
    people = {
        "a@example.com": {"alerts": {"R730OnBackupUplink": "push"}, "default": "email"},
        "b@example.com": {"groups": {"R730 Host": "email"}},
    }

    def route(self, labels):
        return adapter.route(labels, self.people, lambda name: ["R730 Host"] if name == "R730OnBackupUplink" else [])

    def test_alert_goes_to_its_subscribers(self):
        self.assertEqual(self.route({"alertname": "R730OnBackupUplink"}), (["u-a-example-com-push", "u-b-example-com-email"], True))

    def test_recipient_label_goes_to_that_default_channel_only(self):
        labels = {"alertname": "R730OnBackupUplink", "recipient": "a@example.com"}
        self.assertEqual(self.route(labels), (["u-a-example-com-email"], False))

    def test_recipient_without_default(self):
        self.assertEqual(self.route({"alertname": "X", "recipient": "b@example.com"}), ([], False))

    def test_nobody_subscribed(self):
        self.assertEqual(self.route({"alertname": "Other"}), ([], True))


class FakeApprise(BaseHTTPRequestHandler):
    """Answers like apprise-api: /json/urls lists tags, /notify returns a set code."""

    tags = ["u-a-push", "u-b-email"]
    notify_code = 200
    received = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.startswith("/json/urls/notify"):
            body = json.dumps({"tags": self.tags, "urls": [{"url": "x", "tags": self.tags}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        FakeApprise.received.append((self.headers.get("Authorization"), json.loads(self.rfile.read(length))))
        self.send_response(self.notify_code)
        self.end_headers()


N = {"title": "T", "body": "B", "type": "warning"}


class SendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeApprise)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakeApprise.tags = ["u-a-push", "u-b-email"]
        FakeApprise.notify_code = 200
        FakeApprise.received = []
        self.client = adapter.Apprise(self.base, "notify", "admin", "pw")

    def test_sent_with_basic_auth_to_the_listed_tags(self):
        self.assertEqual(self.client.send(N, ["u-a-push", "u-b-email"]), "sent")
        auth, body = FakeApprise.received[0]
        self.assertEqual(auth, "Basic YWRtaW46cHc=")
        self.assertEqual(body, dict(N, tag="u-a-push, u-b-email"))

    def test_tag_apprise_lacks_is_left_out(self):
        self.assertEqual(self.client.send(N, ["u-a-push", "u-c-push"]), "sent")
        self.assertEqual(FakeApprise.received[0][1]["tag"], "u-a-push")

    def test_no_channel_is_not_sent(self):
        self.assertEqual(self.client.send(N, ["u-c-push"]), "no_recipients")
        self.assertEqual(self.client.send(N, []), "no_recipients")
        self.assertEqual(FakeApprise.received, [])

    def test_failed_dependency_is_failed(self):
        FakeApprise.notify_code = 424
        self.assertEqual(self.client.send(N, ["u-a-push"]), "failed")

    def test_unreachable_raises(self):
        dead = adapter.Apprise("http://127.0.0.1:9", "notify", "admin", "pw")
        with self.assertRaises(adapter.Unavailable):
            dead.send(N, ["u-a-push"])


class HandlerTest(unittest.TestCase):
    """The HTTP front: Alertmanager posts, Prometheus scrapes."""

    def setUp(self):
        self.sent = []
        self.results = ["sent", "sent"]
        outer = self

        class StubApprise:
            def send(self, notification, tags):
                outer.sent.append((notification, tags))
                return outer.results.pop(0)

        class StubDirectory:
            people = {
                "a": {"alerts": {"R730OnBackupUplink": "push"}, "default": "push"},
                "b": {"alerts": {"R730OnBackupUplink": "email"}},
            }

            def subscribers(self):
                return self.people

        class StubRules:
            def groups_of(self, name):
                return []

        adapter.METRICS.clear()
        self.server = adapter.make_server(("127.0.0.1", 0), StubApprise(), StubDirectory(), StubRules(), PAGE)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def post(self, data):
        req = urllib.request.Request(self.base + "/alertmanager", json.dumps(data).encode(), {"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req).status
        except urllib.error.HTTPError as e:
            return e.code

    def metrics(self):
        return urllib.request.urlopen(self.base + "/metrics").read().decode()

    def test_push_and_email_go_separately_and_email_carries_the_link(self):
        self.assertEqual(self.post(payload()), 200)
        (push, push_tags), (email, email_tags) = self.sent
        self.assertEqual((push_tags, push["body"]), (["u-a-push"], "R730 is on its backup uplink"))
        self.assertEqual(email_tags, ["u-b-email"])
        self.assertEqual(
            email["body"],
            "R730 is on its backup uplink\n\nChange what you get: https://notify.example/a/R730OnBackupUplink",
        )
        self.assertIn('notify_notifications_total{result="sent"} 1', self.metrics())

    def test_one_failed_channel_counts_as_failed(self):
        self.results = ["sent", "failed"]
        self.post(payload())
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_recipient_send_has_no_link(self):
        self.post(payload(recipient="a"))
        self.assertEqual(self.sent, [(adapter.build(payload()), ["u-a-push"])])

    def test_nobody_subscribed_is_counted(self):
        self.assertEqual(self.post(payload(alertname="Other")), 200)
        self.assertEqual(self.sent, [])
        self.assertIn('notify_notifications_total{result="no_recipients"} 1', self.metrics())

    def test_bad_payload_is_400_and_rejected(self):
        req = urllib.request.Request(self.base + "/alertmanager", b"not json")
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(req)
        self.assertEqual(e.exception.code, 400)
        self.assertIn('notify_notifications_total{result="rejected"} 1', self.metrics())

    def test_unavailable_is_503_so_alertmanager_retries(self):
        def boom():
            raise adapter.Unavailable("down")

        self.server.directory.subscribers = boom
        self.assertEqual(self.post(payload()), 503)
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_failed_metric_is_exported_before_any_failure(self):
        self.assertIn('notify_notifications_total{result="failed"} 0', self.metrics())

    def test_healthz(self):
        self.assertEqual(urllib.request.urlopen(self.base + "/healthz").status, 200)


if __name__ == "__main__":
    unittest.main()
