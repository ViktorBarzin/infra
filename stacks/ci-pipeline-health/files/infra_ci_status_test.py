#!/usr/bin/env python3
"""Tests for infra_ci_status. Zero-dependency: `python3 infra_ci_status_test.py`.

The pipelines are repo 82's push pipelines on master as the Woodpecker API
returned them on 2026-11-27, trimmed to the fields the job reads. #4542-#4592
all ended `error` at lint time ("Insufficient trust level to use privileged
mode"), so nothing applied for a day.
"""
import json
import sys

from infra_ci_status import metrics_text, newest_master_pushes, summarise


def pl(number, status, finished, event="push", branch="master"):
    return {"number": number, "status": status, "event": event, "branch": branch,
            "created": finished - 60 if finished else 1795781700, "finished": finished}


# Newest first, as the API lists them.
INCIDENT = [
    pl(4593, "running", 0),
    pl(4592, "error", 1795781513),
    pl(4591, "error", 1795781395),
    pl(4590, "error", 1795781138),
    pl(4542, "error", 1795694938),
    pl(4541, "success", 1795692794),
    pl(4540, "success", 1795691696),
    pl(4536, "killed", 1795688553),
]


def test_counts_the_errors_since_the_newest_success_and_skips_a_running_pipeline():
    s = summarise(INCIDENT)
    assert s.red_streak == 4, s
    assert s.last_success == 1795692794, s
    assert s.newest_red == 4592, s


def test_a_success_on_top_clears_the_streak():
    s = summarise([pl(4594, "success", 1795782000)] + INCIDENT)
    assert s.red_streak == 0, s
    assert s.last_success == 1795782000, s
    assert s.newest_red == 0, s


def test_failure_and_killed_count_as_red_and_pending_counts_neither_way():
    s = summarise([
        pl(10, "pending", 0),
        pl(9, "killed", 1700000900),
        pl(8, "failure", 1700000800),
        pl(7, "running", 0),
        pl(6, "error", 1700000600),
        pl(5, "success", 1700000500),
    ])
    assert s.red_streak == 3, s
    assert s.newest_red == 9, s
    assert s.last_success == 1700000500, s


def test_order_comes_from_the_pipeline_number_not_the_list_position():
    s = summarise(list(reversed(INCIDENT)))
    assert s.red_streak == 4, s
    assert s.newest_red == 4592, s


def test_no_success_in_the_window_reports_last_success_zero():
    s = summarise([pl(3, "error", 1700000300), pl(2, "error", 1700000200)])
    assert s.red_streak == 2, s
    assert s.last_success == 0, s


def test_a_success_without_finished_falls_back_to_created():
    p = pl(5, "success", 0)
    p["created"] = 1700000000
    assert summarise([p]).last_success == 1700000000


def test_other_branches_and_events_are_ignored():
    got = newest_master_pushes([
        pl(4588, "error", 1795774842, branch="renovate/tor-proxy"),
        pl(4587, "error", 1795764033),
        pl(4586, "success", 1795764030, event="cron"),
        pl(4585, "success", 1795753258, event="pull_request"),
    ])
    assert [p["number"] for p in got] == [4587], got


def test_metrics_text_is_valid_exposition_with_every_gauge():
    text = metrics_text(summarise(INCIDENT), now=1795782600)
    lines = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
    values = dict(ln.split(" ", 1) for ln in lines)
    assert values == {
        "infra_ci_red_streak": "4",
        "infra_ci_last_success_timestamp_seconds": "1795692794",
        "infra_ci_newest_red_pipeline": "4592",
        "infra_ci_status_last_run_timestamp_seconds": "1795782600",
    }, values
    assert text.endswith("\n")
    for name in values:
        assert "# TYPE %s gauge" % name in text


def test_raw_control_characters_in_commit_messages_parse():
    # Repo 82's JSON has carried raw control characters, which a strict
    # parser rejects.
    from infra_ci_status import parse_json
    raw = '[{"number": 1, "status": "success", "event": "push", "branch": "master",' \
          ' "created": 5, "finished": 6, "message": "a\tb\x01"}]'
    assert parse_json(raw)[0]["number"] == 1
    assert json.dumps(parse_json(raw))


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("ok   %s" % name)
            except AssertionError as e:
                failed += 1
                print("FAIL %s: %s" % (name, e))
    sys.exit(1 if failed else 0)
