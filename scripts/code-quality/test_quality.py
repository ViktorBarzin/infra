#!/usr/bin/env python3
"""Tests for the pure helpers, which is where every real bug lived.

Each case here is a false positive or false negative that a real run produced
against terminal-lobby, not an invented one. Measurement code fails by emitting
a plausible number rather than by crashing, so these lock the specific wrong
answers that looked right.

    python3 -m pytest test_quality.py -q
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import quality as q  # noqa: E402


# --- classify -------------------------------------------------------------

def test_classify_splits_prod_from_test():
    assert q.classify("tmux-api/main.go") == "prod"
    assert q.classify("tmux-api/main_test.go") == "test"
    assert q.classify("frontend-v2/src/store/lobby.ts") == "prod"
    assert q.classify("frontend-v2/test/lobby.store.test.ts") == "test"
    assert q.classify("scripts/test_frontend_compat.py") == "test"


def test_classify_ignores_non_source():
    assert q.classify("README.md") == "other"
    assert q.classify("package-lock.json") == "other"


# --- coupling degree ------------------------------------------------------

def test_degree_uses_the_larger_denominator():
    # Measured on terminal-lobby's telemetry pair: 9 co-changes over 15 and 18.
    assert q.coupling_degree(15, 18, 9) == 0.5
    # min-denominator would flatter it to 0.6, which is why max is the choice.
    assert round(9 / min(15, 18), 1) == 0.6


def test_degree_is_zero_when_nothing_changed():
    assert q.coupling_degree(0, 0, 0) == 0.0


# --- language -------------------------------------------------------------

def test_ts_and_tsx_are_one_language():
    # A .tsx/.ts pair was reported as cross-language on the first real run.
    assert not q.cross_language("a/Session.tsx", "b/session.ts")


def test_go_against_ts_is_cross_language():
    assert q.cross_language("frontend-v2/src/telemetry/track.ts",
                            "telemetry/events.go")


# --- test_partner ---------------------------------------------------------

def test_source_and_its_own_test_are_a_partner_pair():
    assert q.test_partner("tmux-api/pushsender.go", "tmux-api/pushsender_test.go")
    assert q.test_partner("frontend-v2/src/store/lobby.ts",
                          "frontend-v2/test/lobby.test.ts")


def test_partner_handles_a_qualified_test_name():
    # watchmode.auto.test.ts covers store/watchmode.ts; the qualifier must not
    # stop them pairing, or the pair shows up as a finding.
    assert q.test_partner("frontend-v2/src/store/watchmode.ts",
                          "frontend-v2/test/watchmode.auto.test.ts")


def test_two_same_named_sources_are_not_a_partner_pair():
    # The bug that mattered most: both stems reduce to "sw", so without the
    # prod/test condition the byte-identical copies excluded themselves and the
    # repo scored a clean zero.
    assert not q.test_partner("frontend-v2/public/sw.js", "frontend/sw.js")


def test_two_tests_are_not_a_partner_pair():
    assert not q.test_partner("frontend-v2/test/a.test.ts",
                              "frontend-v2/test/b.test.ts")


# --- same_go_package ------------------------------------------------------

def test_same_directory_go_files_are_one_unit():
    assert q.same_go_package("skills-api/main.go", "skills-api/privop.go")


def test_go_files_in_different_packages_are_not():
    assert not q.same_go_package("skills-api/main.go", "tmux-api/main.go")


def test_same_directory_non_go_is_not_exempt():
    assert not q.same_go_package("a/x.ts", "a/y.ts")


# --- concentration --------------------------------------------------------

def test_concentration_is_a_percent_of_touches():
    assert q.concentration([10, 10, 10, 10], top_n=2) == 50.0
    assert q.concentration([], top_n=10) == 0.0


def test_concentration_saturates_when_all_work_is_in_the_top_n():
    assert q.concentration([5, 3], top_n=10) == 100.0


# --- diff -----------------------------------------------------------------

def test_diff_flags_a_size_shaped_move():
    old = {"sloc_prod": 1000, "sloc_test": 0, "invisible_coupling_pairs": 10}
    new = {"sloc_prod": 500, "sloc_test": 0, "invisible_coupling_pairs": 5}
    rows = {r["metric"]: r for r in q.diff_series(old, new)}
    # Halving the codebase halved the pairs. That is not an improvement, and the
    # diff has to say so rather than let a reader claim one.
    assert "size-shaped" in rows["invisible_coupling_pairs"]["note"]


def test_diff_stays_quiet_when_size_held_still():
    old = {"sloc_prod": 1000, "sloc_test": 0, "invisible_coupling_pairs": 10}
    new = {"sloc_prod": 1005, "sloc_test": 0, "invisible_coupling_pairs": 5}
    rows = {r["metric"]: r for r in q.diff_series(old, new)}
    assert rows["invisible_coupling_pairs"]["note"] == ""
    assert rows["invisible_coupling_pairs"]["delta"] == -5


# --- the banned list is a contract, not a comment --------------------------

def test_banned_metrics_are_never_emitted():
    import json
    cfg = json.loads(q.DETECTORS.read_text())
    banned = set(cfg["banned"]["metrics"])
    assert banned, "the banned list must not be empty"
    fake = {
        "repo": "x", "sloc": {"prod": 1, "test": 1},
        "invisible_coupling": {"pair_count": 0, "max_degree": 0.0,
                               "identical_pairs": 0},
        "change_concentration": {"ratio_pct": 0.0},
        "bug_magnets": {"count": 0},
        "rework": {"pct": 0.0, "commits": 0},
    }
    emitted = set(q.series(fake))
    assert not (emitted & banned), f"a rejected metric came back: {emitted & banned}"
