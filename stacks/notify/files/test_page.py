"""Tests for the settings page. Run: python3 -m unittest"""

import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

import page
import subs

URL = "https://notify.example"
CATALOG = [
    {"name": "R730 Host", "alerts": [
        {"name": "HighCPUTemperature", "summary": "CPU <hot>", "severity": "warning"},
        {"name": "SSDHighWriteRate", "summary": "", "severity": ""},
    ]},
    {"name": "Storage", "alerts": [{"name": "PVFillingUp", "summary": "PV filling", "severity": "warning"}]},
]


class StubRules:
    def catalog(self):
        return CATALOG

    def groups_of(self, name):
        return [g["name"] for g in CATALOG for a in g["alerts"] if a["name"] == name]

    def rule(self, name):
        if name != "PVFillingUp":
            return None
        return {
            "name": "PVFillingUp",
            "query": "used / capacity > 0.85",
            "labels": {"severity": "warning"},
            "annotations": {"summary": "PV {{ $labels.pvc }} is {{ $value | humanizePercentage }} full", "description": "Grow it."},
            "alerts": [],
        }


class StubProm:
    def query(self, expr, at=None):
        return [{"metric": {"pvc": "immich"}, "value": 0.5}] if expr == "used / capacity" else []

    def values(self, label, metrics):
        return []


class StubApprise:
    def __init__(self):
        self.sent = []
        self.result = "sent"

    def send(self, notification, tags):
        self.sent.append((notification, tags))
        return self.result


class StubSlack:
    def __init__(self):
        self.sent = []

    def post(self, target, body):
        self.sent.append((target, body))
        return "sent"


class StubDirectory:
    def __init__(self):
        self.users = {
            "me@example.com": {
                "pk": 7,
                "username": "me@example.com",
                "email": "me@example.com",
                "attributes": {"other": 1, "notify": {
                    "push_instance": "ha-london",
                    "push_service": "mobile_app_my_phone",
                    "slack_target": "U01ABCDEF",
                    "groups": {"R730 Host": "push"},
                    "alerts": {"SSDHighWriteRate": "off", "DevvmJournalSilent": ["email", "slack"]},
                }},
            }
        }
        self.saved = []
        self.down = False

    def user(self, username):
        if self.down:
            raise subs.Unavailable("down")
        return self.users.get(username)

    def update(self, username, change):
        user = self.user(username)
        if user is None:
            raise subs.Invalid("No account found for %s." % username)
        notify = change(user)
        self.saved.append((user["pk"], notify))
        user["attributes"]["notify"] = notify
        return notify


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class PageTest(unittest.TestCase):
    def setUp(self):
        fd, self.proof_file = tempfile.mkstemp()
        os.write(fd, b"proof123\n")
        os.close(fd)
        self.directory = StubDirectory()
        self.apprise = StubApprise()
        self.slack = StubSlack()
        self.server = page.make_server(("127.0.0.1", 0), self.directory, StubRules(), self.proof_file, URL,
                                       self.apprise, StubProm(), slack_client=self.slack)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        os.unlink(self.proof_file)

    def request(self, path, data=None, proof="proof123", user="me@example.com", origin=URL, groups=""):
        headers = {}
        if proof:
            headers["X-Notify-Ingress-Proof"] = proof
        if user:
            headers["X-authentik-username"] = user
        if origin:
            headers["Origin"] = origin
        if groups:
            headers["X-authentik-groups"] = groups
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        req = urllib.request.Request(self.base + path, body, headers)
        try:
            resp = urllib.request.build_opener(NoRedirect).open(req)
            return resp.status, resp.read().decode(), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(), e.headers

    # --- who may see it ---

    def test_without_ingress_proof_is_refused(self):
        self.assertEqual(self.request("/", proof=None)[0], 403)
        self.assertEqual(self.request("/", proof="guess")[0], 403)

    def test_without_identity_is_refused(self):
        self.assertEqual(self.request("/", user=None)[0], 403)

    def test_unknown_account_is_refused(self):
        self.assertEqual(self.request("/", user="stranger@example.com")[0], 403)

    def test_authentik_down_is_503(self):
        self.directory.down = True
        self.assertEqual(self.request("/")[0], 503)

    # --- what it shows ---

    def test_full_page_rows_carry_their_stored_choice(self):
        status, html, _ = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("CPU &lt;hot&gt;", html)
        self.assertNotIn("CPU <hot>", html)
        self.assertIn('name="g:R730 Host" value="push"', html)
        self.assertIn('name="a:SSDHighWriteRate" value=""', html)
        self.assertIn('name="a:HighCPUTemperature" value="inherit"', html)
        self.assertIn('name="o:a:HighCPUTemperature" value="inherit"', html)
        self.assertIn('name="default" value=""', html)
        self.assertIn('value="U01ABCDEF"', html)
        self.assertIn('placeholder="me@example.com"', html)
        self.assertEqual(html.count('data-ch="slack"'), html.count('data-ch="push"'))

    def test_hidden_rows_stay_disabled_until_changed(self):
        _, html, _ = self.request("/")
        self.assertIn('name="a:HighCPUTemperature" value="inherit" disabled', html)

    def test_chosen_alerts_outside_any_group_are_listed(self):
        _, html, _ = self.request("/")
        self.assertIn('name="a:DevvmJournalSilent" value="email,slack"', html)

    def test_alert_page_shows_what_you_get_now_and_compares_with_what_is_stored(self):
        status, html, _ = self.request("/a/HighCPUTemperature")
        self.assertEqual(status, 200)
        self.assertIn('name="a:HighCPUTemperature" value="push"', html)
        self.assertIn('name="o:a:HighCPUTemperature" value="inherit"', html)
        self.assertIn('name="g:R730 Host" value="push"', html)
        self.assertIn('name="next" value="/a/HighCPUTemperature"', html)

    def test_alert_page_for_an_alert_outside_any_group(self):
        status, html, _ = self.request("/a/SomeLokiAlert")
        self.assertEqual(status, 200)
        self.assertIn('name="a:SomeLokiAlert" value=""', html)
        self.assertNotIn('name="g:', html)

    def test_alert_page_refuses_a_bad_name(self):
        self.assertEqual(self.request("/a/%3Cscript%3E")[0], 404)

    def test_how_it_works(self):
        status, html, _ = self.request("/how")
        self.assertEqual(status, 200)
        self.assertIn("<svg", html)
        self.assertIn("NotifyPipeDown", html)
        _, main, _ = self.request("/")
        self.assertIn('href="/how"', main)

    def test_slack_help_mentions_channels_for_admins_only(self):
        _, html, _ = self.request("/")
        self.assertNotIn("#alerts", html)
        _, html, _ = self.request("/", groups="Home Users|Home Server Admins")
        self.assertIn("#alerts", html)

    def test_hidden_attribute_beats_display_rules(self):
        _, html, _ = self.request("/")
        self.assertIn("[hidden]{display:none!important}", html)

    def test_saved_banner(self):
        _, html, _ = self.request("/?saved=1")
        self.assertIn("Saved.", html)

    # --- saving ---

    def test_save_writes_lists_and_redirects(self):
        status, _, headers = self.request("/save", {"a:PVFillingUp": "push,slack", "o:a:PVFillingUp": "inherit", "next": "/a/PVFillingUp"})
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/a/PVFillingUp?saved=1")
        pk, notify = self.directory.saved[0]
        self.assertEqual(pk, 7)
        self.assertEqual(notify["alerts"], {"SSDHighWriteRate": [], "DevvmJournalSilent": ["email", "slack"], "PVFillingUp": ["push", "slack"]})

    def test_save_of_a_row_someone_changed_is_a_conflict(self):
        status, html, _ = self.request("/save", {"a:SSDHighWriteRate": "push", "o:a:SSDHighWriteRate": "inherit", "next": "/"})
        self.assertEqual(status, 409)
        self.assertIn("SSDHighWriteRate changed since you opened the page", html)
        self.assertEqual(self.directory.saved, [])

    def test_slack_channel_only_for_admins(self):
        status, html, _ = self.request("/save", {"slack_target": "#alerts", "next": "/"})
        self.assertEqual(status, 400)
        self.assertIn("Home Server Admins", html)
        status, _, _ = self.request("/save", {"slack_target": "#alerts", "next": "/"}, groups="Home Server Admins")
        self.assertEqual(status, 303)
        self.assertEqual(self.directory.saved[0][1]["slack_target"], "#alerts")

    def test_save_from_another_site_is_refused(self):
        self.assertEqual(self.request("/save", {"a:PVFillingUp": "push"}, origin="https://evil.example")[0], 403)
        self.assertEqual(self.request("/save", {"a:PVFillingUp": "push"}, origin=None)[0], 403)
        self.assertEqual(self.directory.saved, [])

    def test_save_never_redirects_off_site(self):
        _, _, headers = self.request("/save", {"next": "//evil.example/x"})
        self.assertEqual(headers["Location"], "/?saved=1")

    def test_invalid_form_shows_the_reason(self):
        self.directory.users["me@example.com"]["attributes"]["notify"]["push_instance"] = "none"
        status, html, _ = self.request("/save", {"g:Storage": "push", "next": "/"})
        self.assertEqual(status, 400)
        self.assertIn("Set up your phone first", html)
        self.assertEqual(self.directory.saved, [])

    def test_diff_for_the_log(self):
        self.assertEqual(
            page.diff({"alerts": {"X": "push"}, "email": "a"}, {"alerts": {"X": ["push", "slack"]}, "email": "a"}),
            {"a:X": ["push", "push,slack"]},
        )

    # --- Test button ---

    def test_test_button_on_rows(self):
        _, html, _ = self.request("/")
        self.assertIn('data-alert="PVFillingUp"', html)
        _, html, _ = self.request("/a/PVFillingUp")
        self.assertIn('data-alert="PVFillingUp"', html)

    def test_test_sends_to_every_chosen_channel(self):
        status, body, _ = self.request("/test", {"alert": "PVFillingUp", "channels": "push,slack"})
        self.assertEqual(status, 200)
        answer = json.loads(body)
        self.assertTrue(answer["ok"])
        self.assertIn("your phone and your Slack DMs", answer["message"])
        (n, tags), = self.apprise.sent
        self.assertEqual((tags, n["title"]), (["u-me-example-com-push"], "Test: PV immich is 102% full"))
        (target, msg), = self.slack.sent
        self.assertEqual(target, "U01ABCDEF")
        self.assertEqual(msg["attachments"][0]["title"], "Test: PV immich is 102% full")

    def test_test_email_carries_the_link_like_a_real_one(self):
        self.request("/test", {"alert": "PVFillingUp", "channels": "email"})
        (n, tags), = self.apprise.sent
        self.assertEqual(tags, ["u-me-example-com-email"])
        self.assertEqual(n["body"], "Grow it.\n\nChange what you get: https://notify.example/a/PVFillingUp")

    def test_test_never_posts_into_a_channel(self):
        self.directory.users["me@example.com"]["attributes"]["notify"]["slack_target"] = "#alerts"
        self.request("/test", {"alert": "PVFillingUp", "channels": "slack"})
        self.assertEqual(self.slack.sent, [])
        self.assertEqual(self.apprise.sent[0][1], ["u-me-example-com-push"])

    def test_test_without_channels_uses_the_phone_first(self):
        self.request("/test", {"alert": "PVFillingUp", "channels": ""})
        self.assertEqual(self.apprise.sent[0][1], ["u-me-example-com-push"])

    def test_test_without_any_channel_is_refused(self):
        notify = self.directory.users["me@example.com"]["attributes"]["notify"]
        notify.update(push_instance="none", slack_target="")
        self.directory.users["me@example.com"]["email"] = ""
        status, body, _ = self.request("/test", {"alert": "PVFillingUp"})
        self.assertEqual(status, 400)
        self.assertIn("Set up a phone", json.loads(body)["message"])

    def test_test_of_an_alert_outside_the_rule_list(self):
        status, _, _ = self.request("/test", {"alert": "SomeLokiAlert", "channels": "push"})
        self.assertEqual(status, 200)
        self.assertEqual(self.apprise.sent[0][0]["title"], "Test: SomeLokiAlert")

    def test_test_needs_the_page_origin_and_a_valid_name(self):
        self.assertEqual(self.request("/test", {"alert": "PVFillingUp"}, origin="https://evil.example")[0], 403)
        self.assertEqual(self.request("/test", {"alert": "<x>"})[0], 400)
        self.assertEqual(self.apprise.sent, [])

    def test_tests_are_rate_limited(self):
        codes = [self.request("/test", {"alert": "PVFillingUp", "channels": "push"})[0] for _ in range(7)]
        self.assertEqual(codes, [200] * 6 + [429])

    def test_failed_send_is_reported(self):
        self.apprise.result = "failed"
        status, body, _ = self.request("/test", {"alert": "PVFillingUp", "channels": "push"})
        self.assertEqual(status, 502)
        self.assertFalse(json.loads(body)["ok"])


if __name__ == "__main__":
    unittest.main()
