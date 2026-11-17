"""Tests for the Alertmanager-to-Apprise adapter. Run: python3 -m unittest test_adapter"""

import json
import threading
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

import adapter

TOPICS = {"internet"}


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


class SanitizeTest(unittest.TestCase):
    def test_username_with_dot(self):
        self.assertEqual(adapter.sanitize("some.person"), "some-person")

    def test_upper_and_symbols(self):
        self.assertEqual(adapter.sanitize("  VBarzin_01!"), "vbarzin-01")


class TagTest(unittest.TestCase):
    def test_topic(self):
        self.assertEqual(adapter.tag_for({"topic": "internet"}, TOPICS), "topic-internet")

    def test_recipient(self):
        self.assertEqual(adapter.tag_for({"recipient": "some.person"}, TOPICS), "person-some-person")

    def test_topic_wins_over_recipient(self):
        labels = {"topic": "internet", "recipient": "vbarzin"}
        self.assertEqual(adapter.tag_for(labels, TOPICS), "topic-internet")

    def test_unknown_topic_is_rejected(self):
        with self.assertRaises(adapter.Rejected):
            adapter.tag_for({"topic": "nope"}, TOPICS)

    def test_neither_is_rejected(self):
        with self.assertRaises(adapter.Rejected):
            adapter.tag_for({}, TOPICS)


class BuildTest(unittest.TestCase):
    def test_firing_uses_summary_and_description(self):
        n = adapter.build(payload(topic="internet", alerts=[alert(summary="S", description="D", labels={"topic": "internet"})]), TOPICS)
        self.assertEqual(n, {"tag": "topic-internet", "title": "S", "body": "D", "type": "warning"})

    def test_notification_annotations_win(self):
        a = alert(summary="S", description="D", notification_title="T", notification_body="B")
        n = adapter.build(payload(topic="internet", alerts=[a]), TOPICS)
        self.assertEqual((n["title"], n["body"]), ("T", "B"))

    def test_body_falls_back_to_summary(self):
        n = adapter.build(payload(topic="internet", alerts=[alert(summary="S")]), TOPICS)
        self.assertEqual(n["body"], "S")

    def test_critical_is_failure_type(self):
        a = alert(labels={"severity": "critical"}, summary="S")
        n = adapter.build(payload(topic="internet", alerts=[a]), TOPICS)
        self.assertEqual(n["type"], "failure")

    def test_resolved_default_wording(self):
        n = adapter.build(payload("resolved", topic="internet", alerts=[alert("resolved", summary="S")]), TOPICS)
        self.assertEqual((n["title"], n["body"], n["type"]), ("Resolved: S", "This is no longer happening.", "success"))

    def test_resolved_annotations_win(self):
        a = alert("resolved", summary="S", notification_resolved_title="RT", notification_resolved_body="RB")
        n = adapter.build(payload("resolved", topic="internet", alerts=[a]), TOPICS)
        self.assertEqual((n["title"], n["body"]), ("RT", "RB"))

    def test_several_alerts_count_in_title_and_list_in_body(self):
        alerts = [alert(summary="A", description="dA"), alert(summary="B", description="dB")]
        n = adapter.build(payload(topic="internet", alerts=alerts), TOPICS)
        self.assertEqual(n["title"], "A (+1 more)")
        self.assertEqual(n["body"], "dA\n\ndB")

    def test_firing_group_ignores_its_resolved_members(self):
        alerts = [alert("resolved", summary="old"), alert("firing", summary="new")]
        n = adapter.build(payload("firing", topic="internet", alerts=alerts), TOPICS)
        self.assertEqual(n["title"], "new")

    def test_tag_comes_from_group_labels(self):
        n = adapter.build(payload(recipient="vbarzin"), TOPICS)
        self.assertEqual(n["tag"], "person-vbarzin")


class FakeApprise(BaseHTTPRequestHandler):
    """Answers like apprise-api: /json/urls lists tags, /notify returns a set code."""

    tags = ["topic-internet"]
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


class SendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeApprise)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeApprise.tags = ["topic-internet"]
        FakeApprise.notify_code = 200
        FakeApprise.received = []
        self.client = adapter.Apprise(self.base, "notify", "admin", "pw")

    def n(self, tag="topic-internet"):
        return {"tag": tag, "title": "T", "body": "B", "type": "warning"}

    def test_sent_with_basic_auth(self):
        self.assertEqual(self.client.send(self.n()), "sent")
        auth, body = FakeApprise.received[0]
        self.assertEqual(auth, "Basic YWRtaW46cHc=")
        self.assertEqual(body, self.n())

    def test_no_subscriber_is_not_sent(self):
        FakeApprise.tags = ["topic-other"]
        self.assertEqual(self.client.send(self.n()), "no_recipients")
        self.assertEqual(FakeApprise.received, [])

    def test_failed_dependency_is_failed(self):
        FakeApprise.notify_code = 424
        self.assertEqual(self.client.send(self.n()), "failed")

    def test_unreachable_raises(self):
        dead = adapter.Apprise("http://127.0.0.1:9", "notify", "admin", "pw")
        with self.assertRaises(adapter.Unavailable):
            dead.send(self.n())


class HandlerTest(unittest.TestCase):
    """The HTTP front: Alertmanager posts, Prometheus scrapes."""

    def setUp(self):
        self.sent = []
        outer = self

        class StubApprise:
            def send(self, notification):
                outer.sent.append(notification)
                return outer.result

        self.result = "sent"
        adapter.METRICS.clear()
        self.server = adapter.make_server(("127.0.0.1", 0), StubApprise(), TOPICS)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()

    def post(self, data):
        req = urllib.request.Request(self.base + "/alertmanager", json.dumps(data).encode(), {"Content-Type": "application/json"})
        try:
            return urllib.request.urlopen(req).status
        except urllib.error.HTTPError as e:
            return e.code

    def metrics(self):
        return urllib.request.urlopen(self.base + "/metrics").read().decode()

    def test_post_sends_and_counts(self):
        self.assertEqual(self.post(payload(topic="internet")), 200)
        self.assertEqual(len(self.sent), 1)
        self.assertIn('notify_notifications_total{result="sent"} 1', self.metrics())

    def test_rejected_is_200_and_counted(self):
        self.assertEqual(self.post(payload(topic="nope")), 200)
        self.assertEqual(self.sent, [])
        self.assertIn('notify_notifications_total{result="rejected"} 1', self.metrics())

    def test_unavailable_is_503_so_alertmanager_retries(self):
        def boom(_):
            raise adapter.Unavailable("down")

        self.server.apprise.send = boom
        self.assertEqual(self.post(payload(topic="internet")), 503)
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_failed_metric_is_exported_before_any_failure(self):
        self.assertIn('notify_notifications_total{result="failed"} 0', self.metrics())

    def test_healthz(self):
        self.assertEqual(urllib.request.urlopen(self.base + "/healthz").status, 200)


if __name__ == "__main__":
    unittest.main()
