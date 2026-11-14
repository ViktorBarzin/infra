"""Unit tests for acs_archive.py.

Run with: cd infra/stacks/vermont-access/files && python3 -m unittest test_acs_archive
"""
import gzip
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("acs_archive", Path(__file__).parent / "acs_archive.py")
aa = importlib.util.module_from_spec(_spec)
sys.modules["acs_archive"] = aa
_spec.loader.exec_module(aa)

PANEL_EVENT = {"major": 5, "minor": 75, "time": "2026-11-10 17:44:22", "mask": "unknown", "doorNo": 1}
DOOR_EVENT = {"major": 2, "minor": 1031, "time": "2026-11-10T18:13:30+02:00", "type": 0, "serialNo": 28804}


def reference_key(device, event, index):
    # The exact form the 2026-11-10 initial copy was written with.
    c = json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(f"{device}|{c}|{index}".encode()).hexdigest()


class KeyTests(unittest.TestCase):
    def test_key_matches_the_initial_copy(self):
        rows = aa.keyed_rows(111, [PANEL_EVENT])
        self.assertEqual(rows[0]["key"], reference_key(111, PANEL_EVENT, 0))

    def test_key_ignores_field_order(self):
        reordered = dict(reversed(list(PANEL_EVENT.items())))
        self.assertEqual(aa.keyed_rows(111, [reordered])[0]["key"], aa.keyed_rows(111, [PANEL_EVENT])[0]["key"])

    def test_identical_events_in_one_second_get_distinct_keys(self):
        rows = aa.keyed_rows(111, [PANEL_EVENT, dict(PANEL_EVENT), dict(PANEL_EVENT)])
        self.assertEqual([r["key"] for r in rows], [reference_key(111, PANEL_EVENT, i) for i in range(3)])

    def test_index_counts_only_identical_events(self):
        other = dict(PANEL_EVENT, minor=76)
        rows = aa.keyed_rows(111, [PANEL_EVENT, other, PANEL_EVENT])
        self.assertEqual(rows[1]["key"], reference_key(111, other, 0))
        self.assertEqual(rows[2]["key"], reference_key(111, PANEL_EVENT, 1))

    def test_same_event_on_two_devices_differs(self):
        self.assertNotEqual(aa.keyed_rows(111, [PANEL_EVENT])[0]["key"], aa.keyed_rows(112, [PANEL_EVENT])[0]["key"])

    def test_row_shape_matches_the_initial_copy_lines(self):
        row = aa.keyed_rows(117, [DOOR_EVENT])[0]
        self.assertEqual(set(row), {"device", "key", "event"})
        self.assertEqual(row["device"], 117)
        self.assertEqual(row["event"], DOOR_EVENT)


class GapTests(unittest.TestCase):
    def test_first_run_is_not_a_gap(self):
        self.assertFalse(aa.is_gap(had_rows=False, pulled=900, inserted=900))

    def test_overlap_found_is_not_a_gap(self):
        self.assertFalse(aa.is_gap(had_rows=True, pulled=1330, inserted=8))

    def test_nothing_from_the_overlap_left_on_the_device_is_a_gap(self):
        self.assertTrue(aa.is_gap(had_rows=True, pulled=4000, inserted=4000))

    def test_empty_pull_after_history_is_a_gap(self):
        # The window starts before the newest archived event, so a device that
        # still holds it always returns at least that one.
        self.assertTrue(aa.is_gap(had_rows=True, pulled=0, inserted=0))


class DeviceTimeTests(unittest.TestCase):
    def test_offset_gets_a_colon(self):
        self.assertEqual(aa.device_time("2026-11-07T18:13:30+02"), "2026-11-07T18:13:30+02:00")

    def test_offset_with_minutes_is_kept(self):
        self.assertEqual(aa.device_time("2026-11-07T18:13:30+05:30"), "2026-11-07T18:13:30+05:30")


class PagingTests(unittest.TestCase):
    def test_pages_until_the_device_stops_saying_more(self):
        events = [dict(PANEL_EVENT, minor=i) for i in range(70)]
        calls = []

        def fake_post(body):
            cond = body["AcsEventCond"]
            calls.append((cond["searchResultPosition"], cond["startTime"]))
            pos, n = cond["searchResultPosition"], cond["maxResults"]
            chunk = events[pos:pos + n]
            status = "MORE" if pos + n < len(events) else "OK"
            return {"AcsEvent": {"InfoList": chunk, "responseStatusStrg": status}}

        got = aa.pull_events(fake_post, "2026-11-07T18:13:30+02:00", "2026-11-12T00:00:00+02:00")
        self.assertEqual(got, events)
        self.assertEqual([c[0] for c in calls], [0, 30, 60])
        self.assertTrue(all(c[1] == "2026-11-07T18:13:30+02:00" for c in calls))

    def test_stops_on_an_empty_page(self):
        got = aa.pull_events(lambda body: {"AcsEvent": {"responseStatusStrg": "MORE"}}, "a", "b")
        self.assertEqual(got, [])

    def test_runaway_paging_raises(self):
        page = {"AcsEvent": {"InfoList": [PANEL_EVENT], "responseStatusStrg": "MORE"}}
        with self.assertRaises(RuntimeError):
            aa.pull_events(lambda body: page, "a", "b", max_pages=5)


class MetricsTests(unittest.TestCase):
    def test_metrics_text(self):
        results = {
            111: {"up": 1, "pulled": 1330, "inserted": 8, "gap": 0, "newest": 1762790000},
            112: {"up": 0, "pulled": 0, "inserted": 0, "gap": 0, "newest": None},
        }
        text = aa.metrics_text(results, now=1762800000)
        self.assertIn('vermont_acs_device_up{device="111"} 1\n', text)
        self.assertIn('vermont_acs_device_up{device="112"} 0\n', text)
        self.assertIn('vermont_acs_inserted_events{device="111"} 8\n', text)
        self.assertIn('vermont_acs_gap{device="111"} 0\n', text)
        self.assertIn('vermont_acs_newest_event_timestamp_seconds{device="111"} 1762790000\n', text)
        self.assertNotIn('vermont_acs_newest_event_timestamp_seconds{device="112"}', text)
        self.assertIn("vermont_acs_last_run_timestamp_seconds 1762800000\n", text)
        self.assertTrue(text.endswith("\n"))


class LoadFileTests(unittest.TestCase):
    def test_reads_initial_copy_lines_and_rejects_foreign_keys(self):
        good = aa.keyed_rows(111, [PANEL_EVENT])[0]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "111.jsonl.gz"
            with gzip.open(p, "wt", encoding="utf-8") as f:
                f.write(json.dumps(good, ensure_ascii=False) + "\n")
            self.assertEqual(aa.read_copy(p), [good])
            with gzip.open(p, "wt", encoding="utf-8") as f:
                f.write(json.dumps(dict(good, key="0" * 64)) + "\n")
            with self.assertRaises(ValueError):
                aa.read_copy(p)


if __name__ == "__main__":
    unittest.main()
