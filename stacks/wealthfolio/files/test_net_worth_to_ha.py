"""Unit tests for net_worth_to_ha.py.

Run with: cd infra/stacks/wealthfolio/files && python3 -m unittest test_net_worth_to_ha
"""
import datetime as dt
import importlib.util
import sys
import unittest
from decimal import Decimal
from pathlib import Path

_spec = importlib.util.spec_from_file_location("net_worth_to_ha", Path(__file__).parent / "net_worth_to_ha.py")
nw = importlib.util.module_from_spec(_spec)
sys.modules["net_worth_to_ha"] = nw
_spec.loader.exec_module(nw)

D = dt.date


class FormatTotalTests(unittest.TestCase):
    def test_cases(self):
        for value, want in [
            (Decimal("1223999.12"), "£1.22M"),
            (Decimal("1995000"), "£2.00M"),
            (Decimal("1000000"), "£1.00M"),
            (Decimal("987654"), "£988k"),
            (Decimal("999600"), "£1.00M"),  # rounds up past the million boundary
        ]:
            with self.subTest(value=value):
                self.assertEqual(nw.format_total(value), want)


class FormatChangeTests(unittest.TestCase):
    def test_cases(self):
        for value, want in [
            (Decimal("-9073"), ("▼£9.1k", nw.RED)),
            (Decimal("4246"), ("▲£4.2k", nw.GREEN)),
            (Decimal("640.4"), ("▲£640", nw.GREEN)),
            (Decimal("-17"), ("▼£17", nw.RED)),
            (Decimal("999.6"), ("▲£1.0k", nw.GREEN)),  # rounds into thousands
            (Decimal("-150000"), ("▼£150.0k", nw.RED)),
            (Decimal("0.3"), ("±£0", nw.GREY)),
            (Decimal("-0.4"), ("±£0", nw.GREY)),
        ]:
            with self.subTest(value=value):
                self.assertEqual(nw.format_change(value), want)


# Thu 2026-10-08 .. Mon 2026-10-12, weekend rows carry Friday forward.
WEEK = {
    D(2026, 10, 8): Decimal("1200000"),   # Thu
    D(2026, 10, 9): Decimal("1205000"),   # Fri
    D(2026, 10, 10): Decimal("1204998"),  # Sat
    D(2026, 10, 11): Decimal("1204981"),  # Sun
}


class BuildStateTests(unittest.TestCase):
    def test_weekend_shows_fridays_move(self):
        s = nw.build_state(WEEK, today=D(2026, 10, 11))
        a = s["attributes"]
        self.assertEqual(s["state"], "1204981")  # total is the latest row, like the Grafana tile
        self.assertEqual(a["change"], 5000.0)
        self.assertEqual(a["as_of"], "2026-10-09")
        self.assertEqual(a["compared_to"], "2026-10-08")
        self.assertEqual(a["change_short"], "▲£5.0k")
        self.assertFalse(a["stale"])

    def test_monday_morning_still_shows_friday(self):
        s = nw.build_state(WEEK, today=D(2026, 10, 12))
        self.assertEqual(s["attributes"]["as_of"], "2026-10-09")

    def test_monday_after_update_compares_to_friday(self):
        totals = dict(WEEK)
        totals[D(2026, 10, 12)] = Decimal("1209227")
        a = nw.build_state(totals, today=D(2026, 10, 12))["attributes"]
        self.assertEqual(a["as_of"], "2026-10-12")
        self.assertEqual(a["compared_to"], "2026-10-09")
        self.assertEqual(a["change"], 4227.0)

    def test_stale_after_three_days(self):
        for today, want in [(D(2026, 10, 14), False), (D(2026, 10, 15), True)]:
            with self.subTest(today=today):
                a = nw.build_state(WEEK, today=today)["attributes"]
                self.assertEqual(a["stale"], want)
                if want:
                    self.assertEqual(a["change_short"], "—")
                    self.assertEqual(a["change_color"], nw.GREY)

    def test_one_weekday_has_no_change(self):
        totals = {D(2026, 10, 9): Decimal("1205000"), D(2026, 10, 10): Decimal("1205000")}
        a = nw.build_state(totals, today=D(2026, 10, 10))["attributes"]
        self.assertIsNone(a["change"])
        self.assertEqual(a["change_short"], "—")

    def test_no_rows_raises(self):
        with self.assertRaises(ValueError):
            nw.build_state({}, today=D(2026, 10, 10))


class ParseTotalsTests(unittest.TestCase):
    def test_psql_unaligned_output(self):
        out = "2026-10-14|1233072.40\n2026-10-15|1223999.12\n"
        self.assertEqual(nw.parse_totals(out), {
            D(2026, 10, 14): Decimal("1233072.40"),
            D(2026, 10, 15): Decimal("1223999.12"),
        })


if __name__ == "__main__":
    unittest.main()
