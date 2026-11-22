"""Unit tests for download_row: which file the row offers, its text, and routing.

Run with: cd infra/stacks/servarr/aiostreams/files && python3 -m unittest test_download_row
"""
import unittest
import urllib.error

import download_row as dr

GB = 1_000_000_000


def stream(name, res, size, url="https://x/api/v1/proxy/abc/file.mkv", filename="file.mkv"):
    """One stream the way AIOStreams sends it (shape copied from a 2026-11-22 response)."""
    s = {
        "name": name,
        "description": "🎥 BluRay\n📦 size",
        "behaviorHints": {
            "bingeGroup": f"com.aiostreams.viren070|{res}|BluRay",
            "filename": filename,
        },
    }
    if size is not None:
        s["behaviorHints"]["videoSize"] = size
    if url is not None:
        s["url"] = url
    return s


REMUX_1080 = stream("🕵️ [RD⚡] Comet 1080p", "1080p", 23 * GB, url="https://x/remux1080", filename="remux1080.mkv")
SMALL_1080 = stream("🕵️ [RD⚡] Torrentio 1080p", "1080p", int(1.6 * GB), url="https://x/small1080", filename="Paddington 2 BONE.mkv")
MID_1080 = stream("🕵️ [RD⚡] Torrentio 1080p", "1080p", int(4.2 * GB), url="https://x/mid1080", filename="mid1080.mkv")
SD_720 = stream("🕵️ [RD⚡] Torrentio 720p", "720p", int(2.0 * GB), url="https://x/sd720", filename="sd720.mkv")
UHD_SMALL = stream("🕵️ [RD⚡] Torrentio 2160p", "2160p", int(5.5 * GB), url="https://x/uhd", filename="uhd.mkv")
UHD_REMUX = stream("🕵️ [RD⚡] Comet 2160p", "2160p", 39 * GB, url="https://x/uhdremux", filename="uhdremux.mkv")
# AIOStreams' own per-stream download row: no url, only externalUrl.
EXTERNAL_ROW = {"name": "🕵️ [RD⚡]  ", "externalUrl": "https://x/small1080"}
P2P = stream("🚨 P2P · VPN-ONLY 🚨 Comet 1080p", "1080p", 3 * GB, url=None)
UNCACHED = stream("🕵️ [RD⏳] Comet 1080p", "1080p", 3 * GB, url="https://x/uncached")


class ResolutionTests(unittest.TestCase):
    def test_from_binge_group(self):
        self.assertEqual(dr.resolution_of(SMALL_1080), 1080)

    def test_from_name_when_no_binge_group(self):
        s = {"name": "[RD⚡] Comet 2160p", "url": "u", "behaviorHints": {"videoSize": GB}}
        self.assertEqual(dr.resolution_of(s), 2160)

    def test_unknown(self):
        self.assertIsNone(dr.resolution_of({"name": "x", "behaviorHints": {}}))


class ChooseTests(unittest.TestCase):
    def test_largest_1080p_that_fits(self):
        self.assertIs(dr.choose([REMUX_1080, SMALL_1080, MID_1080, SD_720, UHD_SMALL]), MID_1080)

    def test_1080p_beats_a_4k_file_that_fits(self):
        self.assertIs(dr.choose([UHD_SMALL, SMALL_1080]), SMALL_1080)

    def test_4k_when_no_1080p_fits(self):
        self.assertIs(dr.choose([REMUX_1080, UHD_SMALL, SD_720]), UHD_SMALL)

    def test_720p_when_nothing_larger_fits(self):
        self.assertIs(dr.choose([REMUX_1080, UHD_REMUX, SD_720]), SD_720)

    def test_smallest_file_when_nothing_fits(self):
        self.assertIs(dr.choose([UHD_REMUX, REMUX_1080]), REMUX_1080)

    def test_skips_rows_without_a_direct_link_and_uncached_files(self):
        self.assertIs(dr.choose([EXTERNAL_ROW, P2P, UNCACHED, SD_720]), SD_720)

    def test_skips_files_of_unknown_size(self):
        unknown = stream("🕵️ [RD⚡] Comet 1080p", "1080p", None, url="https://x/unknown")
        self.assertIs(dr.choose([unknown, SD_720]), SD_720)

    def test_english_only_audio_beats_a_bigger_dual_audio_file(self):
        dual = stream("🕵️ [RD⚡] Torrentio 1080p", "1080p", 4 * GB, url="https://x/dual")
        dual["description"] = "🎥 BluRay\n🌎 Hindi | English📝 English\n📁 dual.mkv"
        english = stream("🕵️ [RD⚡] Comet 1080p", "1080p", 2 * GB, url="https://x/eng")
        english["description"] = "🎥 BluRay\n🌎 English📝 English\n📁 eng.mkv"
        self.assertIs(dr.choose([dual, english]), english)

    def test_no_language_line_counts_as_english(self):
        dual = stream("🕵️ [RD⚡] Torrentio 1080p", "1080p", 4 * GB, url="https://x/dual")
        dual["description"] = "🌎 Hindi | English"
        self.assertIs(dr.choose([dual, SMALL_1080]), SMALL_1080)

    def test_dual_audio_when_it_is_the_only_file_that_fits(self):
        dual = stream("🕵️ [RD⚡] Torrentio 1080p", "1080p", 4 * GB, url="https://x/dual")
        dual["description"] = "🌎 Hindi | English"
        self.assertIs(dr.choose([dual, REMUX_1080]), dual)

    def test_nothing_to_offer(self):
        self.assertIsNone(dr.choose([]))
        self.assertIsNone(dr.choose([P2P, EXTERNAL_ROW, UNCACHED]))


class RowTests(unittest.TestCase):
    def test_row(self):
        row = dr.row(SMALL_1080)
        self.assertEqual(row["name"], "⬇ Download")
        self.assertEqual(row["externalUrl"], "https://x/small1080")
        self.assertNotIn("url", row)
        self.assertIn("1080p · 1.6 GB", row["description"])
        self.assertIn("Paddington 2 BONE.mkv", row["description"])

    def test_row_with_unknown_resolution(self):
        s = {"name": "x", "url": "https://x/y", "behaviorHints": {"videoSize": 700_000_000, "filename": "y.avi"}}
        self.assertIn("0.7 GB", dr.row(s)["description"])


class RouteTests(unittest.TestCase):
    TOKEN = "t0ken"

    def test_manifest(self):
        self.assertEqual(dr.route("/t0ken/manifest.json", self.TOKEN), ("manifest",))

    def test_movie(self):
        self.assertEqual(dr.route("/t0ken/stream/movie/tt4468740.json", self.TOKEN), ("stream", "movie", "tt4468740"))

    def test_episode_id_url_encoded(self):
        self.assertEqual(
            dr.route("/t0ken/stream/series/tt0903747%3A1%3A1.json", self.TOKEN),
            ("stream", "series", "tt0903747:1:1"),
        )

    def test_wrong_token(self):
        self.assertIsNone(dr.route("/nope/manifest.json", self.TOKEN))
        self.assertIsNone(dr.route("/manifest.json", self.TOKEN))

    def test_bad_id_or_type(self):
        self.assertIsNone(dr.route("/t0ken/stream/movie/..%2Fetc.json", self.TOKEN))
        self.assertIsNone(dr.route("/t0ken/stream/channel/tt1.json", self.TOKEN))

    def test_health(self):
        self.assertEqual(dr.route("/healthz", self.TOKEN), ("health",))
        self.assertEqual(dr.route("/", self.TOKEN), ("health",))


class FakeUpstream:
    """Stands in for AIOStreams' user API and stream endpoint."""

    def __init__(self, streams=None, fail_first_with=None, error=None):
        self.streams = streams or []
        self.fail_first_with = fail_first_with
        self.error = error
        self.password_fetches = 0
        self.stream_calls = []

    def get_json(self, url, auth=None):
        if url.endswith("/api/v1/user"):
            self.password_fetches += 1
            return {"data": {"encryptedPassword": f"enc/{self.password_fetches}"}}
        self.stream_calls.append(url)
        if self.error:
            raise self.error
        if self.fail_first_with and len(self.stream_calls) == 1:
            raise urllib.error.HTTPError(url, self.fail_first_with, "denied", {}, None)
        return {"streams": self.streams}


class StreamsTests(unittest.TestCase):
    def make(self, upstream):
        return dr.Addon(base="http://localhost:3000", uuid="u-1", password="pw", get_json=upstream.get_json)

    def test_one_row(self):
        up = FakeUpstream([REMUX_1080, SMALL_1080])
        result = self.make(up).streams("movie", "tt4468740")
        self.assertEqual([r["externalUrl"] for r in result["streams"]], ["https://x/small1080"])
        self.assertEqual(up.stream_calls, ["http://localhost:3000/stremio/u-1/enc%2F1/stream/movie/tt4468740.json"])

    def test_password_is_fetched_once(self):
        up = FakeUpstream([SMALL_1080])
        addon = self.make(up)
        addon.streams("movie", "tt1")
        addon.streams("movie", "tt2")
        self.assertEqual(up.password_fetches, 1)

    def test_refetches_password_once_when_refused(self):
        up = FakeUpstream([SMALL_1080], fail_first_with=401)
        result = self.make(up).streams("movie", "tt1")
        self.assertEqual(up.password_fetches, 2)
        self.assertEqual(len(result["streams"]), 1)

    def test_upstream_down_gives_no_row(self):
        up = FakeUpstream(error=urllib.error.URLError("refused"))
        self.assertEqual(self.make(up).streams("movie", "tt1"), {"streams": []})

    def test_no_candidate_gives_no_row(self):
        up = FakeUpstream([P2P])
        self.assertEqual(self.make(up).streams("movie", "tt1"), {"streams": []})


if __name__ == "__main__":
    unittest.main()
