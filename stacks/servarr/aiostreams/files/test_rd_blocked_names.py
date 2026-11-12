"""Unit tests for rd_blocked_names: extraction, the safety check, the JSON and the refresh.

Run with: cd infra/stacks/servarr/aiostreams/files && python3 -m unittest test_rd_blocked_names
"""
import json
import os
import tempfile
import unittest

import rd_blocked_names as rbn

# The three shapes Debrid Media Manager's src/utils/deInfringe.ts has used.
# Each fixture is only the lines that matter, copied from the commit named.

# a94652b6, 2026-10-14 (current): two constants, one line each.
TWO_CONSTS = """
 */
const RD_BLOCKED_EXACT_CASE = /WEB-DL|WEB\\.(?:x264|H264)/;
const RD_BLOCKED_ANY_CASE = /(?:web|bd|hd|dvd)rip|bluray\\.x264|p\\.bluray\\.dts|hdtv\\.(?:x264|xvid)/i;
const isBlocked = (name: string) =>
\tRD_BLOCKED_EXACT_CASE.test(name) || RD_BLOCKED_ANY_CASE.test(name);
"""

# e04bb69a, 2026-10-10: one constant, the literal on the next line.
SPLIT_LINE = """
const RD_BLOCKED_NAME =
\t/web-dl|(?:web|bd|hd|dvd)rip|bluray\\.x264|p\\.bluray\\.dts|hdtv\\.(?:x264|xvid)|web\\.(?:x264|h264)/i;

/**
"""

# 8f5e40e7, 2026-10-03: one constant on one line, no flags.
ONE_CONST = """
const RD_BLOCKED_NAME = /WEB-DL|WEB\\.x264|WEB\\.H264|HDTV\\.x264|HDTV\\.XviD/;
"""


class ExtractTests(unittest.TestCase):
    def test_two_constants(self):
        self.assertEqual(
            rbn.extract_patterns(TWO_CONSTS),
            [
                ("RD_BLOCKED_EXACT_CASE", "/WEB-DL|WEB\\.(?:x264|H264)/"),
                (
                    "RD_BLOCKED_ANY_CASE",
                    "/(?:web|bd|hd|dvd)rip|bluray\\.x264|p\\.bluray\\.dts|hdtv\\.(?:x264|xvid)/i",
                ),
            ],
        )

    def test_literal_on_the_next_line(self):
        [(name, pattern)] = rbn.extract_patterns(SPLIT_LINE)
        self.assertEqual(name, "RD_BLOCKED_NAME")
        self.assertTrue(pattern.startswith("/web-dl|"))
        self.assertTrue(pattern.endswith("|web\\.(?:x264|h264)/i"))

    def test_no_flags(self):
        self.assertEqual(
            rbn.extract_patterns(ONE_CONST),
            [("RD_BLOCKED_NAME", "/WEB-DL|WEB\\.x264|WEB\\.H264|HDTV\\.x264|HDTV\\.XviD/")],
        )

    def test_usage_lines_are_not_patterns(self):
        names = [n for n, _ in rbn.extract_patterns(TWO_CONSTS)]
        self.assertEqual(names, ["RD_BLOCKED_EXACT_CASE", "RD_BLOCKED_ANY_CASE"])

    def test_nothing_found(self):
        self.assertEqual(rbn.extract_patterns("export const x = 1;\n"), [])


class ValidateTests(unittest.TestCase):
    def test_every_known_version_passes(self):
        for text in (TWO_CONSTS, SPLIT_LINE, ONE_CONST):
            rbn.validate(rbn.extract_patterns(text))

    def test_current_list_blocks_what_rd_refuses(self):
        compiled = rbn.validate(rbn.extract_patterns(TWO_CONSTS))
        for name in (
            "Movie.2024.1080p.WEB-DL.DDP5.1.H.264-GRP.mkv",
            "Movie.2024.1080p.BluRay.x264-YTS.mp4",
            "Show.S01E01.720p.HDTV.x264-GRP.mkv",
            "Movie 2024 1080p WEBRip x265.mkv",
        ):
            self.assertTrue(any(r.search(name) for r in compiled), name)

    def test_current_list_passes_what_rd_serves(self):
        compiled = rbn.validate(rbn.extract_patterns(TWO_CONSTS))
        for name in (
            "Dune Part Two (2024) [ENG GER][WEBDL-1080p][EAC3 Atmos 5.1].mkv",
            "Movie.2024.1080p.web-dl.x265.mkv",
        ):
            self.assertFalse(any(r.search(name) for r in compiled), name)

    def test_empty_is_rejected(self):
        with self.assertRaises(ValueError):
            rbn.validate([])

    def test_a_pattern_that_hides_ordinary_names_is_rejected(self):
        for bad in ("/mkv/", "/1080p/i", "/./", "/BluRay/i", "/x265/"):
            with self.assertRaises(ValueError, msg=bad):
                rbn.validate([("RD_BLOCKED_NAME", bad)])

    def test_unknown_flags_are_rejected(self):
        with self.assertRaises(ValueError):
            rbn.validate([("RD_BLOCKED_NAME", "/WEB-DL/s")])

    def test_overlong_is_rejected(self):
        with self.assertRaises(ValueError):
            rbn.validate([("RD_BLOCKED_NAME", "/" + "a|" * 200 + "WEB-DL/")])

    def test_too_many_is_rejected(self):
        with self.assertRaises(ValueError):
            rbn.validate([(f"RD_BLOCKED_{i}", f"/WEB-DL{i}/") for i in range(rbn.MAX_PATTERNS + 1)])

    def test_uncompilable_is_rejected(self):
        with self.assertRaises(ValueError):
            rbn.validate([("RD_BLOCKED_NAME", "/WEB-(DL/")])


class RenderTests(unittest.TestCase):
    def test_aiostreams_shape(self):
        items = json.loads(rbn.render(rbn.extract_patterns(TWO_CONSTS)))
        self.assertEqual(
            items[0],
            {
                "name": "Real-Debrid blocked names (RD_BLOCKED_EXACT_CASE)",
                "pattern": "/WEB-DL|WEB\\.(?:x264|H264)/",
            },
        )
        self.assertEqual(len(items), 2)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state_file = os.path.join(self.dir.name, "rd-blocked-names.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_good_source_is_served_and_saved(self):
        state = rbn.State(self.state_file)
        self.assertTrue(state.refresh(lambda: TWO_CONSTS, now=100.0))
        self.assertEqual(len(json.loads(state.body)), 2)
        self.assertEqual(state.last_success, 100.0)
        with open(self.state_file, "rb") as f:
            self.assertEqual(f.read(), state.body)

    def test_bad_source_keeps_the_last_good_list(self):
        state = rbn.State(self.state_file)
        state.refresh(lambda: TWO_CONSTS, now=100.0)
        good = state.body
        self.assertFalse(state.refresh(lambda: "const RD_BLOCKED_NAME = /mkv/;\n", now=200.0))
        self.assertEqual(state.body, good)
        self.assertEqual(state.last_success, 100.0)
        self.assertEqual(state.failures, 1)

    def test_fetch_error_keeps_the_last_good_list(self):
        state = rbn.State(self.state_file)
        state.refresh(lambda: TWO_CONSTS, now=100.0)

        def boom():
            raise OSError("network down")

        self.assertFalse(state.refresh(boom, now=200.0))
        self.assertEqual(len(json.loads(state.body)), 2)
        self.assertEqual(state.failures, 1)

    def test_restart_serves_the_saved_list_before_the_first_fetch(self):
        rbn.State(self.state_file).refresh(lambda: TWO_CONSTS, now=100.0)
        restarted = rbn.State(self.state_file)
        self.assertEqual(len(json.loads(restarted.body)), 2)
        # Not counted as a fresh success: staleness is measured from a real fetch.
        self.assertIsNone(restarted.last_success)

    def test_nothing_saved_and_nothing_fetched_serves_nothing(self):
        state = rbn.State(self.state_file)
        self.assertIsNone(state.body)

    def test_change_time_moves_only_when_the_list_changes(self):
        state = rbn.State(self.state_file)
        state.refresh(lambda: ONE_CONST, now=100.0)
        state.refresh(lambda: ONE_CONST, now=200.0)
        self.assertEqual(state.last_change, 100.0)
        state.refresh(lambda: TWO_CONSTS, now=300.0)
        self.assertEqual(state.last_change, 300.0)

    def test_metrics(self):
        state = rbn.State(self.state_file)
        state.refresh(lambda: TWO_CONSTS, now=100.0)
        text = state.metrics()
        self.assertIn("rd_blocked_names_last_success_timestamp_seconds 100.0\n", text)
        self.assertIn("rd_blocked_names_patterns 2\n", text)
        self.assertIn("rd_blocked_names_refresh_failures_total 0\n", text)


if __name__ == "__main__":
    unittest.main()
