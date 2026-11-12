#!/usr/bin/env python3
"""Tests for sleep_stage_cleanup.py against a throwaway recorder database.

Run: python3 scripts/ha-london/sleep_stage_cleanup_test.py

The database has the columns of Home Assistant's recorder tables that the job
reads and writes. Every night here is synthetic; the shapes copy what ha-london
recorded in November 2026 (see the module docstring).
"""
import datetime as dt
import importlib.util
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "sleep_stage_cleanup", os.path.join(_HERE, "sleep_stage_cleanup.py")
)
sc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sc)

PREFIX = "sensor.phone"
ENTITIES = ["sleep_duration", "core_sleep", "deep_sleep", "rem_sleep", "awake"]
T0 = dt.datetime(2026, 11, 1, tzinfo=dt.UTC).timestamp()
H = 3600.0

SCHEMA = """
CREATE TABLE states_meta (metadata_id INTEGER PRIMARY KEY, entity_id VARCHAR(255));
CREATE TABLE states (
    state_id INTEGER PRIMARY KEY, entity_id CHAR(0), state VARCHAR(255), attributes CHAR(0),
    event_id SMALLINT, last_changed CHAR(0), last_changed_ts FLOAT, last_updated CHAR(0),
    last_updated_ts FLOAT, old_state_id INTEGER, attributes_id INTEGER, context_id CHAR(0),
    context_user_id CHAR(0), context_parent_id CHAR(0), origin_idx SMALLINT,
    context_id_bin BLOB, context_user_id_bin BLOB, context_parent_id_bin BLOB,
    metadata_id INTEGER, last_reported_ts FLOAT
);
CREATE TABLE statistics_meta (id INTEGER PRIMARY KEY, statistic_id VARCHAR(255), source VARCHAR(32));
CREATE TABLE statistics (
    id INTEGER PRIMARY KEY, created CHAR(0), created_ts FLOAT, metadata_id INTEGER,
    start CHAR(0), start_ts FLOAT, mean FLOAT, min FLOAT, max FLOAT, last_reset CHAR(0),
    last_reset_ts FLOAT, state FLOAT, sum FLOAT, mean_weight FLOAT
);
CREATE TABLE statistics_short_term (
    id INTEGER PRIMARY KEY, created CHAR(0), created_ts FLOAT, metadata_id INTEGER,
    start CHAR(0), start_ts FLOAT, mean FLOAT, min FLOAT, max FLOAT, last_reset CHAR(0),
    last_reset_ts FLOAT, state FLOAT, sum FLOAT, mean_weight FLOAT
);
"""


def ha_mean(timeline, start, length):
    """Home Assistant's compile: numeric states only, each lasting until the next numeric one."""
    nums = []
    for ts, v in timeline:
        try:
            nums.append((ts, float(v)))
        except ValueError:
            pass
    end = start + length
    carry = [v for ts, v in nums if ts <= start]
    points = ([(start, carry[-1])] if carry else []) + [(ts, v) for ts, v in nums if start < ts < end]
    if not points:
        return None
    total = 0.0
    for i, (ts, v) in enumerate(points):
        nxt = points[i + 1][0] if i + 1 < len(points) else end
        total += v * (nxt - ts)
    span = end - points[0][0]
    values = [v for _, v in points]
    return total / span, min(values), max(values)


class Recorder:
    """A tiny recorder: writes state rows, then compiles statistics the way HA does."""

    def __init__(self, path):
        self.conn = sqlite3.connect(path)
        self.conn.executescript(SCHEMA)
        self.meta = {}
        self.stat_meta = {}
        for i, name in enumerate(ENTITIES, start=1):
            eid = f"{PREFIX}_{name}"
            self.conn.execute("INSERT INTO states_meta VALUES (?, ?)", (i, eid))
            self.conn.execute("INSERT INTO statistics_meta VALUES (?, ?, 'recorder')", (i, eid))
            self.meta[name] = i
        self.conn.commit()

    def snapshot(self, hours, **values):
        """One phone update: the sensors whose value changed get a state row."""
        ts = T0 + hours * H
        for i, (name, value) in enumerate(values.items()):
            last = self.conn.execute(
                "SELECT state FROM states WHERE metadata_id=? ORDER BY last_updated_ts DESC LIMIT 1",
                (self.meta[name],),
            ).fetchone()
            if last and last[0] == str(value):
                continue
            self.conn.execute(
                "INSERT INTO states (state, last_updated_ts, metadata_id) VALUES (?, ?, ?)",
                (str(value), ts + i, self.meta[name]),
            )
        self.conn.commit()

    def timeline(self, name):
        return self.conn.execute(
            "SELECT last_updated_ts, state FROM states WHERE metadata_id=? ORDER BY last_updated_ts",
            (self.meta[name],),
        ).fetchall()

    def compile(self, until_hours):
        end = T0 + until_hours * H
        for name, mid in self.meta.items():
            tl = self.timeline(name)
            for table, length in (("statistics", 3600), ("statistics_short_term", 300)):
                start = T0
                while start + length <= end:
                    stats = ha_mean(tl, start, length)
                    if stats:
                        self.conn.execute(
                            f"INSERT INTO {table} (metadata_id, start_ts, mean, min, max) VALUES (?,?,?,?,?)",
                            (mid, start, *stats),
                        )
                    start += length
        self.conn.commit()

    def states(self, name):
        return [s for _, s in self.timeline(name)]

    def hourly(self, name, hours):
        row = self.conn.execute(
            "SELECT mean, min, max FROM statistics WHERE metadata_id=? AND start_ts=?",
            (self.meta[name], T0 + hours * H),
        ).fetchone()
        return row


def night(rec, hours, dur, core, deep, rem, awake):
    rec.snapshot(hours, sleep_duration=dur, core_sleep=core, deep_sleep=deep, rem_sleep=rem, awake=awake)


class CleanupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "home-assistant_v2.db"
        self.undo = Path(self.tmp.name) / "undo"
        self.rec = Recorder(self.db)

    def tearDown(self):
        self.rec.conn.close()
        self.tmp.cleanup()

    def run_job(self, now_hours, **kwargs):
        out = sc.run(
            db_path=str(self.db),
            prefix=PREFIX,
            now=T0 + now_hours * H,
            undo_dir=str(self.undo),
            **kwargs,
        )
        self.rec.conn.rollback()
        return out

    def test_watch_first_then_sleep_cycle_keeps_the_watch_split(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)        # Watch alone: 250+50+100 = 400
        night(self.rec, 11, 404, 330, 100, 140, 30)       # Sleep Cycle lands: stages 570 vs 404
        self.rec.compile(20)

        out = self.run_job(20)

        self.assertEqual(out["status"], "ok")
        self.assertEqual(self.rec.states("core_sleep"), ["250", "250"])
        self.assertEqual(self.rec.states("deep_sleep"), ["50", "50"])
        self.assertEqual(self.rec.states("rem_sleep"), ["100", "100"])
        self.assertEqual(self.rec.states("awake"), ["10", "10"])
        self.assertEqual(self.rec.hourly("core_sleep", 15), (250.0, 250.0, 250.0))
        self.assertEqual(self.rec.hourly("deep_sleep", 11), (50.0, 50.0, 50.0))

    def test_sleep_cycle_first_then_watch_keeps_the_sleep_cycle_split(self):
        night(self.rec, 10, 420, 280, 60, 80, 20)         # Sleep Cycle alone, consistent
        night(self.rec, 12, 425, 400, 110, 150, 35)       # the Watch lands on top
        self.rec.compile(20)

        self.run_job(20)

        self.assertEqual(self.rec.states("core_sleep"), ["280", "280"])
        self.assertEqual(self.rec.states("rem_sleep"), ["80", "80"])

    def test_night_with_no_clean_reading_is_blanked(self):
        night(self.rec, 0, 380, 270, 30, 80, 5)           # the night before, clean
        night(self.rec, 15, 380, 300, 40, 115, 25)        # first reading of this night is inflated
        night(self.rec, 30, 400, 255, 20, 125, 40)        # next night, clean
        self.rec.compile(40)

        self.run_job(40)

        self.assertEqual(self.rec.states("core_sleep"), ["270", "unknown", "255"])
        self.assertEqual(self.rec.states("awake"), ["5", "unknown", "40"])
        self.assertIsNone(self.rec.hourly("core_sleep", 20))
        # The hour the blank starts keeps the night before for its first minutes only.
        self.assertEqual(self.rec.hourly("core_sleep", 15), (270.0, 270.0, 270.0))
        self.assertEqual(self.rec.hourly("core_sleep", 30), (255.0, 255.0, 255.0))

    def test_new_night_that_is_shorter_is_not_given_the_last_night(self):
        night(self.rec, 0, 480, 300, 60, 120, 10)
        night(self.rec, 6, 300, 250, 80, 90, 20)          # shorter total: a different night
        self.rec.compile(10)

        self.run_job(10)

        self.assertEqual(self.rec.states("core_sleep"), ["300", "unknown"])

    def test_a_repeat_of_the_same_inflated_reading_gets_the_same_answer(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        # HA restarts the next afternoon and records the inflated values again.
        for name, value in (("core_sleep", 330), ("deep_sleep", 100), ("rem_sleep", 140), ("awake", 30)):
            self.rec.conn.execute(
                "INSERT INTO states (state, last_updated_ts, metadata_id) VALUES (?, ?, ?)",
                (str(value), T0 + 30 * H, self.rec.meta[name]),
            )
        self.rec.conn.commit()
        self.rec.compile(35)

        self.run_job(35)

        self.assertEqual(self.rec.states("core_sleep"), ["250", "250", "250"])

    def test_rounding_up_to_two_minutes_is_clean(self):
        night(self.rec, 10, 375, 273, 26, 78, 3)          # 377 vs 375: each sensor is rounded
        night(self.rec, 34, 400, 260, 40, 103, 5)         # 403 vs 400: inflated, and a new night
        self.rec.compile(40)

        out = self.run_job(40)

        self.assertEqual(self.rec.states("core_sleep"), ["273", "unknown"])
        self.assertEqual(out["changed_states"], 4)

    def test_second_run_changes_nothing(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        night(self.rec, 15, 380, 300, 40, 115, 25)
        self.rec.compile(20)
        self.run_job(20)

        out = self.run_job(20)

        self.assertEqual(out["status"], "ok")
        self.assertEqual(out["changed_states"], 0)
        self.assertEqual(out["changed_stats"], 0)
        self.assertEqual(len(list(self.undo.glob("*.sql"))), 1)

    def test_clean_nights_are_left_alone(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 34, 455, 314, 32, 109, 17)
        self.rec.compile(40)

        out = self.run_job(40)

        self.assertEqual((out["changed_states"], out["changed_stats"]), (0, 0))
        self.assertFalse(self.undo.exists() and any(self.undo.iterdir()))

    def test_self_check_failure_writes_nothing(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        self.rec.compile(20)
        # A statistics row HA would not have written: the compile no longer matches the model.
        self.rec.conn.execute(
            "UPDATE statistics SET mean=999 WHERE metadata_id=? AND start_ts=?",
            (self.rec.meta["core_sleep"], T0 + 10 * H),
        )
        self.rec.conn.commit()

        out = self.run_job(20)

        self.assertEqual(out["status"], "self_check_failed")
        self.assertEqual(self.rec.states("core_sleep"), ["250", "330"])

    def test_undo_file_restores_every_row(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        night(self.rec, 15, 380, 300, 40, 115, 25)
        self.rec.compile(20)
        before = self.rec.conn.execute("SELECT * FROM statistics ORDER BY id").fetchall()

        self.run_job(20)
        (undo,) = self.undo.glob("*.sql")
        self.rec.conn.executescript(undo.read_text())

        self.assertEqual(self.rec.states("core_sleep"), ["250", "330", "300"])
        self.assertEqual(self.rec.conn.execute("SELECT * FROM statistics ORDER BY id").fetchall(), before)

    def test_only_the_lookback_window_is_touched(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        self.rec.compile(20)

        self.run_job(200, lookback_hours=72)

        self.assertEqual(self.rec.states("core_sleep"), ["250", "330"])

    def test_dry_run_reports_and_writes_nothing(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        night(self.rec, 11, 404, 330, 100, 140, 30)
        self.rec.compile(20)

        out = self.run_job(20, dry_run=True)

        self.assertEqual(out["status"], "dry_run")
        self.assertEqual(out["changed_states"], 4)
        self.assertEqual(self.rec.states("core_sleep"), ["250", "330"])
        self.assertFalse(self.undo.exists())

    def test_missing_database_column_stops_the_run(self):
        self.rec.conn.execute("ALTER TABLE states RENAME COLUMN last_updated_ts TO updated_at")
        self.rec.conn.commit()

        out = self.run_job(20)

        self.assertEqual(out["status"], "schema_changed")

    def test_main_prints_one_json_line_and_exits_zero(self):
        night(self.rec, 10, 400, 250, 50, 100, 10)
        self.rec.compile(12)

        code, line = sc.main_for_test(
            ["--db", str(self.db), "--prefix", PREFIX, "--undo-dir", str(self.undo)]
        )

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(line)["status"], "ok")


if __name__ == "__main__":
    unittest.main()
