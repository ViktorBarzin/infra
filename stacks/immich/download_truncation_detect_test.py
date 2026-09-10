#!/usr/bin/env python3
"""Tests for download_truncation_detect.

The cases that matter are the ones separating a download that merely got cut
(fine, the client resumed) from one that was left partial (the real failure).
Both look identical in the access log until the sizes are joined in, so these
are built from real log lines captured on 2026-08-30.

The line shape is Traefik's JSON access log (the format since 2026-09-01),
copied from a line captured off traefik:v3.7.1 rather than written from the
docs — including the `\u0026` that Traefik's encoder puts where a query string
has an `&`, which is the detail a hand-written fixture gets wrong.

Run: python3 download_truncation_detect_test.py
"""

import json
import unittest

from download_truncation_detect import analyse, parse_lines


def line(ip, aid, status, nbytes, proto="HTTP/2.0", ua=None, path=None):
    """One Traefik JSON access-log line for a GET of an original asset."""
    obj = {
        "ClientAddr": f"{ip}:45246",
        "ClientHost": ip,
        "ClientPort": "45246",
        "ClientUsername": "-",
        "DownstreamContentSize": nbytes,
        "DownstreamStatus": status,
        "Duration": 9494000000,
        "OriginContentSize": nbytes,
        "OriginDuration": 9490000000,
        "OriginStatus": status,
        "Overhead": 4000000,
        "RequestAddr": "immich.viktorbarzin.me",
        "RequestContentSize": 0,
        "RequestCount": 1995191,
        "RequestHost": "immich.viktorbarzin.me",
        "RequestMethod": "GET",
        "RequestPath": path if path is not None
        else f"/api/assets/{aid}/original?key=k&edited=true",
        "RequestPort": "-",
        "RequestProtocol": proto,
        "RequestScheme": "https",
        "RetryAttempts": 0,
        "RouterName": "immich-immich-immich-viktorbarzin-me@kubernetes",
        "ServiceAddr": "10.10.122.155:2283",
        "ServiceName": "immich-immich-immich-viktorbarzin-me-immich-2283@kubernetes",
        "ServiceURL": "http://10.10.122.155:2283",
        "StartLocal": "2026-08-30T02:23:24.416301062Z",
        "StartUTC": "2026-08-30T02:23:24.416301062Z",
        "TLSCipher": "TLS_AES_128_GCM_SHA256",
        "TLSVersion": "1.3",
        "entryPointName": "websecure",
        "level": "info",
        "msg": "",
        "request_User-Agent": FF if ua is None else ua,
        "request_X-Authentik-Username": "viktor",
        "time": "2026-08-30T02:23:24Z",
    }
    # Traefik's encoder HTML-escapes &, < and > inside string values, so a real
    # line never carries a bare & in the query string. json.dumps does not do
    # that by default, so do it here or the fixture is not what Loki holds.
    out = json.dumps(obj, separators=(",", ":"), sort_keys=True)
    return (
        out.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    )


FF = "Mozilla/5.0 (Android 16; Mobile; rv:154.0) Gecko/154.0 Firefox/154.0"
CURL = "curl/8.5.0"
SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) Safari/605.1.15"

A = "ead39fa9-b377-48b8-9cf7-0a0f0ff41dd8"
B = "56495350-c804-4b72-b240-a9df6021e018"
IP1, IP2 = "185.139.138.221", "92.63.205.141"


class TestParse(unittest.TestCase):
    def test_extracts_fields(self):
        got = parse_lines([line(IP1, A, 200, 4239182)])
        self.assertEqual(got, [(IP1, A, 200, 4239182, FF)])

    def test_ignores_unrelated_lines(self):
        noise = [
            line("10.0.0.1", A, 200, 5, path="/"),
            line("10.0.0.1", A, 200, 5, path=f"/api/assets/{A}/thumbnail"),
            "not a log line at all",
            "",
            "{ this is not valid json",
            # The nginx auth-proxy and bot-block-proxy sit in the same
            # namespace and still log CLF. Their lines must be skipped, not
            # half-parsed.
            '10.0.20.1 - viktor [30/Aug/2026:02:00:00 +0000] "GET /auth HTTP/1.1" 200 7 "-" "curl/8.5.0"',
        ]
        self.assertEqual(parse_lines(noise), [])

    def test_asset_id_comes_from_the_request_path_field_only(self):
        # A crafted User-Agent must not be able to file metrics under a
        # different asset. The id is only ever read from the RequestPath field.
        # Traefik escapes quotes inside values, so the crafted key never even
        # looks like a key — but the parser must not depend on that: it reads
        # the field by name off a parsed object, never by searching the line.
        evil = line(
            IP1, A, 200, 100,
            ua=f'x","RequestPath":"/api/assets/{B}/original","z":"',
        )
        got = parse_lines([evil])
        self.assertEqual(len(got), 1)
        ip, aid, status, nbytes, ua = got[0]
        self.assertEqual(aid, A)
        self.assertNotEqual(aid, B)
        self.assertEqual((ip, status, nbytes), (IP1, 200, 100))
        self.assertIn(B, ua)  # it IS carried through, just not as the asset

    def test_asset_id_is_anchored_to_the_start_of_the_path(self):
        # A path that merely CONTAINS an asset-original segment further along
        # is not a download of that asset.
        sneaky = line(IP1, A, 200, 100, path=f"/share/x/api/assets/{B}/original")
        self.assertEqual(parse_lines([sneaky]), [])

    def test_escaped_ampersand_in_the_query_string_still_parses(self):
        # Traefik writes ?key=k&edited=true as ?key=k\u0026edited=true. A line
        # built by hand without that escape would pass while the real one fails.
        raw = line(IP1, A, 200, 4239182)
        self.assertIn("\\u0026", raw)
        self.assertEqual(parse_lines([raw]), [(IP1, A, 200, 4239182, FF)])

    def test_range_response_parses(self):
        got = parse_lines([line(IP1, A, 206, 1024)])
        self.assertEqual(got, [(IP1, A, 206, 1024, FF)])

    def test_missing_fields_do_not_raise(self):
        # A line from a different producer that happens to be valid JSON.
        self.assertEqual(parse_lines(['{"msg":"hello","level":"info"}']), [])

    def test_http3_lines_parse_too(self):
        got = parse_lines([line(IP1, A, 200, 3360762, proto="HTTP/3.0")])
        self.assertEqual(got, [(IP1, A, 200, 3360762, FF)])


class TestAnalyse(unittest.TestCase):
    def test_single_complete_response(self):
        r = analyse([(IP1, A, 200, 6544473, FF)], {A: 6544473})
        self.assertEqual((r["complete"], r["cut"], r["unrecovered"]), (1, 0, 0))

    def test_cut_then_resumed_is_not_a_failure(self):
        # The real IMG_20260824_141031_1.jpg sequence: two short attempts, then
        # a range request covering the rest. 1687552 + 6111519 == 7799071.
        size = 7799071
        r = analyse([
            (IP1, A, 200, 1507328, FF),
            (IP1, A, 200, 2686976, FF),
            (IP2, A, 206, 6111519, FF),
        ], {A: size})
        self.assertEqual(r["cut"], 1)
        self.assertEqual(r["unrecovered"], 0, "resume covered the remainder")

    def test_cut_without_resume_is_the_failure(self):
        # IMG_20260824_141031.jpg: 8% delivered, never retried.
        r = analyse([(IP1, A, 200, 622592, FF)], {A: 7792308})
        self.assertEqual(r["cut"], 1)
        self.assertEqual(r["unrecovered"], 1)
        self.assertEqual(r["unrecovered_assets"], [A])
        self.assertEqual(r["worst_client"], IP1)

    def test_partial_resume_still_counts_as_unrecovered(self):
        r = analyse([(IP1, A, 200, 1000, FF), (IP2, A, 206, 10, FF)], {A: 7792308})
        self.assertEqual(r["unrecovered"], 1)

    def test_unknown_asset_is_skipped_not_guessed(self):
        r = analyse([(IP1, A, 200, 5, FF)], {})
        self.assertEqual((r["assets"], r["cut"], r["unrecovered"]), (0, 0, 0))

    def test_range_only_traffic_is_not_truncation(self):
        # Video seeking produces 206s with no preceding 200. That is ordinary
        # behaviour and must not read as a cut.
        r = analyse([(IP1, A, 206, 1000, FF), (IP1, A, 206, 2000, FF)], {A: 7792308})
        self.assertEqual((r["cut"], r["unrecovered"]), (0, 0))

    def test_assets_are_independent(self):
        r = analyse([
            (IP1, A, 200, 6544473, FF),          # complete
            (IP1, B, 200, 622592, FF),           # left partial
        ], {A: 6544473, B: 7792308})
        self.assertEqual((r["complete"], r["cut"], r["unrecovered"]), (1, 1, 1))
        self.assertEqual(r["unrecovered_assets"], [B])

    def test_retry_that_succeeds_clears_the_asset(self):
        # A client that gives up and re-downloads from scratch is recovered.
        r = analyse([
            (IP1, A, 200, 622592, FF),
            (IP1, A, 200, 6544473, FF),
        ], {A: 6544473})
        self.assertEqual((r["complete"], r["unrecovered"]), (1, 0))

    def test_empty_input(self):
        r = analyse([], {A: 10})
        self.assertEqual((r["assets"], r["complete"], r["cut"], r["unrecovered"]),
                         (0, 0, 0, 0))


class TestClientIsolation(unittest.TestCase):
    """The 2026-08-31 regression: one client's success cleared another's partial."""

    def test_another_clients_success_does_not_clear_a_partial(self):
        # A phone got 8% and stopped. Separately, a diagnostic curl pulled the
        # whole file. The phone is still holding a broken file.
        r = analyse([
            (IP1, A, 200, 622592, FF),
            ("10.0.10.10", A, 200, 7792308, CURL),
        ], {A: 7792308})
        self.assertEqual(r["unrecovered"], 1,
                         "a different client's full download must not clear this")
        self.assertEqual(r["worst_client"], IP1)

    def test_internal_ips_are_dropped_at_parse_time(self):
        internal = [line(ip, A, 200, 7792308) for ip in
                    ("10.0.10.10", "127.0.0.1", "192.168.1.5", "172.16.0.9")]
        self.assertEqual(parse_lines(internal), [])

    def test_same_client_resuming_from_a_new_ip_still_counts_as_recovered(self):
        # The real mobile case: starts on one carrier address, resumes on
        # another. Same user-agent, so it is one client and it did recover.
        r = analyse([
            (IP1, A, 200, 1507328, FF),
            (IP2, A, 206, 6291743, FF),
        ], {A: 7799071})
        self.assertEqual(r["unrecovered"], 0)

    def test_two_distinct_clients_are_tracked_separately(self):
        r = analyse([
            (IP1, A, 200, 100, FF),          # partial
            ("1.2.3.4", A, 200, 7792308, SAFARI),  # complete
        ], {A: 7792308})
        self.assertEqual(r["cut"], 1)
        self.assertEqual(r["unrecovered"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
