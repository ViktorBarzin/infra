#!/usr/bin/env python3
"""Tests for the pure seams of london_dns_digest. Zero-dependency:
`python3 london_dns_digest_test.py`.

The log lines are real dnsmasq --log-queries=extra lines from the London Flint
(2026-10-02), as Loki stores them (message body only).
"""
import json

from london_dns_digest import (
    build_device_map,
    build_digest,
    device_name,
    error_query_regex,
    in_learning,
    new_blocks,
    parse_error_line,
    parse_query_line,
)

DATE = "Sat 03 Oct 2026"

LEASES = (
    "43200 a4:0e:2b:0e:48:a3 192.168.8.198 Portal-75AE8F9C2A8A 01:a4:0e:2b:0e:48:a3\n"
    "43200 f8:2a:e2:64:7c:f7 192.168.8.168 mbp-london 01:f8:2a:e2:64:7c:f7\n"
    "43200 7e:d0:86:38:d9:30 192.168.8.140 * 01:7e:d0:86:38:d9:30"
)
NEIGH6 = (
    "2a01:4b00:ab23:1200:411:63e5:a806:8143 dev br-lan lladdr f8:2a:e2:64:7c:f7 REACHABLE \n"
    "fe80::1894:3d60:ccf3:1852 dev br-lan lladdr 7e:d0:86:38:d9:30 STALE \n"
    "2a01:4b00:ab23:1200::99 dev br-lan  FAILED "
)
NEIGH4 = "192.168.8.198 dev br-lan lladdr a4:0e:2b:0e:48:a3 REACHABLE "


def _snap(neigh4=NEIGH4, neigh6=NEIGH6, leases=LEASES):
    return json.dumps({"neigh4": neigh4, "neigh6": neigh6, "leases": leases})


# --- parsing ---------------------------------------------------------------

def test_parse_error_line():
    assert parse_error_line("33590 127.0.0.1/59479 reply error is SERVFAIL") == (
        "33590", "127.0.0.1", "59479", "SERVFAIL")
    assert parse_error_line(
        "12 2a01:4b00:ab23:1200:411:63e5:a806:8143/65147 reply error is REFUSED"
    ) == ("12", "2a01:4b00:ab23:1200:411:63e5:a806:8143", "65147", "REFUSED")


def test_parse_error_line_ignores_other_lines():
    for line in (
        "1240 127.0.0.1/41275 reply doubleclick.net is 0.0.0.0",
        "33590 127.0.0.1/59479 query[A] dnssec-failed.org from 127.0.0.1",
        "Maximum number of concurrent DNS queries reached (max: 150)",
        "",
    ):
        assert parse_error_line(line) is None, line


def test_parse_query_line():
    assert parse_query_line("33590 127.0.0.1/59479 query[A] dnssec-failed.org from 127.0.0.1") == (
        "33590", "127.0.0.1", "59479", "dnssec-failed.org")
    assert parse_query_line(
        "2347 2a01:4b00:ab23:1200:411:63e5:a806:8143/65147 query[HTTPS] "
        "browser-bridge.internalmeta.com from 2a01:4b00:ab23:1200:411:63e5:a806:8143"
    ) == ("2347", "2a01:4b00:ab23:1200:411:63e5:a806:8143", "65147", "browser-bridge.internalmeta.com")
    assert parse_query_line("33590 127.0.0.1/59479 reply error is SERVFAIL") is None


def test_error_query_regex_matches_only_the_named_queries():
    import re
    rx = re.compile(error_query_regex([("33590", "127.0.0.1", "59479"), ("7", "2a01::1", "53")]))
    assert rx.search("33590 127.0.0.1/59479 query[A] dnssec-failed.org from 127.0.0.1")
    assert rx.search("7 2a01::1/53 query[AAAA] x.example from 2a01::1")
    assert not rx.search("133590 127.0.0.1/59479 query[A] other.org from 127.0.0.1")
    assert not rx.search("33590 127.0.0.1/59478 query[A] other.org from 127.0.0.1")


# --- devices ---------------------------------------------------------------

def test_device_map_joins_ipv6_neighbour_to_lease_hostname():
    m = build_device_map([_snap()])
    assert device_name("2a01:4b00:ab23:1200:411:63e5:a806:8143", m) == "mbp-london"
    assert device_name("192.168.8.198", m) == "Portal-75AE8F9C2A8A"


def test_device_without_hostname_shows_mac():
    m = build_device_map([_snap()])
    assert device_name("fe80::1894:3d60:ccf3:1852", m) == "7e:d0:86:38:d9:30"


def test_unknown_and_router_addresses():
    m = build_device_map([_snap()])
    assert device_name("2a01:4b00:ab23:1200::99", m) == "2a01:4b00:ab23:1200::99"  # FAILED, no lladdr
    assert device_name("127.0.0.1", m) == "the Flint"
    assert device_name("::1", m) == "the Flint"


def test_later_snapshot_wins_and_bad_lines_are_skipped():
    older = _snap(neigh6="2a01::5 dev br-lan lladdr a4:0e:2b:0e:48:a3 STALE ")
    newer = _snap(neigh6="2a01::5 dev br-lan lladdr f8:2a:e2:64:7c:f7 REACHABLE ")
    m = build_device_map([older, "not json", newer])
    assert device_name("2a01::5", m) == "mbp-london"


# --- new blocks and learning -----------------------------------------------

def test_new_blocks_drops_domains_seen_in_history():
    today = {("192.168.8.198", "graph.facebook.com"): 4, ("192.168.8.198", "doubleclick.net"): 9,
             ("192.168.8.168", "shop-ads.example"): 1}
    history = {"doubleclick.net"}
    assert new_blocks(today, history) == {
        "192.168.8.198": [("graph.facebook.com", 4)],
        "192.168.8.168": [("shop-ads.example", 1)],
    }


def test_new_blocks_sorted_by_count_then_name():
    today = {("c", "b.example"): 2, ("c", "a.example"): 2, ("c", "z.example"): 5}
    assert new_blocks(today, set()) == {"c": [("z.example", 5), ("a.example", 2), ("b.example", 2)]}


def test_in_learning():
    import datetime as dt
    start = dt.datetime(2026, 10, 2, 16, 10, tzinfo=dt.timezone.utc)
    assert in_learning(start, start + dt.timedelta(days=6, hours=23))
    assert not in_learning(start, start + dt.timedelta(days=7))


# --- the message -----------------------------------------------------------

def test_none_when_nothing_to_report():
    assert build_digest(errors=[], overflow=0, blocks={}, dpi={}, learning=False,
                        devices={}, date_label=DATE) is None


def test_none_when_only_blocks_during_learning():
    assert build_digest(errors=[], overflow=0, blocks={"c": [("x.example", 1)]}, dpi={},
                        learning=True, devices={}, date_label=DATE) is None


def test_errors_section_with_device_names_and_overflow():
    devices = build_device_map([_snap()])
    msg = build_digest(
        errors=[("192.168.8.198", "dnssec-failed.org", "SERVFAIL", 3),
                ("10.9.9.9", "(unknown name)", "REFUSED", 1)],
        overflow=2, blocks={}, dpi={}, learning=False, devices=devices, date_label=DATE)
    assert "London DNS" in msg and DATE in msg, msg
    assert "Portal-75AE8F9C2A8A: dnssec-failed.org SERVFAIL x3" in msg, msg
    assert "10.9.9.9: (unknown name) REFUSED x1" in msg, msg
    assert "concurrent-query limit 2 times" in msg, msg


def test_errors_from_two_addresses_of_one_device_are_merged():
    snap = _snap(neigh6="2a01::a dev br-lan lladdr f8:2a:e2:64:7c:f7 REACHABLE \n"
                        "2a01::b dev br-lan lladdr f8:2a:e2:64:7c:f7 STALE ")
    msg = build_digest(errors=[("2a01::a", "printer.example", "SERVFAIL", 2),
                               ("2a01::b", "printer.example", "SERVFAIL", 2)],
                       overflow=0, blocks={}, dpi={}, learning=False,
                       devices=build_device_map([snap]), date_label=DATE)
    assert msg.count("printer.example") == 1, msg
    assert "mbp-london: printer.example SERVFAIL x4" in msg, msg


def test_blocks_and_dpi_sections_carry_unblock_hints():
    devices = build_device_map([_snap()])
    msg = build_digest(
        errors=[], overflow=0,
        blocks={"2a01:4b00:ab23:1200:411:63e5:a806:8143": [("shop-ads.example", 2)]},
        dpi={"192.168.8.198": [("conduit-services.com", 1)]},
        learning=False, devices=devices, date_label=DATE)
    assert "Newly blocked by AdGuard" in msg, msg
    assert "mbp-london: shop-ads.example x2" in msg, msg
    assert "94.140.14.140" in msg and "dnsmasq restart" in msg, msg
    assert "Blocked by GL content protection" in msg, msg
    assert "Portal-75AE8F9C2A8A: conduit-services.com x1" in msg, msg


def test_learning_hides_blocks_but_keeps_errors():
    msg = build_digest(errors=[("c", "x.org", "SERVFAIL", 1)], overflow=0,
                       blocks={"c": [("ads.example", 1)]}, dpi={}, learning=True,
                       devices={}, date_label=DATE)
    assert "x.org" in msg and "ads.example" not in msg, msg


def test_long_lists_are_capped():
    blocks = {"c": [("d%02d.example" % i, 1) for i in range(30)]}
    msg = build_digest(errors=[], overflow=0, blocks=blocks, dpi={}, learning=False,
                       devices={}, date_label=DATE)
    assert "d00.example" in msg and "d29.example" not in msg, msg
    assert "+20 more" in msg, msg


if __name__ == "__main__":
    import sys
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("ok  ", name)
            except AssertionError as e:
                failed += 1
                print("FAIL", name, e)
    sys.exit(1 if failed else 0)
