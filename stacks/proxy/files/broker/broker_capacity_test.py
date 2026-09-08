#!/usr/bin/env python3
"""Tests for the reaper's pure timestamp helper. Zero-dependency:
`python3 broker_capacity_test.py`. The capacity check (browser count) and the
reaper deletes are thin k8s-API I/O, validated live.
"""
import broker
import pool


def _routes(*userkeys):
    return [{"userkey": uk, "name": "proxy-br-" + uk} for uk in userkeys]


def test_orphan_routing_ignores_routes_whose_pod_is_alive():
    orphans, streak = pool.plan_orphan_routing_reaping(
        _routes("alice"), {"proxy-br-alice"}, {}, required_streak=3)
    assert orphans == []
    # a live pod must not accumulate a streak, or it would eventually be reaped
    assert streak == {}


def test_orphan_routing_needs_consecutive_misses():
    """One missed tick is a browser being recreated (switch-country), not a leak."""
    streak = {}
    for tick in range(1, 3):
        orphans, streak = pool.plan_orphan_routing_reaping(
            _routes("bob"), set(), streak, required_streak=3)
        assert orphans == [], "reaped after only %d tick(s)" % tick
    orphans, streak = pool.plan_orphan_routing_reaping(
        _routes("bob"), set(), streak, required_streak=3)
    assert orphans == ["bob"]


def test_orphan_routing_streak_resets_when_pod_returns():
    _, streak = pool.plan_orphan_routing_reaping(
        _routes("carol"), set(), {}, required_streak=3)
    assert streak == {"carol": 1}
    # pod came back mid-recreate — the count must not carry over
    orphans, streak = pool.plan_orphan_routing_reaping(
        _routes("carol"), {"proxy-br-carol"}, streak, required_streak=3)
    assert orphans == [] and streak == {}


def test_orphan_routing_forgets_deleted_routes():
    """Once the Service is gone its streak must not linger and re-fire later."""
    _, streak = pool.plan_orphan_routing_reaping(
        _routes("dave"), set(), {}, required_streak=3)
    orphans, streak = pool.plan_orphan_routing_reaping([], set(), streak, required_streak=3)
    assert orphans == [] and streak == {}


def test_ts_parses_rfc3339():
    assert broker._ts("1970-01-01T00:00:00Z") == 0.0
    assert broker._ts("") == 0.0
    assert broker._ts(None) == 0.0
    assert broker._ts("not-a-time") == 0.0
    # a real creationTimestamp round-trips to a positive epoch
    assert broker._ts("2026-07-26T19:15:34Z") > 1_700_000_000
    # newer timestamp is strictly greater (the reaper's 5-min age gate relies on this)
    assert broker._ts("2026-07-26T19:20:00Z") > broker._ts("2026-07-26T19:15:00Z")


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print("broker_capacity: %d tests passed" % len(fns))


if __name__ == "__main__":
    _run()
