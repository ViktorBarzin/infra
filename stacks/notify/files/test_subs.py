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


class ChannelsForTest(unittest.TestCase):
    def test_nothing_chosen_is_off(self):
        self.assertEqual(subs.channels_for({}, "PVFillingUp", ["Storage"]), set())

    def test_group_choice_covers_its_alerts(self):
        s = {"groups": {"Storage": "push"}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), {"push"})

    def test_alert_choice_wins_over_group(self):
        s = {"groups": {"Storage": "push"}, "alerts": {"PVFillingUp": "email"}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), {"email"})

    def test_alert_off_silences_a_subscribed_group(self):
        s = {"groups": {"Storage": "push"}, "alerts": {"PVFillingUp": "off"}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), set())

    def test_alert_in_two_groups_gets_both_channels(self):
        s = {"groups": {"A": "push", "B": "email"}}
        self.assertEqual(subs.channels_for(s, "X", ["A", "B"]), {"push", "email"})

    def test_unknown_choice_is_ignored(self):
        s = {"groups": {"Storage": "sms"}, "alerts": {"PVFillingUp": "pager"}}
        self.assertEqual(subs.channels_for(s, "PVFillingUp", ["Storage"]), set())


class TagsTest(unittest.TestCase):
    people = {
        "some.person@example.com": {"groups": {"Storage": "push"}},
        "other@example.com": {"alerts": {"PVFillingUp": "email"}, "default": "push"},
        "nobody@example.com": {},
    }

    def test_channel_tag(self):
        self.assertEqual(subs.channel_tag("Some.Person@example.com", "push"), "u-some-person-example-com-push")

    def test_alert_reaches_every_subscriber(self):
        self.assertEqual(
            subs.tags_for_alert(self.people, "PVFillingUp", ["Storage"]),
            ["u-other-example-com-email", "u-some-person-example-com-push"],
        )

    def test_alert_nobody_wants(self):
        self.assertEqual(subs.tags_for_alert(self.people, "HighCPUTemperature", ["R730 Host"]), [])

    def test_recipient_gets_their_default_channel(self):
        self.assertEqual(subs.tag_for_recipient(self.people, "other@example.com"), "u-other-example-com-push")

    def test_recipient_matches_after_sanitizing(self):
        self.assertEqual(subs.tag_for_recipient(self.people, "Other@Example.com"), "u-other-example-com-push")

    def test_recipient_without_default_gets_nothing(self):
        self.assertIsNone(subs.tag_for_recipient(self.people, "nobody@example.com"))
        self.assertIsNone(subs.tag_for_recipient(self.people, "stranger@example.com"))


class AvailableTest(unittest.TestCase):
    def test_phone_and_account_email(self):
        self.assertEqual(subs.available(PHONE, "me@example.com"), {"push", "email"})

    def test_bad_service_name_is_no_phone(self):
        self.assertEqual(subs.available({"push_instance": "ha-london", "push_service": "notify.x y"}, ""), set())

    def test_unknown_instance_is_no_phone(self):
        self.assertEqual(subs.available({"push_instance": "ha-mars", "push_service": "mobile_app_x"}, ""), set())

    def test_own_email_overrides_account_email(self):
        self.assertEqual(subs.available({"email": "not-an-address"}, "me@example.com"), set())


class ApplyFormTest(unittest.TestCase):
    def apply(self, settings, form, email="me@example.com"):
        return subs.apply_form(settings, form, groups_of, email)

    def test_group_choice_is_stored(self):
        s = self.apply(PHONE, {"g:Storage": "push"})
        self.assertEqual(s["groups"], {"Storage": "push"})

    def test_partial_form_keeps_other_settings(self):
        s = self.apply({**PHONE, "groups": {"R730 Host": "email"}, "default": "push"}, {"g:Storage": "push"})
        self.assertEqual(s["groups"], {"R730 Host": "email", "Storage": "push"})
        self.assertEqual(s["default"], "push")
        self.assertEqual(s["push_service"], "mobile_app_some_phone")

    def test_alert_equal_to_its_group_is_not_stored(self):
        s = self.apply({**PHONE, "groups": {"Storage": "push"}}, {"a:PVFillingUp": "push"})
        self.assertEqual(s.get("alerts", {}), {})

    def test_alert_different_from_its_group_is_stored(self):
        s = self.apply({**PHONE, "groups": {"Storage": "push"}}, {"a:PVFillingUp": "off"})
        self.assertEqual(s["alerts"], {"PVFillingUp": "off"})

    def test_alert_off_without_group_is_not_stored(self):
        s = self.apply({**PHONE, "alerts": {"PVFillingUp": "push"}}, {"a:PVFillingUp": "off"})
        self.assertEqual(s.get("alerts", {}), {})

    def test_inherit_clears_the_alert_choice(self):
        s = self.apply({**PHONE, "alerts": {"PVFillingUp": "email"}}, {"a:PVFillingUp": "inherit"})
        self.assertEqual(s.get("alerts", {}), {})

    def test_changing_a_group_keeps_inherited_alerts_inherited(self):
        s = self.apply({**PHONE, "groups": {"Storage": "push"}}, {"g:Storage": "email", "a:PVFillingUp": "inherit"})
        self.assertEqual(s["groups"], {"Storage": "email"})
        self.assertEqual(s.get("alerts", {}), {})

    def test_group_off_is_not_stored(self):
        s = self.apply({**PHONE, "groups": {"Storage": "push"}}, {"g:Storage": "off"})
        self.assertEqual(s.get("groups", {}), {})

    def test_alert_outside_any_group_can_be_chosen(self):
        s = self.apply(PHONE, {"a:DevvmJournalSilent": "push"})
        self.assertEqual(s["alerts"], {"DevvmJournalSilent": "push"})

    def test_old_topics_are_dropped(self):
        s = self.apply({**PHONE, "topics": {"internet": "push"}}, {})
        self.assertNotIn("topics", s)

    def test_channel_fields(self):
        form = {"push_instance": "ha-sofia", "push_service": " mobile_app_x ", "email": "a@b.co", "default": "email"}
        s = self.apply({}, form)
        self.assertEqual(
            {k: s[k] for k in form},
            {"push_instance": "ha-sofia", "push_service": "mobile_app_x", "email": "a@b.co", "default": "email"},
        )

    def test_empty_email_falls_back_to_account(self):
        s = self.apply({}, {"email": "", "default": "email"})
        self.assertEqual(s["email"], "")

    def test_bad_values_are_refused(self):
        for form in (
            {"push_instance": "ha-mars"},
            {"push_service": "notify.mobile app"},
            {"email": "not an address"},
            {"default": "sms"},
            {"g:Storage": "sms"},
            {"a:PVFillingUp": "sms"},
            {"a:bad name!": "push"},
        ):
            with self.subTest(form=form), self.assertRaises(subs.Invalid):
                self.apply(PHONE, form)

    def test_push_without_a_phone_is_refused(self):
        with self.assertRaisesRegex(subs.Invalid, "phone"):
            self.apply({}, {"g:Storage": "push"})

    def test_email_without_any_address_is_refused(self):
        with self.assertRaisesRegex(subs.Invalid, "email"):
            self.apply({}, {"a:PVFillingUp": "email"}, email="")

    def test_input_is_not_modified(self):
        before = {**PHONE, "groups": {"Storage": "push"}}
        self.apply(before, {"g:Storage": "off"})
        self.assertEqual(before["groups"], {"Storage": "push"})


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
