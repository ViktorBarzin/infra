"""Tests for the claude-sessions store pass of `homelab reflect`.

Run: python3 -I scripts/session-reflection/test_store.py
"""
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import store  # noqa: E402


def fake_runner(answers):
    """A stand-in for `homelab claude-sessions sql`: answers by spec key,
    which each test embeds in the SQL as a comment."""
    calls = []

    def run(sql):
        calls.append(sql)
        key = re.search(r"-- key: (\S+)", sql).group(1)
        a = answers[key]
        if isinstance(a, Exception):
            raise a
        return "\n".join(json.dumps(r) for r in a)
    run.calls = calls
    return run


class RenderSQL(unittest.TestCase):
    def test_substitutes_window_and_user(self):
        sql = store.render_sql("ts >= {start} AND ts < {end} AND os_user = {user}",
                               "2026-11-01 00:00:00", "2026-11-08 00:00:00", "wizard")
        self.assertEqual(sql, "ts >= '2026-11-01 00:00:00' AND ts < '2026-11-08 00:00:00' "
                              "AND os_user = 'wizard'")

    def test_rejects_a_user_that_could_break_out_of_the_quotes(self):
        for bad in ["wiz'ard", "a b", "", "x;DROP"]:
            with self.assertRaises(ValueError):
                store.render_sql("{user}", "2026-01-01 00:00:00", "2026-01-02 00:00:00", bad)

    def test_rejects_an_unknown_placeholder(self):
        with self.assertRaises(ValueError):
            store.render_sql("{since}", "2026-01-01 00:00:00", "2026-01-02 00:00:00", "wizard")


class RunSpecs(unittest.TestCase):
    specs = [
        {"key": "sessions", "kind": "scalar", "sql": "-- key: sessions\nSELECT 1"},
        {"key": "spend_by_model", "kind": "labelled", "sql": "-- key: spend_by_model\nSELECT 1"},
        {"key": "broken", "kind": "scalar", "sql": "-- key: broken\nSELECT 1"},
        {"key": "empty", "kind": "scalar", "sql": "-- key: empty\nSELECT 1"},
    ]

    def test_collects_scalars_and_labelled_and_survives_a_failing_query(self):
        run = fake_runner({
            "sessions": [{"value": 12}],
            "spend_by_model": [{"label": "claude-opus-5-5", "value": 101.5},
                               {"label": "claude-haiku-5-5", "value": 0.25}],
            "broken": RuntimeError("clickhouse 500: Code: 47"),
            "empty": [],
        })
        out = store.run_specs(self.specs, "2026-11-01 00:00:00", "2026-11-08 00:00:00",
                              "wizard", run)
        self.assertEqual(out["scalars"]["sessions"], 12)
        self.assertEqual(out["labelled"]["spend_by_model"],
                         {"claude-opus-5-5": 101.5, "claude-haiku-5-5": 0.25})
        self.assertIsNone(out["scalars"]["broken"])
        self.assertIn("broken", out["errors"])
        self.assertEqual(out["scalars"]["empty"], 0)
        self.assertEqual(len(run.calls), 4)


class Deltas(unittest.TestCase):
    def test_reports_movement_and_skips_unchanged_or_missing(self):
        cur = {"scalars": {"a": 10, "b": 5, "c": None, "d": 3}}
        prev = {"scalars": {"a": 20, "b": 5, "c": 4}}
        lines = store.deltas(cur, prev)
        self.assertEqual(lines, ["a 20->10 (-50%)"])

    def test_no_previous_run_means_no_deltas(self):
        self.assertEqual(store.deltas({"scalars": {"a": 1}}, None), [])


class Render(unittest.TestCase):
    def test_table_shows_now_prev_and_labelled_top_rows(self):
        cur = {"window": {"start": "2026-11-01 00:00:00", "end": "2026-11-08 00:00:00", "user": "wizard"},
               "scalars": {"sessions": 12, "bash_sleep": 40},
               "labelled": {"spend_by_model": {"claude-opus-5-5": 101.5}}, "errors": {}}
        prev = {"scalars": {"sessions": 10, "bash_sleep": 40}}
        text = store.render(cur, prev, store.load_specs())
        self.assertIn("sessions", text)
        self.assertIn("+2", text)
        self.assertIn("claude-opus-5-5", text)


class Push(unittest.TestCase):
    def test_metric_lines_are_valid_and_skip_missing_values(self):
        cur = {"scalars": {"sessions": 12, "broken": None},
               "labelled": {"spend_by_model": {'we"ird': 1.5}}}
        lines = store.metric_lines(cur)
        self.assertIn("session_reflection_store_sessions 12", lines)
        self.assertFalse(any("broken" in l for l in lines))
        self.assertIn('session_reflection_store_spend_by_model{label="weird"} 1.5', lines)


class SpecFile(unittest.TestCase):
    def test_every_spec_is_well_formed(self):
        specs = store.load_specs()
        keys = [s["key"] for s in specs]
        self.assertEqual(len(keys), len(set(keys)), "duplicate keys")
        for s in specs:
            self.assertRegex(s["key"], r"^[a-z][a-z0-9_]*$")
            self.assertIn(s["kind"], ("scalar", "labelled"))
            self.assertTrue(s.get("description"), f"{s['key']} has no description")
            for ph in re.findall(r"\{(\w+)\}", s["sql"]):
                self.assertIn(ph, ("start", "end", "user"), f"{s['key']}: unknown {{{ph}}}")
            # Every query must be bound to the window, or the trend means nothing.
            self.assertIn("{start}", s["sql"], f"{s['key']} ignores the window")
            self.assertIn("{user}", s["sql"], f"{s['key']} ignores the user")

    def test_fingerprint_is_stable(self):
        self.assertEqual(store.fingerprint(), store.fingerprint())
        self.assertEqual(len(store.fingerprint()), 12)


class ReflectIntegration(unittest.TestCase):
    def test_history_line_handles_a_store_only_run(self):
        import reflect
        line = reflect.history_line({"recorded_at": "2026-11-09T10:00:00+00:00",
                                     "store": {"scalars": {"spend_usd": 2046.49, "sessions": 231}}})
        self.assertIn("2026-11-09T10:00:00", line)
        self.assertIn("spend_usd=2046.49", line)

    def test_history_line_keeps_the_transcript_fields(self):
        import reflect
        line = reflect.history_line({"recorded_at": "2026-09-01T17:48:42", "turns": 1463,
                                     "d1_corrections": 90, "d2_anomalies": 1538, "d4_wins": 270,
                                     "patterns_fingerprint": "e9fce188e431"})
        self.assertIn("turns=1463", line)
        self.assertIn("e9fce188e431", line)


if __name__ == "__main__":
    unittest.main(verbosity=2)
