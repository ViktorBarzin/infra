"""Tests for Subscriptions, settings forms and the two API clients. Run: python3 -m unittest"""

import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import subs

GROUPS = {"PVFillingUp": ["Storage"], "HighCPUTemperature": ["R730 Host"], "SSDHighWriteRate": ["R730 Host"]}


def groups_of(name):
    return GROUPS.get(name, [])


PHONE = {"push_instance": "ha-london", "push_service": "mobile_app_some_phone"}
ALL = dict(PHONE, slack_target="U01ABCDEF")


class ChannelsForTest(unittest.TestCase):
    def test_nothing_chosen_is_off(self):
        self.assertEqual(subs.channels_for({}, "PVFillingUp", ["Storage"]), set())

    def test_group_choice_covers_its_alerts(self):
        s = {"groups": {"Storage": ["push", "slack"]}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), {"push", "slack"})

    def test_alert_choice_wins_over_group(self):
        s = {"groups": {"Storage": ["push"]}, "alerts": {"PVFillingUp": ["email"]}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), {"email"})

    def test_empty_alert_choice_silences_a_subscribed_group(self):
        s = {"groups": {"Storage": ["push"]}, "alerts": {"PVFillingUp": []}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), set())

    def test_alert_in_two_groups_gets_both(self):
        s = {"groups": {"A": ["push"], "B": ["email"]}}
        self.assertEqual(subs.channels_for(s, "X", ["A", "B"]), {"push", "email"})

    def test_old_single_words_still_read(self):
        s = {"groups": {"Storage": "push"}, "alerts": {"Other": "off"}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), {"push"})
        self.assertEqual(subs.channels_for(s, "Other", ["Storage"]), set())

    def test_unknown_values_are_ignored(self):
        s = {"groups": {"Storage": "sms"}, "alerts": {"PVFillingUp": "pager", "X": ["push", "fax"]}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), set())
        self.assertEqual(subs.channels_for(s, "X", []), {"push"})


class TargetsTest(unittest.TestCase):
    people = {
        "some.person@example.com": {"groups": {"Storage": ["push", "slack"]}},
        "other@example.com": {"alerts": {"PVFillingUp": ["email"]}, "default": ["push", "email"]},
        "nobody@example.com": {"default": "off"},
    }

    def test_channel_tag(self):
        self.assertEqual(subs.channel_tag("Some.Person@example.com", "push"), "u-some-person-example-com-push")

    def test_alert_reaches_every_subscriber_on_every_channel(self):
        self.assertEqual(
            subs.targets_for_alert(self.people, "PVFillingUp", ["Storage"]),
            [("other@example.com", "email"), ("some.person@example.com", "push"), ("some.person@example.com", "slack")],
        )

    def test_alert_nobody_wants(self):
        self.assertEqual(subs.targets_for_alert(self.people, "HighCPUTemperature", ["R730 Host"]), [])

    def test_recipient_gets_every_default_channel(self):
        self.assertEqual(
            subs.targets_for_recipient(self.people, "Other@Example.com"),
            [("other@example.com", "push"), ("other@example.com", "email")],
        )

    def test_recipient_with_old_single_word_default(self):
        self.assertEqual(subs.targets_for_recipient({"a@x.io": {"default": "email"}}, "a@x.io"), [("a@x.io", "email")])

    def test_recipient_without_default_gets_nothing(self):
        self.assertEqual(subs.targets_for_recipient(self.people, "nobody@example.com"), [])
        self.assertEqual(subs.targets_for_recipient(self.people, "stranger@example.com"), [])


class AvailableTest(unittest.TestCase):
    def test_all_three(self):
        self.assertEqual(subs.available(ALL, "me@example.com"), {"push", "email", "slack"})

    def test_bad_service_name_is_no_phone(self):
        self.assertEqual(subs.available({"push_instance": "ha-london", "push_service": "notify.x y"}, ""), set())

    def test_unknown_instance_is_no_phone(self):
        self.assertEqual(subs.available({"push_instance": "ha-mars", "push_service": "mobile_app_x"}, ""), set())

    def test_own_email_overrides_account_email(self):
        self.assertEqual(subs.available({"email": "not-an-address"}, "me@example.com"), set())

    def test_slack_channel_or_member(self):
        self.assertEqual(subs.slack_target({"slack_target": "#alerts"}), "#alerts")
        self.assertEqual(subs.slack_target({"slack_target": " U01ABCDEF "}), "U01ABCDEF")
        self.assertIsNone(subs.slack_target({"slack_target": "@viktor"}))


class ShowParseTest(unittest.TestCase):
    def test_show(self):
        self.assertEqual(subs.show(None), "inherit")
        self.assertEqual(subs.show(["slack", "push"]), "push,slack")
        self.assertEqual(subs.show([]), "")
        self.assertEqual(subs.show("off"), "")
        self.assertEqual(subs.show("email"), "email")

    def test_parse(self):
        self.assertEqual(subs.parse("slack,push", True), ["push", "slack"])
        self.assertEqual(subs.parse("", True), [])
        self.assertIsNone(subs.parse("inherit", True))
        with self.assertRaises(subs.Invalid):
            subs.parse("inherit", False)
        with self.assertRaises(subs.Invalid):
            subs.parse("push,sms", True)


class ApplyFormTest(unittest.TestCase):
    def apply(self, settings, form, email="me@example.com", admin=False):
        return subs.apply_form(settings, form, groups_of, email, admin)

    def test_group_choice_is_stored_as_a_list(self):
        s = self.apply(ALL, {"g:Storage": "slack,push"})
        self.assertEqual(s["groups"], {"Storage": ["push", "slack"]})

    def test_partial_form_keeps_other_settings(self):
        s = self.apply({**ALL, "groups": {"R730 Host": "email"}, "default": "push"}, {"g:Storage": "push"})
        self.assertEqual(s["groups"], {"R730 Host": ["email"], "Storage": ["push"]})
        self.assertEqual(s["default"], ["push"])
        self.assertEqual(s["push_service"], "mobile_app_some_phone")

    def test_alert_equal_to_its_group_is_not_stored(self):
        s = self.apply({**ALL, "groups": {"Storage": ["push"]}}, {"a:PVFillingUp": "push"})
        self.assertEqual(s["alerts"], {})

    def test_alert_different_from_its_group_is_stored(self):
        s = self.apply({**ALL, "groups": {"Storage": ["push"]}}, {"a:PVFillingUp": ""})
        self.assertEqual(s["alerts"], {"PVFillingUp": []})

    def test_alert_off_without_group_is_not_stored(self):
        s = self.apply({**ALL, "alerts": {"PVFillingUp": ["push"]}}, {"a:PVFillingUp": ""})
        self.assertEqual(s["alerts"], {})

    def test_inherit_clears_the_alert_choice(self):
        s = self.apply({**ALL, "alerts": {"PVFillingUp": ["email"]}}, {"a:PVFillingUp": "inherit"})
        self.assertEqual(s["alerts"], {})

    def test_changing_a_group_keeps_inherited_alerts_inherited(self):
        s = self.apply({**ALL, "groups": {"Storage": ["push"]}}, {"g:Storage": "email,slack", "a:PVFillingUp": "inherit"})
        self.assertEqual(s["groups"], {"Storage": ["email", "slack"]})
        self.assertEqual(s["alerts"], {})

    def test_group_off_is_not_stored(self):
        s = self.apply({**ALL, "groups": {"Storage": ["push"]}}, {"g:Storage": ""})
        self.assertEqual(s["groups"], {})

    def test_old_words_are_rewritten_as_lists(self):
        s = self.apply({**ALL, "groups": {"Storage": "push"}, "alerts": {"X": "email"}, "default": "email"}, {})
        self.assertEqual((s["groups"], s["alerts"], s["default"]), ({"Storage": ["push"]}, {"X": ["email"]}, ["email"]))

    def test_alert_outside_any_group_can_be_chosen(self):
        s = self.apply(ALL, {"a:DevvmJournalSilent": "push,slack"})
        self.assertEqual(s["alerts"], {"DevvmJournalSilent": ["push", "slack"]})

    def test_old_topics_are_dropped(self):
        s = self.apply({**ALL, "topics": {"internet": "push"}}, {})
        self.assertNotIn("topics", s)

    def test_channel_fields(self):
        form = {"push_instance": "ha-sofia", "push_service": " notify.mobile_app_x ", "email": "a@b.co", "default": "email,slack", "slack_target": "U01ABCDEF"}
        s = self.apply({}, form)
        self.assertEqual(
            {k: s[k] for k in form},
            {"push_instance": "ha-sofia", "push_service": "mobile_app_x", "email": "a@b.co", "default": ["email", "slack"], "slack_target": "U01ABCDEF"},
        )

    def test_slack_channel_needs_an_admin(self):
        with self.assertRaisesRegex(subs.Invalid, "Home Server Admins"):
            self.apply({}, {"slack_target": "#alerts"})
        self.assertEqual(self.apply({}, {"slack_target": "#alerts"}, admin=True)["slack_target"], "#alerts")

    def test_bad_values_are_refused(self):
        for form in (
            {"push_instance": "ha-mars"},
            {"push_service": "mobile app"},
            {"email": "not an address"},
            {"slack_target": "@viktor"},
            {"default": "sms"},
            {"g:Storage": "sms"},
            {"g:Storage": "inherit"},
            {"a:PVFillingUp": "push,sms"},
            {"a:bad name!": "push"},
        ):
            with self.subTest(form=form), self.assertRaises(subs.Invalid):
                self.apply(ALL, form)

    def test_channel_not_set_up_is_refused(self):
        with self.assertRaisesRegex(subs.Invalid, "phone"):
            self.apply({}, {"g:Storage": "push"})
        with self.assertRaisesRegex(subs.Invalid, "email"):
            self.apply({}, {"a:PVFillingUp": "email"}, email="")
        with self.assertRaisesRegex(subs.Invalid, "Slack"):
            self.apply(PHONE, {"a:PVFillingUp": "slack"})

    def test_row_changed_by_someone_else_is_a_conflict(self):
        stored = {**ALL, "alerts": {"PVFillingUp": ["email"]}}
        with self.assertRaisesRegex(subs.Conflict, "PVFillingUp"):
            self.apply(stored, {"a:PVFillingUp": "push", "o:a:PVFillingUp": "inherit"})
        s = self.apply(stored, {"a:PVFillingUp": "push", "o:a:PVFillingUp": "email"})
        self.assertEqual(s["alerts"], {"PVFillingUp": ["push"]})

    def test_group_and_default_conflicts(self):
        with self.assertRaises(subs.Conflict):
            self.apply({**ALL, "groups": {"Storage": ["push"]}}, {"g:Storage": "email", "o:g:Storage": ""})
        self.apply({**ALL}, {"g:Storage": "email", "o:g:Storage": ""})
        with self.assertRaises(subs.Conflict):
            self.apply({**ALL, "default": ["push"]}, {"default": "email", "o:default": ""})

    def test_input_is_not_modified(self):
        before = {**ALL, "groups": {"Storage": ["push"]}}
        self.apply(before, {"g:Storage": ""})
        self.assertEqual(before["groups"], {"Storage": ["push"]})


def serve(handler):
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, "http://127.0.0.1:%d" % server.server_port


class FakePrometheus(BaseHTTPRequestHandler):
    calls = 0
    status = 200
    groups = [
        {"name": "Storage", "rules": [
            {"type": "alerting", "name": "PVFillingUp", "labels": {"severity": "warning"}, "annotations": {"summary": "PV {{ $labels.pvc }} is filling"}},
            {"type": "alerting", "name": "PVFillingUp", "labels": {"severity": "critical"}, "annotations": {}},
        ]},
        {"name": "R730 Host", "rules": [
            {"type": "alerting", "name": "HighCPUTemperature", "labels": {}, "annotations": {"summary": "CPU hot"}},
        ]},
        {"name": "Empty", "rules": []},
    ]

    def log_message(self, *args):
        pass

    def do_GET(self):
        FakePrometheus.calls += 1
        body = json.dumps({"status": "success", "data": {"groups": self.groups}}).encode()
        self.send_response(self.status)
        self.end_headers()
        self.wfile.write(body)


class RulesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.base = serve(FakePrometheus)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakePrometheus.calls = 0
        FakePrometheus.status = 200
        self.now = 1000.0
        self.rules = subs.Rules(self.base, clock=lambda: self.now)

    def test_catalog_is_sorted_and_deduplicated(self):
        cat = self.rules.catalog()
        self.assertEqual([g["name"] for g in cat], ["R730 Host", "Storage"])
        self.assertEqual(cat[1]["alerts"], [{"name": "PVFillingUp", "summary": "PV {{ $labels.pvc }} is filling", "severity": "warning"}])

    def test_groups_of(self):
        self.assertEqual(self.rules.groups_of("PVFillingUp"), ["Storage"])
        self.assertEqual(self.rules.groups_of("Nope"), [])

    def test_rule_returns_the_raw_rule(self):
        self.assertEqual(self.rules.rule("PVFillingUp")["labels"], {"severity": "warning"})
        self.assertIsNone(self.rules.rule("Nope"))

    def test_cached_within_ttl(self):
        self.rules.catalog()
        self.now += 100
        self.rules.catalog()
        self.assertEqual(FakePrometheus.calls, 1)

    def test_refetched_after_ttl(self):
        self.rules.catalog()
        self.now += 301
        self.rules.catalog()
        self.assertEqual(FakePrometheus.calls, 2)

    def test_unknown_alert_refetches_at_most_once_a_minute(self):
        self.rules.groups_of("Nope")
        self.rules.groups_of("Nope")
        self.assertEqual(FakePrometheus.calls, 1)
        self.now += 61
        self.rules.groups_of("Nope")
        self.assertEqual(FakePrometheus.calls, 2)

    def test_error_keeps_the_last_catalog(self):
        self.rules.catalog()
        FakePrometheus.status = 500
        self.now += 301
        self.assertEqual(len(self.rules.catalog()), 2)

    def test_error_without_catalog_is_empty(self):
        FakePrometheus.status = 500
        self.assertEqual(self.rules.catalog(), [])
        self.assertEqual(self.rules.groups_of("PVFillingUp"), [])


class FakeLoki(BaseHTTPRequestHandler):
    groups = [
        {"name": "Storage", "rules": [
            {"type": "alerting", "name": "NFSStale", "labels": {"severity": "critical"}, "annotations": {"summary": "NFS stale"}},
        ]},
        {"name": "Security", "rules": [
            {"type": "alerting", "name": "BastionLogin", "labels": {"lane": "security"}, "annotations": {}},
        ]},
    ]

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = json.dumps({"status": "success", "data": {"groups": self.groups}}).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


class TwoSourceRulesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prom, cls.prom_url = serve(FakePrometheus)
        cls.loki, cls.loki_url = serve(FakeLoki)

    @classmethod
    def tearDownClass(cls):
        for srv in (cls.prom, cls.loki):
            srv.shutdown()
            srv.server_close()

    def setUp(self):
        FakePrometheus.status = 200
        self.rules = subs.Rules([self.prom_url, self.loki_url + "/prometheus/api/v1/rules?type=alert"])

    def test_same_named_groups_merge(self):
        cat = {g["name"]: [a["name"] for a in g["alerts"]] for g in self.rules.catalog()}
        self.assertEqual(cat["Storage"], ["PVFillingUp", "NFSStale"])
        self.assertEqual(cat["Security"], ["BastionLogin"])

    def test_loki_rules_are_found(self):
        self.assertEqual(self.rules.groups_of("BastionLogin"), ["Security"])
        self.assertEqual(self.rules.rule("BastionLogin")["labels"], {"lane": "security"})

    def test_one_source_down_keeps_the_other(self):
        FakePrometheus.status = 500
        cat = {g["name"] for g in self.rules.catalog()}
        self.assertEqual(cat, {"Storage", "Security"})


class FakeAuthentik(BaseHTTPRequestHandler):
    users = []
    patched = []
    auth = []
    status = 200

    def log_message(self, *args):
        pass

    def answer(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        FakeAuthentik.auth.append(self.headers.get("Authorization"))
        if self.status != 200:
            return self.answer(self.status, {})
        from urllib.parse import parse_qs, urlparse

        q = parse_qs(urlparse(self.path).query)
        rows = [u for u in self.users if "username" not in q or u["username"] == q["username"][0]]
        page = int(q.get("page", ["1"])[0])
        chunk = rows[(page - 1) * 2 : page * 2]
        more = page * 2 < len(rows)
        self.answer(200, {"pagination": {"next": page + 1 if more else 0}, "results": chunk})

    def do_PATCH(self):
        length = int(self.headers["Content-Length"])
        FakeAuthentik.patched.append((self.path, json.loads(self.rfile.read(length))))
        self.answer(200, {})


class AuthentikTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.base = serve(FakeAuthentik)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakeAuthentik.users = [
            {"pk": 1, "username": "a@example.com", "email": "a@example.com", "attributes": {"notify": {"default": "push"}}},
            {"pk": 2, "username": "b@example.com", "email": "b@example.com", "attributes": {}},
            {"pk": 3, "username": "c@example.com", "email": "c@example.com", "attributes": {"notify": {"groups": {"X": "email"}}, "other": 1}},
        ]
        FakeAuthentik.patched = []
        FakeAuthentik.auth = []
        FakeAuthentik.status = 200
        fd, self.token_file = tempfile.mkstemp()
        os.write(fd, b"tok123\n")
        os.close(fd)
        self.now = 1000.0
        self.ak = subs.Authentik(self.base, self.token_file, clock=lambda: self.now)

    def tearDown(self):
        os.unlink(self.token_file)

    def test_subscribers_reads_every_page_and_keeps_notify_users(self):
        self.assertEqual(
            self.ak.subscribers(),
            {"a@example.com": {"default": "push"}, "c@example.com": {"groups": {"X": "email"}}},
        )
        self.assertEqual(FakeAuthentik.auth[0], "Bearer tok123")

    def test_subscribers_cached_for_a_minute(self):
        self.ak.subscribers()
        calls = len(FakeAuthentik.auth)
        self.now += 30
        self.ak.subscribers()
        self.assertEqual(len(FakeAuthentik.auth), calls)
        self.now += 31
        self.ak.subscribers()
        self.assertGreater(len(FakeAuthentik.auth), calls)

    def test_user(self):
        self.assertEqual(self.ak.user("c@example.com")["pk"], 3)
        self.assertIsNone(self.ak.user("zzz@example.com"))

    def test_save_patches_all_attributes_and_drops_the_cache(self):
        self.ak.subscribers()
        user = self.ak.user("c@example.com")
        self.ak.save(user, {"default": "email"})
        path, body = FakeAuthentik.patched[0]
        self.assertEqual(path, "/api/v3/core/users/3/")
        self.assertEqual(body, {"attributes": {"notify": {"default": "email"}, "other": 1}})
        calls = len(FakeAuthentik.auth)
        self.ak.subscribers()
        self.assertGreater(len(FakeAuthentik.auth), calls)

    def test_outage_uses_the_last_read_then_the_snapshot(self):
        folder = tempfile.mkdtemp()
        snap = os.path.join(folder, "people.json")
        ak = subs.Authentik(self.base, self.token_file, clock=lambda: self.now, snapshot_file=snap)
        people = ak.subscribers()
        self.assertEqual(oct(os.stat(snap).st_mode & 0o777), "0o600")
        FakeAuthentik.status = 503
        self.now += 120
        self.assertEqual(ak.subscribers(), people)
        self.assertTrue(ak.stale)
        fresh = subs.Authentik(self.base, self.token_file, snapshot_file=snap)
        self.assertEqual(fresh.subscribers(), people)
        empty = subs.Authentik(self.base, self.token_file, snapshot_file=os.path.join(folder, "none.json"))
        with self.assertRaises(subs.Unavailable):
            empty.subscribers()

    def test_update_reads_fresh_and_writes(self):
        out = self.ak.update("c@example.com", lambda u: dict(u["attributes"]["notify"], default=["email"]))
        self.assertEqual(out, {"groups": {"X": "email"}, "default": ["email"]})
        self.assertEqual(FakeAuthentik.patched[0][1]["attributes"]["notify"], out)
        with self.assertRaises(subs.Invalid):
            self.ak.update("zzz@example.com", lambda u: {})

    def test_server_error_is_unavailable(self):
        FakeAuthentik.status = 503
        with self.assertRaises(subs.Unavailable):
            self.ak.subscribers()

    def test_refused_token_is_unavailable(self):
        FakeAuthentik.status = 403
        with self.assertRaises(subs.Unavailable):
            self.ak.user("a@example.com")

    def test_unreachable_is_unavailable(self):
        dead = subs.Authentik("http://127.0.0.1:9", self.token_file)
        with self.assertRaises(subs.Unavailable):
            dead.subscribers()


if __name__ == "__main__":
    unittest.main()
