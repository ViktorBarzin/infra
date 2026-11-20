"""Tests for the Slack Channel. Run: python3 -m unittest"""

import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import slack
import subs

PAGE = "https://notify.example"


def group(status="firing", alerts=None, **labels):
    labels = {"alertname": "PVFillingUp", **labels}
    alerts = alerts or [{"status": status, "labels": dict(labels), "annotations": {"summary": "PV immich is 91% full"}}]
    return {"status": status, "groupLabels": {"alertname": labels["alertname"]}, "commonLabels": labels, "alerts": alerts}


class MessageTest(unittest.TestCase):
    def att(self, payload):
        return slack.message(payload, PAGE)["attachments"][0]

    def test_critical_like_the_old_receiver(self):
        a = self.att(group(severity="critical"))
        self.assertEqual((a["title"], a["fallback"], a["color"]), ("[CRITICAL] PVFillingUp (1)", "CRITICAL: PVFillingUp", "danger"))
        self.assertEqual(a["text"], "• PV immich is 91% full\n<https://notify.example/a/PVFillingUp|Notify me about this>")

    def test_resolved(self):
        a = self.att(group("resolved", severity="critical"))
        self.assertEqual((a["title"], a["color"]), ("[RESOLVED] PVFillingUp (1)", "good"))

    def test_warning_is_the_default_and_info_is_blue(self):
        self.assertEqual(self.att(group())["title"], "[WARNING] PVFillingUp (1)")
        a = self.att(group(severity="info"))
        self.assertEqual((a["title"], a["color"]), ("[INFO] PVFillingUp (1)", "#439FE0"))

    def test_security_layout(self):
        alerts = [{"status": "firing", "labels": {"alertname": "BastionLogin", "lane": "security", "severity": "critical"},
                   "annotations": {"summary": "Login", "description": "From 1.2.3.4", "runbook": "docs/x.md"}}]
        a = self.att(group(alerts=alerts, alertname="BastionLogin", lane="security", severity="critical"))
        self.assertEqual((a["title"], a["color"]), ("[SECURITY/CRITICAL] BastionLogin (1)", "danger"))
        self.assertTrue(a["text"].startswith("*Login*\nFrom 1.2.3.4\nRunbook: docs/x.md\n"))

    def test_event(self):
        a = self.att(group(alertname="LondonInternetDrop", lane="event"))
        self.assertEqual(a["title"], "[EVENT] LondonInternetDrop")

    def test_trivy_styles_follow_the_old_routes(self):
        self.assertEqual(slack.style({"alertname": "TrivyKnownExploitedCVE", "severity": "warning"}), "critical")
        self.assertEqual(slack.style({"alertname": "UpgradeFixNotLanded", "severity": "critical"}), "warning")

    def test_count_is_every_alert_in_the_group(self):
        alerts = [{"status": "firing", "labels": {}, "annotations": {"summary": "a"}},
                  {"status": "resolved", "labels": {}, "annotations": {"summary": "b"}}]
        self.assertEqual(self.att(group(alerts=alerts))["title"], "[WARNING] PVFillingUp (2)")

    def test_title_matches_the_healthcheck_parser(self):
        import re
        tag = re.compile(r"^\[?(CRITICAL|WARNING|INFO|RESOLVED|SECURITY[/-][A-Z]+|FIRING(?::\d+)?)\]?:?\s+(\S+)")
        for p in (group(severity="critical"), group("resolved"), group(severity="info")):
            self.assertEqual(tag.match(self.att(p)["title"]).group(2), "PVFillingUp")


class FakeSlack(BaseHTTPRequestHandler):
    answers = []
    received = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        FakeSlack.received.append((self.headers.get("Authorization"), json.loads(self.rfile.read(length))))
        code, body, retry = FakeSlack.answers.pop(0) if FakeSlack.answers else (200, {"ok": True}, None)
        self.send_response(code)
        if retry:
            self.send_header("Retry-After", retry)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())


class PostTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeSlack)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d/api" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakeSlack.answers, FakeSlack.received = [], []
        fd, self.token = tempfile.mkstemp()
        os.write(fd, b"xoxb-test\n")
        os.close(fd)
        self.slept = []
        self.client = slack.Slack(self.token, base=self.base, sleep=self.slept.append)

    def tearDown(self):
        os.unlink(self.token)

    def test_posts_with_the_bot_token_to_the_target(self):
        self.assertEqual(self.client.post("#alerts", {"text": "hi"}), "sent")
        auth, body = FakeSlack.received[0]
        self.assertEqual((auth, body), ("Bearer xoxb-test", {"text": "hi", "channel": "#alerts"}))

    def test_rate_limit_waits_once_then_retries(self):
        FakeSlack.answers = [(429, {"ok": False, "error": "ratelimited"}, "1")]
        self.assertEqual(self.client.post("U01ABCDEF", {"text": "hi"}), "sent")
        self.assertEqual(self.slept, [1.0])

    def test_long_rate_limit_is_unavailable(self):
        FakeSlack.answers = [(429, {}, "30")]
        with self.assertRaises(subs.Unavailable):
            self.client.post("#alerts", {"text": "hi"})

    def test_retryable_error_twice_is_unavailable(self):
        FakeSlack.answers = [(200, {"ok": False, "error": "internal_error"}, None)] * 2
        with self.assertRaises(subs.Unavailable):
            self.client.post("#alerts", {"text": "hi"})

    def test_permanent_refusal_is_failed(self):
        FakeSlack.answers = [(200, {"ok": False, "error": "channel_not_found"}, None)]
        self.assertEqual(self.client.post("#nope", {"text": "hi"}), "failed")

    def test_unreachable_is_unavailable(self):
        dead = slack.Slack(self.token, base="http://127.0.0.1:9/api", sleep=lambda s: None)
        with self.assertRaises(subs.Unavailable):
            dead.post("#alerts", {"text": "hi"})


if __name__ == "__main__":
    unittest.main()
