#!/usr/bin/env python3
"""Tests for cisa_kev. Zero-dependency: `python3 cisa_kev_test.py`.

The feed sample has the shape of CISA's known_exploited_vulnerabilities.json
(fields trimmed to the ones the job reads).
"""
import sys

from cisa_kev import FeedError, metrics_text, parse_feed

FEED = {
    "title": "CISA Catalog of Known Exploited Vulnerabilities",
    "catalogVersion": "2026.11.07",
    "count": 3,
    "vulnerabilities": [
        {"cveID": "CVE-2026-111497", "dateAdded": "2026-10-27"},
        {"cveID": "CVE-2025-27363", "dateAdded": "2025-05-06"},
        {"cveID": "CVE-2023-44487", "dateAdded": "2023-10-10"},
    ],
}


def test_parse_feed_returns_each_cve_with_its_date_added_as_epoch():
    got = parse_feed(FEED, min_entries=1)
    assert got["CVE-2026-111497"] == 1793059200, got
    assert got["CVE-2023-44487"] == 1696896000, got
    assert len(got) == 3


def test_parse_feed_rejects_a_truncated_feed():
    try:
        parse_feed(FEED, min_entries=1000)
    except FeedError as e:
        assert "3" in str(e)
        return
    raise AssertionError("a 3-entry feed passed a 1000-entry floor")


def test_parse_feed_skips_malformed_ids_and_duplicates():
    feed = {"vulnerabilities": FEED["vulnerabilities"] + [
        {"cveID": "not-a-cve", "dateAdded": "2026-01-01"},
        {"cveID": 'CVE-2026-1"} evil', "dateAdded": "2026-01-01"},
        {"cveID": "CVE-2026-111497", "dateAdded": "2026-10-28"},
        {"cveID": "CVE-2026-0001"},
    ]}
    got = parse_feed(feed, min_entries=1)
    assert set(got) == {"CVE-2026-111497", "CVE-2025-27363", "CVE-2023-44487", "CVE-2026-0001"}, got
    assert got["CVE-2026-111497"] == 1793059200, "first entry wins"
    assert got["CVE-2026-0001"] == 0, "no dateAdded is 0"


def test_parse_feed_rejects_a_feed_without_a_list():
    for bad in ({}, {"vulnerabilities": "x"}, []):
        try:
            parse_feed(bad, min_entries=0)
        except FeedError:
            continue
        raise AssertionError("accepted %r" % (bad,))


def test_metrics_text_has_one_series_per_cve_plus_totals():
    text = metrics_text({"CVE-2023-44487": 1696896000, "CVE-2025-27363": 1746489600}, now=1794268800)
    lines = [l for l in text.splitlines() if l and not l.startswith("#")]
    assert 'cisa_kev_listed{vuln_id="CVE-2023-44487"} 1696896000' in lines, text
    assert 'cisa_kev_listed{vuln_id="CVE-2025-27363"} 1746489600' in lines, text
    assert "cisa_kev_entries 2" in lines, text
    assert "cisa_kev_last_success_timestamp_seconds 1794268800" in lines, text
    assert text.endswith("\n")


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("ok   " + name)
            except Exception as e:
                failed += 1
                print("FAIL %s: %r" % (name, e))
    sys.exit(1 if failed else 0)
