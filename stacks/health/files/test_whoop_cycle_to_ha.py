"""Unit tests for whoop_cycle_to_ha.py.

Run with: cd infra/stacks/health/files && python3 -m unittest test_whoop_cycle_to_ha
"""
import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("whoop_cycle_to_ha", Path(__file__).parent / "whoop_cycle_to_ha.py")
wc = importlib.util.module_from_spec(_spec)
sys.modules["whoop_cycle_to_ha"] = wc
_spec.loader.exec_module(wc)


def day(date, phase, first=False):
    return {"date": date, "phase": phase, "first_day_of_phase": first}


# Shape of GET /womens-health-service/v1/menstrual-cycle-insights?date=...
SAMPLE = {
    "tiles": [
        {"type": "HEADER_TILE", "content": {
            "title_display": "Cycle Day 11", "subtitle_display": "Follicular Phase", "style": "FOLLICULAR"}},
        {"type": "CALENDAR_TILE", "content": {"calendar": {"days_of_month": [
            day("2026-11-01", "MENSTRUAL", True),
            day("2026-11-06", "FOLLICULAR", True),
            day("2026-11-14", "OVULATORY", True),
            day("2026-11-17", "LUTEAL", True),
            day("2026-11-29", "MENSTRUAL", True),
            day("2026-11-30", "MENSTRUAL"),
        ]}}},
        {"type": "TYPICAL_CYCLE_TILE", "content": {"stats": [
            {"title_display": "PERIOD LENGTH", "value_display": "5"},
            {"title_display": "CYCLE LENGTH", "value_display": "28"},
        ]}},
    ]
}


class ProjectTests(unittest.TestCase):
    def test_full_response(self):
        self.assertEqual(wc.project(SAMPLE, "2026-11-11"), {
            "phase": "Follicular",
            "cycle_day": 11,
            "cycle_length": 28,
            "period_length": 5,
            "next_period": "2026-11-29",
            "ovulation": "2026-11-14",
        })

    def test_markers_before_today_are_ignored(self):
        got = wc.project(SAMPLE, "2026-11-15")
        self.assertIsNone(got["ovulation"])
        self.assertEqual(got["next_period"], "2026-11-29")

    def test_phase_falls_back_to_style_enum(self):
        raw = {"tiles": [{"type": "HEADER_TILE", "content": {"title_display": "Cycle Day 20", "style": "LUTEAL"}}]}
        self.assertEqual(wc.project(raw, "2026-11-11")["phase"], "Luteal")

    def test_cycle_length_dash_means_unknown(self):
        raw = {"tiles": [{"type": "TYPICAL_CYCLE_TILE", "content": {"stats": [
            {"title_display": "CYCLE LENGTH", "value_display": "-"}]}}]}
        self.assertIsNone(wc.project(raw, "2026-11-11")["cycle_length"])

    def test_feature_not_set_up(self):
        self.assertEqual(wc.project({}, "2026-11-11"), {
            "phase": None, "cycle_day": None, "cycle_length": None,
            "period_length": None, "next_period": None, "ovulation": None,
        })


class CycleStartTests(unittest.TestCase):
    def test_start_is_back_dated_from_cycle_day(self):
        self.assertEqual(
            wc.cycle_start_date({"cycle_day": 11}, dt.date(2026, 11, 11)),
            dt.date(2026, 11, 1),
        )

    def test_day_one_is_today(self):
        self.assertEqual(
            wc.cycle_start_date({"cycle_day": 1}, dt.date(2026, 11, 11)),
            dt.date(2026, 11, 11),
        )

    def test_no_cycle_day(self):
        self.assertIsNone(wc.cycle_start_date({"cycle_day": None}, dt.date(2026, 11, 11)))


class PhaseForDayTests(unittest.TestCase):
    def test_boundaries_28_5(self):
        # cycle_length 28, period 5 -> ovulation day 14
        cases = {1: "Menstrual", 5: "Menstrual", 6: "Follicular", 12: "Follicular",
                 13: "Ovulatory", 14: "Ovulatory", 15: "Ovulatory", 16: "Luteal", 28: "Luteal"}
        for d, want in cases.items():
            with self.subTest(day=d):
                self.assertEqual(wc.phase_for_day(d, 28, 5), want)

    def test_wraps_past_cycle_length(self):
        # day 29 of a 28-day cycle is day 1 again
        self.assertEqual(wc.phase_for_day(29, 28, 5), "Menstrual")

    def test_short_cycle_keeps_ovulation_after_period(self):
        # cl 18, period 5: cl-14=4 would collide with the period, so clamp to 6
        self.assertEqual(wc.phase_for_day(5, 18, 5), "Menstrual")
        self.assertEqual(wc.phase_for_day(6, 18, 5), "Ovulatory")


class ExtractOtpTests(unittest.TestCase):
    def test_plain_code(self):
        self.assertEqual(wc.extract_otp("Your WHOOP login code is 418293. It expires in 10 minutes."), "418293")

    def test_subject_code(self):
        self.assertEqual(wc.extract_otp("418293 is your WHOOP verification code"), "418293")

    def test_ignores_longer_numbers(self):
        self.assertEqual(wc.extract_otp("Order 1234567890 shipped. Code: 902517 now."), "902517")

    def test_none_when_absent(self):
        self.assertIsNone(wc.extract_otp("No numeric code in this message at all."))

    def test_real_whoop_html_with_decoys(self):
        # Mirrors the live email: code is visible text; decoys live in a CSS
        # color and AWS tracking URLs inside tags/attributes.
        body = (
            '<style>.x{letter-spacing:-1px}</style>'
            '<td style="color:#000000; letter-spacing:-1px; padding:15px;">\r\n 839049 \r\n</td>'
            '<a href="https://r.awstrack.me/I0/010101a1ccfa6f7a-000000/Mh9yzw">Reset</a>'
        )
        self.assertEqual(wc.extract_otp(body), "839049")

    def test_two_value_decoy_skipped(self):
        self.assertEqual(wc.extract_otp("<p>010101</p><p>445364</p>"), "445364")


class AuthenticateTests(unittest.TestCase):
    class FakeSession:
        def __init__(self, responses):
            self._responses = list(responses)
            self.calls = []

        def post(self, url, json, headers, timeout):
            self.calls.append(json)
            body = self._responses.pop(0)

            class R:
                status_code = 200
                def json(self_inner):
                    return body
            return R()

    def test_direct_login_never_reads_email(self):
        sess = self.FakeSession([{"AuthenticationResult": {"AccessToken": "tok-direct", "RefreshToken": "ref-direct"}}])
        called = {"otp": False}

        def otp():
            called["otp"] = True
            return "000000"

        self.assertEqual(wc.authenticate(sess, "a@b.com", "pw", otp), ("tok-direct", "ref-direct"))
        self.assertFalse(called["otp"])

    def test_email_otp_challenge_answered(self):
        sess = self.FakeSession([
            {"ChallengeName": "EMAIL_OTP", "Session": "sess-1", "AuthenticationResult": None},
            {"AuthenticationResult": {"AccessToken": "tok-otp"}},
        ])
        self.assertEqual(wc.authenticate(sess, "a@b.com", "pw", lambda: "418293"), ("tok-otp", None))
        # second call must carry the code under EMAIL_OTP_CODE
        self.assertEqual(sess.calls[1]["ChallengeResponses"]["EMAIL_OTP_CODE"], "418293")

    def test_rejected_code_raises(self):
        sess = self.FakeSession([
            {"ChallengeName": "EMAIL_OTP", "Session": "sess-1", "AuthenticationResult": None},
            {"ChallengeName": "EMAIL_OTP", "AuthenticationResult": None},
        ])
        with self.assertRaises(RuntimeError):
            wc.authenticate(sess, "a@b.com", "pw", lambda: "000000")


class StatusSession:
    """Fake requests.Session whose responses carry a status code."""
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    def post(self, url, json, headers, timeout):
        self.calls.append(json)
        status, body = self._responses.pop(0)

        class R:
            status_code = status
            text = str(body)
            def json(self_inner):
                return body
        return R()


class MemoryStore:
    def __init__(self, token=None):
        self.token = token
        self.saves = []

    def load(self):
        return self.token

    def save(self, token):
        self.saves.append(token)
        self.token = token


class RefreshTests(unittest.TestCase):
    def test_refresh_sends_only_the_refresh_token(self):
        sess = StatusSession([(200, {"AuthenticationResult": {"AccessToken": "acc"}})])
        self.assertEqual(wc.refresh_tokens(sess, "ref-1"), ("acc", "ref-1"))
        self.assertEqual(sess.calls[0], {
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": {"REFRESH_TOKEN": "ref-1"},
            "ClientId": "",
        })

    def test_rotated_refresh_token_is_returned(self):
        sess = StatusSession([(200, {"AuthenticationResult": {"AccessToken": "acc", "RefreshToken": "ref-2"}})])
        self.assertEqual(wc.refresh_tokens(sess, "ref-1"), ("acc", "ref-2"))

    def test_expired_refresh_token_returns_none(self):
        sess = StatusSession([(400, {"__type": "NotAuthorizedException", "message": "Refresh Token has expired"})])
        self.assertIsNone(wc.refresh_tokens(sess, "ref-old"))


class SignInTests(unittest.TestCase):
    def otp_never(self):
        raise AssertionError("must not read the login-code email")

    def test_saved_token_signs_in_without_email(self):
        sess = StatusSession([(200, {"AuthenticationResult": {"AccessToken": "acc"}})])
        store = MemoryStore("ref-1")
        self.assertEqual(wc.sign_in(sess, "a@b.com", "pw", store, self.otp_never), "acc")
        self.assertEqual(store.saves, [])  # unchanged token is not rewritten

    def test_rotated_token_is_saved(self):
        sess = StatusSession([(200, {"AuthenticationResult": {"AccessToken": "acc", "RefreshToken": "ref-2"}})])
        store = MemoryStore("ref-1")
        wc.sign_in(sess, "a@b.com", "pw", store, self.otp_never)
        self.assertEqual(store.saves, ["ref-2"])

    def test_expired_token_falls_back_to_email_login_and_saves(self):
        sess = StatusSession([
            (400, {"__type": "NotAuthorizedException"}),
            (200, {"ChallengeName": "EMAIL_OTP", "Session": "s", "AuthenticationResult": None}),
            (200, {"AuthenticationResult": {"AccessToken": "acc-new", "RefreshToken": "ref-new"}}),
        ])
        store = MemoryStore("ref-old")
        self.assertEqual(wc.sign_in(sess, "a@b.com", "pw", store, lambda: "418293"), "acc-new")
        self.assertEqual(store.saves, ["ref-new"])

    def test_no_saved_token_logs_in(self):
        sess = StatusSession([(200, {"AuthenticationResult": {"AccessToken": "acc", "RefreshToken": "ref"}})])
        store = MemoryStore(None)
        self.assertEqual(wc.sign_in(sess, "a@b.com", "pw", store, lambda: "1"), "acc")
        self.assertEqual(store.saves, ["ref"])


class SecretCodecTests(unittest.TestCase):
    def test_round_trip(self):
        body = wc.secret_patch_body("ref-abc")
        self.assertEqual(wc.token_from_secret(body), "ref-abc")

    def test_empty_secret_has_no_token(self):
        self.assertIsNone(wc.token_from_secret({"data": {"refresh_token": ""}}))
        self.assertIsNone(wc.token_from_secret({}))


class HelperCallsTests(unittest.TestCase):
    def test_full(self):
        calls = dict((c[1]["entity_id"], c) for c in
                     wc.helper_calls(wc.project(SAMPLE, "2026-11-11"), dt.date(2026, 11, 11), "2026-11-11T09:37:00+00:00"))
        self.assertEqual(calls["input_datetime.anca_cycle_start"][0], "input_datetime/set_datetime")
        self.assertEqual(calls["input_datetime.anca_cycle_start"][1]["date"], "2026-11-01")
        self.assertEqual(calls["input_number.anca_cycle_length"][1]["value"], 28)
        self.assertEqual(calls["input_number.anca_period_length"][1]["value"], 5)
        self.assertEqual(calls["input_datetime.anca_cycle_last_sync"][1]["datetime"], "2026-11-11T09:37:00+00:00")

    def test_sparse_response_only_sets_last_sync(self):
        calls = wc.helper_calls(wc.project({}, "2026-11-11"), dt.date(2026, 11, 11), "2026-11-11T09:37:00+00:00")
        ids = [c[1]["entity_id"] for c in calls]
        self.assertEqual(ids, ["input_datetime.anca_cycle_last_sync"])


if __name__ == "__main__":
    unittest.main()
