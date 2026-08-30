#!/usr/bin/env python3
"""Tests for download_truncation_detect.

The cases that matter are the ones separating a download that merely got cut
(fine, the client resumed) from one that was left partial (the real failure).
Both look identical in the access log until the sizes are joined in, so these
are built from real log lines captured on 2026-08-30.

Run: python3 download_truncation_detect_test.py
"""

import unittest

from download_truncation_detect import analyse, parse_lines

SUFFIX = (
    '"-" "Mozilla/5.0 (Android 16; Mobile; rv:154.0) Gecko/154.0 Firefox/154.0" '
    '1995191 "immich@kubernetes" "http://10.10.122.155:2283" 9494ms'
)


def line(ip, aid, status, nbytes, proto="HTTP/2.0"):
    return (
        f'{ip} - - [30/Aug/2026:02:23:24 +0000] '
        f'"GET /api/assets/{aid}/original?key=k&edited=true {proto}" '
        f'{status} {nbytes} {SUFFIX}'
    )


A = "ead39fa9-b377-48b8-9cf7-0a0f0ff41dd8"
B = "56495350-c804-4b72-b240-a9df6021e018"
IP1, IP2 = "185.139.138.221", "92.63.205.141"


class TestParse(unittest.TestCase):
    def test_extracts_fields(self):
        got = parse_lines([line(IP1, A, 200, 4239182)])
        self.assertEqual(got, [(IP1, A, 200, 4239182)])

    def test_ignores_unrelated_lines(self):
        noise = [
            '10.0.0.1 - - [30/Aug/2026:02:00:00 +0000] "GET / HTTP/2.0" 200 5 ' + SUFFIX,
            f'10.0.0.1 - - [30/Aug/2026:02:00:00 +0000] "GET /api/assets/{A}/thumbnail HTTP/2.0" 200 5 ' + SUFFIX,
            "not a log line at all",
        ]
        self.assertEqual(parse_lines(noise), [])

    def test_asset_id_is_positional_not_searched(self):
        # A crafted User-Agent must not be able to file metrics under a
        # different asset. The id is only ever read from the request line.
        evil = line(IP1, A, 200, 100).replace(
            "Mozilla/5.0", f"/api/assets/{B}/original"
        )
        self.assertEqual(parse_lines([evil]), [(IP1, A, 200, 100)])

    def test_http3_lines_parse_too(self):
        got = parse_lines([line(IP1, A, 200, 3360762, proto="HTTP/3.0")])
        self.assertEqual(got, [(IP1, A, 200, 3360762)])


class TestAnalyse(unittest.TestCase):
    def test_single_complete_response(self):
        r = analyse([(IP1, A, 200, 6544473)], {A: 6544473})
        self.assertEqual((r["complete"], r["cut"], r["unrecovered"]), (1, 0, 0))

    def test_cut_then_resumed_is_not_a_failure(self):
        # The real IMG_20260824_141031_1.jpg sequence: two short attempts, then
        # a range request covering the rest. 1687552 + 6111519 == 7799071.
        size = 7799071
        r = analyse([
            (IP1, A, 200, 1507328),
            (IP1, A, 200, 2686976),
            (IP2, A, 206, 6111519),
        ], {A: size})
        self.assertEqual(r["cut"], 1)
        self.assertEqual(r["unrecovered"], 0, "resume covered the remainder")

    def test_cut_without_resume_is_the_failure(self):
        # IMG_20260824_141031.jpg: 8% delivered, never retried.
        r = analyse([(IP1, A, 200, 622592)], {A: 7792308})
        self.assertEqual(r["cut"], 1)
        self.assertEqual(r["unrecovered"], 1)
        self.assertEqual(r["unrecovered_assets"], [A])
        self.assertEqual(r["worst_client"], IP1)

    def test_partial_resume_still_counts_as_unrecovered(self):
        r = analyse([(IP1, A, 200, 1000), (IP2, A, 206, 10)], {A: 7792308})
        self.assertEqual(r["unrecovered"], 1)

    def test_unknown_asset_is_skipped_not_guessed(self):
        r = analyse([(IP1, A, 200, 5)], {})
        self.assertEqual((r["assets"], r["cut"], r["unrecovered"]), (0, 0, 0))

    def test_range_only_traffic_is_not_truncation(self):
        # Video seeking produces 206s with no preceding 200. That is ordinary
        # behaviour and must not read as a cut.
        r = analyse([(IP1, A, 206, 1000), (IP1, A, 206, 2000)], {A: 7792308})
        self.assertEqual((r["cut"], r["unrecovered"]), (0, 0))

    def test_assets_are_independent(self):
        r = analyse([
            (IP1, A, 200, 6544473),          # complete
            (IP1, B, 200, 622592),           # left partial
        ], {A: 6544473, B: 7792308})
        self.assertEqual((r["complete"], r["cut"], r["unrecovered"]), (1, 1, 1))
        self.assertEqual(r["unrecovered_assets"], [B])

    def test_retry_that_succeeds_clears_the_asset(self):
        # A client that gives up and re-downloads from scratch is recovered.
        r = analyse([
            (IP1, A, 200, 622592),
            (IP1, A, 200, 6544473),
        ], {A: 6544473})
        self.assertEqual((r["complete"], r["unrecovered"]), (1, 0))

    def test_empty_input(self):
        r = analyse([], {A: 10})
        self.assertEqual((r["assets"], r["complete"], r["cut"], r["unrecovered"]),
                         (0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main(verbosity=2)
