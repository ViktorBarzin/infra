#!/usr/bin/env python3
"""Tests for the pure seams of dns_digest. Zero-dependency:
`python3 dns_digest_test.py`.

The log lines are real dnsmasq --log-queries=extra lines from the London Flint
(2026-10 / 2026-11), as Loki stores them (message body only). The feed header
is HaGeZi TIF's real header.
"""
import datetime as dt
import json

from dns_digest import (
    FeedError,
    build_device_map,
    build_digest,
    check_feed,
    coverage_gaps,
    device_name,
    error_query_regex,
    errors_worth_posting,
    feed_match,
    find_threats,
    instance_of,
    is_fingerprint,
    logql_alternation,
    metrics_text,
    parse_error_line,
    parse_feed,
    parse_query_line,
    parse_sofia_coverage,
    parse_sofia_lookups,
)

DATE = "Wed 04 Nov 2026"
NOW = dt.datetime(2026, 11, 4, 8, 0, tzinfo=dt.timezone.utc)

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

FEED_HEADER = (
    "# Title: HaGeZi's Threat Intelligence Feeds - a serious security boost (recommended)\n"
    "# Expires: 8 hours\n"
    "# Last modified: 03 Nov 2026 09:17 UTC\n"
    "# Version: 2026.1103.0917.44\n"
    "# Syntax: Domains (without subdomains)\n"
    "# Number of entries: 4\n"
    "#\n"
)
FEED = FEED_HEADER + "pahtef.tech\npolyfill.io\nEvil-Example.COM.\n000webhostapp.com\n"


def _snap(neigh4=NEIGH4, neigh6=NEIGH6, leases=LEASES):
    return json.dumps({"neigh4": neigh4, "neigh6": neigh6, "leases": leases})


def _feed(text=FEED):
    return parse_feed(text.splitlines())


# --- dnsmasq lines ---------------------------------------------------------

def test_parse_error_line_reply_and_config_errors():
    assert parse_error_line("33590 127.0.0.1/59479 reply error is SERVFAIL") == (
        "33590", "127.0.0.1", "59479", "SERVFAIL", "reply")
    assert parse_error_line(
        "12 2a01:4b00:ab23:1200:411:63e5:a806:8143/65147 reply error is REFUSED"
    ) == ("12", "2a01:4b00:ab23:1200:411:63e5:a806:8143", "65147", "REFUSED", "reply")
    # The 2 Nov outage: dnsmasq could not reach any upstream.
    assert parse_error_line("21299933 192.168.9.117/8512 config error is REFUSED (EDE: network error)") == (
        "21299933", "192.168.9.117", "8512", "REFUSED", "config")


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
    assert parse_query_line("1057548 192.168.8.114/54612 query[TXT] version.maradns from 192.168.8.114") == (
        "1057548", "192.168.8.114", "54612", "version.maradns")
    assert parse_query_line("33590 127.0.0.1/59479 reply error is SERVFAIL") is None


def test_error_query_regex_matches_only_the_named_queries():
    import re
    rx = re.compile(error_query_regex([("33590", "127.0.0.1", "59479"), ("7", "2a01::1", "53")]))
    assert rx.search("33590 127.0.0.1/59479 query[A] dnssec-failed.org from 127.0.0.1")
    assert rx.search("7 2a01::1/53 query[AAAA] x.example from 2a01::1")
    assert not rx.search("133590 127.0.0.1/59479 query[A] other.org from 127.0.0.1")
    assert not rx.search("33590 127.0.0.1/59478 query[A] other.org from 127.0.0.1")


def test_logql_alternation_escapes_dots():
    import re
    rx = re.compile(logql_alternation(["pahtef.tech", "a-b.example"]))
    assert rx.fullmatch("pahtef.tech") and rx.fullmatch("a-b.example")
    assert not rx.fullmatch("pahtefxtech")


# --- errors: what is worth a post ------------------------------------------

def test_fingerprint_names_are_recognised():
    for name in ("version.bind", "VERSION.BIND.", "version.maradns", "version.mydns", "version.pdns",
                 "erre-con-erre-cigarro.maradns.org", "id.server", "hostname.bind", "version.server"):
        assert is_fingerprint(name), name
    assert not is_fingerprint("printer.glb.thefacebook.com")
    assert not is_fingerprint("bind.example.com")


AVAST = [("192.168.8.114", n, "REFUSED", "reply", 1)
         for n in ("version.maradns", "version.mydns", "version.pdns", "erre-con-erre-cigarro.maradns.org")]


def test_avast_probes_alone_are_not_worth_posting():
    assert errors_worth_posting(AVAST, 0) == []


def test_one_or_two_failing_names_are_not_worth_posting():
    errs = AVAST + [("2a01::a", "printer.glb.thefacebook.com", "SERVFAIL", "reply", 264),
                    ("2a01::a", "zf32.xs.alibabachengdun.com", "SERVFAIL", "reply", 3)]
    assert errors_worth_posting(errs, 0) == []


def test_three_distinct_failing_names_are_worth_posting_without_fingerprints():
    errs = AVAST + [("c", "a.example", "SERVFAIL", "reply", 1), ("c", "b.example", "SERVFAIL", "reply", 1),
                    ("d", "c.example", "REFUSED", "reply", 2)]
    kept = errors_worth_posting(errs, 0)
    assert {e[1] for e in kept} == {"a.example", "b.example", "c.example"}, kept


def test_any_config_error_is_worth_posting():
    errs = [("192.168.9.117", "www.google.com", "REFUSED", "config", 5)]
    assert errors_worth_posting(errs, 0) == errs


def test_overflow_alone_is_worth_posting():
    assert errors_worth_posting([], 2) == []
    assert errors_worth_posting([("c", "x.org", "SERVFAIL", "reply", 1)], 2) == [
        ("c", "x.org", "SERVFAIL", "reply", 1)]


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


# --- threat feed -----------------------------------------------------------

def test_parse_feed_reads_header_and_normalises_entries():
    feed = _feed()
    assert feed.header_count == 4
    assert feed.modified == dt.datetime(2026, 11, 3, 9, 17, tzinfo=dt.timezone.utc)
    assert feed.domains == {"pahtef.tech", "polyfill.io", "evil-example.com", "000webhostapp.com"}


def test_check_feed_accepts_a_fresh_complete_feed():
    check_feed(_feed(), NOW)


def test_check_feed_rejects_a_truncated_feed():
    text = FEED_HEADER.replace("Number of entries: 4", "Number of entries: 400") + "pahtef.tech\n"
    try:
        check_feed(_feed(text), NOW)
    except FeedError as e:
        assert "1 of 400" in str(e), e
    else:
        raise AssertionError("truncated feed accepted")


def test_check_feed_rejects_a_stale_feed():
    try:
        check_feed(_feed(), NOW + dt.timedelta(days=4))
    except FeedError as e:
        assert "old" in str(e), e
    else:
        raise AssertionError("stale feed accepted")


def test_check_feed_rejects_a_feed_without_a_header():
    try:
        check_feed(_feed("pahtef.tech\n"), NOW)
    except FeedError:
        pass
    else:
        raise AssertionError("headerless feed accepted")


def test_feed_match_covers_subdomains_but_not_lookalikes():
    domains = _feed().domains
    assert feed_match("pahtef.tech", domains) == "pahtef.tech"
    assert feed_match("cdn.polyfill.io", domains) == "polyfill.io"
    assert feed_match("A.B.Evil-Example.com.", domains) == "evil-example.com"
    assert feed_match("notpahtef.tech", domains) is None
    assert feed_match("polyfill.io.example.net", domains) is None
    assert feed_match("tech", domains) is None


def test_find_threats_keeps_site_client_count_and_block_state():
    rows = [("Sofia", "192.168.1.144", "pahtef.tech", 2, True),
            ("Sofia", "192.168.1.144", "www.24zdrave.bg", 3, False),
            ("London", "192.168.8.198", "cdn.polyfill.io", 20, False)]
    assert find_threats(rows, _feed().domains) == [
        ("London", "192.168.8.198", "cdn.polyfill.io", "polyfill.io", 20, False),
        ("Sofia", "192.168.1.144", "pahtef.tech", "pahtef.tech", 2, True),
    ]


# --- Sofia query log -------------------------------------------------------

def test_parse_sofia_lookups_from_psql_csv():
    csv_text = ("192.168.1.144,pahtef.tech,2,t\n"
                "192.168.1.8,\"weird,name.example\",5,f\n"
                "10.10.0.1,,1,f\n")
    assert parse_sofia_lookups(csv_text) == [
        ("Sofia", "192.168.1.144", "pahtef.tech", 2, True),
        ("Sofia", "192.168.1.8", "weird,name.example", 5, False),
    ]


def test_instance_of_strips_the_pod_suffix():
    assert instance_of("technitium-658c8944b9-lmd52") == "technitium"
    assert instance_of("technitium-secondary-7b499c9b69-ld8cq") == "technitium-secondary"
    assert instance_of("custom-name") == "custom-name"


def test_coverage_gaps_names_each_quiet_instance_and_hour():
    h = [NOW - dt.timedelta(hours=i) for i in range(3, 0, -1)]  # 05:00, 06:00, 07:00
    counts = parse_sofia_coverage(
        "technitium-658c8944b9-lmd52,2026-11-04 05:00:00+00,900\n"
        "technitium-658c8944b9-lmd52,2026-11-04 06:00:00+00,800\n"
        "technitium-658c8944b9-lmd52,2026-11-04 07:00:00+00,700\n"
        "technitium-secondary-7b499c9b69-ld8cq,2026-11-04 05:00:00+00,10\n"
    )
    gaps = coverage_gaps(counts, ["technitium", "technitium-secondary", "technitium-tertiary"], h)
    assert gaps == {"technitium-secondary": h[1:], "technitium-tertiary": h}, gaps


def test_coverage_gaps_ignore_hours_before_coverage_start():
    h = [NOW - dt.timedelta(hours=i) for i in range(3, 0, -1)]
    gaps = coverage_gaps({}, ["technitium-tertiary"], h, since=h[2])
    assert gaps == {"technitium-tertiary": [h[2]]}, gaps


# --- the message -----------------------------------------------------------

def _digest(**kw):
    args = dict(errors=[], overflow=0, dpi={}, threats=[], gaps=[], devices={}, date_label=DATE)
    args.update(kw)
    return build_digest(**args)


def test_none_when_nothing_to_report():
    assert _digest() is None


def test_threats_section_names_devices_and_block_state():
    devices = build_device_map([_snap()])
    devices["192.168.1.144"] = "192.168.1.144"
    msg = _digest(threats=[("London", "192.168.8.198", "cdn.polyfill.io", "polyfill.io", 20, False),
                           ("Sofia", "192.168.1.144", "pahtef.tech", "pahtef.tech", 2, True)],
                  devices=devices)
    assert "DNS digest" in msg and DATE in msg, msg
    assert "Threat-feed matches" in msg, msg
    assert "London, Portal-75AE8F9C2A8A: cdn.polyfill.io x20 (feed entry polyfill.io), not blocked" in msg, msg
    assert "Sofia, 192.168.1.144: pahtef.tech x2, blocked" in msg, msg


def test_errors_section_with_device_names_and_overflow():
    devices = build_device_map([_snap()])
    msg = _digest(errors=[("192.168.8.198", "dnssec-failed.org", "SERVFAIL", "reply", 3),
                          ("10.9.9.9", "www.google.com", "REFUSED", "config", 1)],
                  overflow=2, devices=devices)
    assert "London DNS errors" in msg, msg
    assert "Portal-75AE8F9C2A8A: dnssec-failed.org SERVFAIL x3" in msg, msg
    assert "10.9.9.9: www.google.com REFUSED (no upstream answered) x1" in msg, msg
    assert "concurrent-query limit 2 times" in msg, msg


def test_errors_from_two_addresses_of_one_device_are_merged():
    snap = _snap(neigh6="2a01::a dev br-lan lladdr f8:2a:e2:64:7c:f7 REACHABLE \n"
                        "2a01::b dev br-lan lladdr f8:2a:e2:64:7c:f7 STALE ")
    msg = _digest(errors=[("2a01::a", "printer.example", "SERVFAIL", "reply", 2),
                          ("2a01::b", "printer.example", "SERVFAIL", "reply", 2)],
                  devices=build_device_map([snap]))
    assert msg.count("printer.example") == 1, msg
    assert "mbp-london: printer.example SERVFAIL x4" in msg, msg


def test_long_error_lists_are_capped():
    errs = [("c", "n%02d.example" % i, "SERVFAIL", "reply", 1) for i in range(40)]
    msg = _digest(errors=errs)
    assert "+%d more" % (40 - 15) in msg, msg


def test_dpi_section_carries_unblock_hint():
    devices = build_device_map([_snap()])
    msg = _digest(dpi={"192.168.8.198": [("conduit-services.com", 1)]}, devices=devices)
    assert "Blocked by GL content protection" in msg, msg
    assert "Portal-75AE8F9C2A8A: conduit-services.com x1" in msg, msg


def test_gaps_section_lists_hours():
    h = [dt.datetime(2026, 11, 4, x, 0, tzinfo=dt.timezone.utc) for x in (2, 3)]
    msg = _digest(gaps=[("Sofia query log", "technitium-tertiary", h), ("London query log", None, h[:1])])
    assert "Monitoring gaps" in msg, msg
    assert "Sofia query log: technitium-tertiary logged nothing in 2 of the last 24 hours (02:00, 03:00 UTC)" in msg, msg
    assert "London query log: nothing in 1 of the last 24 hours (02:00 UTC)" in msg, msg


def test_gaps_section_for_a_whole_silent_day():
    h = [dt.datetime(2026, 11, 3, 8, 0, tzinfo=dt.timezone.utc) + dt.timedelta(hours=i) for i in range(24)]
    msg = _digest(gaps=[("Sofia query log", "technitium-secondary", h)])
    assert "technitium-secondary logged nothing in any of the last 24 hours" in msg, msg


def test_no_blocked_name_lists_any_more():
    msg = _digest(errors=[("c", "x.org", "SERVFAIL", "config", 1)])
    assert "Newly blocked" not in msg and "94.140.14.140" not in msg, msg


# --- metrics ---------------------------------------------------------------

def test_metrics_text_for_pushgateway():
    text = metrics_text({"London": 2700, "Sofia": 900}, feed_entries=1814363, matches=1, now=NOW)
    assert 'dns_digest_names_checked{site="London"} 2700' in text, text
    assert 'dns_digest_names_checked{site="Sofia"} 900' in text, text
    assert "dns_digest_feed_entries 1814363" in text, text
    assert "dns_digest_threat_matches 1" in text, text
    assert "dns_digest_last_success %d" % int(NOW.timestamp()) in text, text
    assert text.endswith("\n")


if __name__ == "__main__":
    import sys
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
