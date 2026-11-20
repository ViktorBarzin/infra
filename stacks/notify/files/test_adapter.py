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

    def test_tag_apprise_lacks_is_a_failure_but_the_rest_still_go(self):
        self.assertEqual(self.client.send(N, ["u-a-push", "u-c-push"]), "failed")
        self.assertEqual(FakeApprise.received[0][1]["tag"], "u-a-push")

    def test_only_missing_tags_is_failed_and_nothing_sent(self):
        self.assertEqual(self.client.send(N, ["u-c-push"]), "failed")
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
        self.results = {}
        outer = self

        class StubApprise:
            def send(self, notification, tags):
                outer.sent.append(("apprise", notification, tags))
                r = outer.results.get(tags[0].rsplit("-", 1)[1], "sent")
                if r == "down":
                    raise adapter.Unavailable("down")
                return r

        class StubSlack:
            def post(self, target, body):
                outer.sent.append(("slack", target, body))
                r = outer.results.get("slack", "sent")
                if r == "down":
                    raise adapter.Unavailable("rate limited")
                return r

        class StubDirectory:
            stale = False
            people = {
                "a": {"alerts": {"R730OnBackupUplink": ["push", "slack"]}, "default": ["push"], "slack_target": "#alerts"},
                "b": {"alerts": {"R730OnBackupUplink": "email"}, "slack_target": "U01ABCDEF"},
                "c": {"alerts": {"R730OnBackupUplink": ["slack"]}, "slack_target": "#alerts"},
            }

            def subscribers(self):
                return self.people

        class StubRules:
            def groups_of(self, name):
                return []

        adapter.METRICS.clear()
        adapter.DELIVERIES.clear()
        self.server = adapter.make_server(
            ("127.0.0.1", 0), StubApprise(), StubDirectory(), StubRules(), PAGE, StubSlack(), slack_live=True,
        )
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

    def test_slack_first_once_per_target_then_push_and_email(self):
        self.assertEqual(self.post(payload()), 200)
        kinds = [(s[0], s[1] if s[0] == "slack" else s[2]) for s in self.sent]
        self.assertEqual(kinds, [("slack", "#alerts"), ("apprise", ["u-a-push"]), ("apprise", ["u-b-email"])])
        self.assertEqual(self.sent[0][2]["attachments"][0]["title"], "[WARNING] R730OnBackupUplink (1)")
        self.assertEqual(
            self.sent[2][1]["body"],
            "R730 is on its backup uplink\n\nChange what you get: https://notify.example/a/R730OnBackupUplink",
        )
        self.assertIn('notify_notifications_total{result="sent"} 1', self.metrics())
        self.assertIn('notify_deliveries_total{channel="slack",result="sent"} 1', self.metrics())

    def test_slack_down_is_503_and_the_retry_skips_what_went_out(self):
        self.results = {"slack": "down"}
        self.assertEqual(self.post(payload()), 503)
        self.assertEqual(len(self.sent), 3)
        self.results = {}
        self.sent.clear()
        self.assertEqual(self.post(payload()), 200)
        self.assertEqual([s[0] for s in self.sent], ["slack"])

    def test_a_new_notification_is_not_skipped(self):
        self.post(payload())
        self.sent.clear()
        self.post(payload("resolved", alerts=[alert("resolved")]))
        self.assertEqual(len(self.sent), 3)

    def test_permanent_failure_is_200_and_counted(self):
        self.results = {"email": "failed"}
        self.assertEqual(self.post(payload()), 200)
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_shadow_mode_never_posts_to_slack(self):
        self.server.slack_live = False
        self.post(payload())
        self.assertEqual([s[0] for s in self.sent], ["apprise", "apprise"])
        self.assertIn('notify_deliveries_total{channel="slack",result="skipped"} 1', self.metrics())

    def test_recipient_send_has_no_link_and_uses_default(self):
        self.post(payload(recipient="a"))
        self.assertEqual(self.sent, [("apprise", adapter.build(payload()), ["u-a-push"])])

    def test_unrouted_critical_is_reported_once(self):
        crit = payload(alertname="DiskOnFire", alerts=[alert(labels={"alertname": "DiskOnFire", "severity": "critical"})])
        crit["commonLabels"]["severity"] = "critical"
        self.post(crit)
        self.assertEqual(self.sent[0][0:2], ("slack", "#alerts"))
        self.assertIn("DiskOnFire", self.sent[0][2]["text"])
        self.sent.clear()
        other = dict(crit, groupKey="other")
        self.post(other)
        self.assertEqual(self.sent, [])

    def test_unrouted_warning_stays_quiet(self):
        self.assertEqual(self.post(payload(alertname="Other")), 200)
        self.assertEqual(self.sent, [])
        self.assertIn('notify_notifications_total{result="no_recipients"} 1', self.metrics())

    def test_bad_payload_is_400_and_rejected(self):
        req = urllib.request.Request(self.base + "/alertmanager", b"not json")
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(req)
        self.assertEqual(e.exception.code, 400)
        self.assertIn('notify_notifications_total{result="rejected"} 1', self.metrics())

    def test_authentik_down_without_snapshot_is_503(self):
        def boom():
            raise adapter.Unavailable("down")

        self.server.directory.subscribers = boom
        self.assertEqual(self.post(payload()), 503)
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_a_crash_is_503_and_counted(self):
        self.server.directory.subscribers = lambda: {"a": {"alerts": {"R730OnBackupUplink": ["push"]}}}
        self.server.apprise = None
        self.assertEqual(self.post(payload()), 503)
        self.assertIn('notify_notifications_total{result="failed"} 1', self.metrics())

    def test_metrics_export_zeroes_and_snapshot_gauge(self):
        m = self.metrics()
        self.assertIn('notify_notifications_total{result="failed"} 0', m)
        self.assertIn("notify_snapshot_in_use 0", m)

    def test_healthz(self):
        self.assertEqual(urllib.request.urlopen(self.base + "/healthz").status, 200)


if __name__ == "__main__":
    unittest.main()
