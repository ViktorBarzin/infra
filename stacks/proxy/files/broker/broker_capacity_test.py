#!/usr/bin/env python3
"""Tests for the reaper's pure timestamp helper. Zero-dependency:
`python3 broker_capacity_test.py`. The capacity check (browser count) and the
reaper deletes are thin k8s-API I/O, validated live.
"""
import broker


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
