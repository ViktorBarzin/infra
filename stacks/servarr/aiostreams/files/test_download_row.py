"""Unit tests for download_row: which file the row offers, its text, and routing.

Run with: cd infra/stacks/servarr/aiostreams/files && python3 -m unittest test_download_row
"""
import json
import tempfile
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


UHD_MID = stream("🕵️ [RD⚡] Torrentio 2160p", "2160p", int(14.6 * GB), url="https://x/uhdmid", filename="uhdmid.mkv")
SD_720_BIG = stream("🕵️ [RD⚡] Torrentio 720p", "720p", int(3.5 * GB), url="https://x/sd720big", filename="sd720big.mkv")
SD_480 = stream("🕵️ [RD⚡] Torrentio 480p", "480p", int(0.7 * GB), url="https://x/sd480", filename="sd480.avi")


def urls(rows):
    return [r["externalUrl"] for r in rows]


class OptionsTests(unittest.TestCase):
    def test_recommended_first_then_a_ladder_by_quality(self):
        streams = [REMUX_1080, SMALL_1080, MID_1080, SD_720, SD_720_BIG, UHD_SMALL, UHD_MID, UHD_REMUX]
        self.assertEqual(
            urls(dr.options(streams)),
            [
                "https://x/mid1080",  # recommended: largest 1080p up to 6 GB
                "https://x/sd720",  # 720p smallest
                "https://x/sd720big",  # 720p largest up to 15 GB
                "https://x/small1080",  # 1080p smallest
                "https://x/uhd",  # 4K smallest
                "https://x/uhdmid",  # 4K largest up to 15 GB
            ],
        )

    def test_only_the_smallest_when_nothing_else_fits_under_15_gb(self):
        self.assertEqual(urls(dr.options([REMUX_1080, UHD_REMUX])), ["https://x/remux1080", "https://x/uhdremux"])

    def test_no_second_row_when_the_bigger_file_is_barely_bigger(self):
        twin = stream("🕵️ [RD⚡] Comet 1080p", "1080p", int(1.8 * GB), url="https://x/twin")
        self.assertEqual(urls(dr.options([SMALL_1080, twin, SD_720])), ["https://x/twin", "https://x/sd720", "https://x/small1080"])

    def test_480p_only_without_720p(self):
        self.assertEqual(urls(dr.options([SMALL_1080, SD_480])), ["https://x/small1080", "https://x/sd480"])
        self.assertNotIn("https://x/sd480", urls(dr.options([SMALL_1080, SD_720, SD_480])))

    def test_english_only_file_fills_a_slot_before_a_dual_audio_one(self):
        dual = stream("🕵️ [RD⚡] Torrentio 720p", "720p", int(0.9 * GB), url="https://x/dual720")
        dual["description"] = "🌎 Hindi | English"
        self.assertNotIn("https://x/dual720", urls(dr.options([SMALL_1080, dual, SD_720])))

    def test_nothing_to_offer(self):
        self.assertEqual(dr.options([P2P, EXTERNAL_ROW]), [])

    def test_row_text(self):
        first, *rest = dr.options([MID_1080, SMALL_1080, UHD_SMALL])
        self.assertEqual(first["name"], "⬇ Recommended")
        self.assertTrue(first["description"].startswith("1080p · 4.2 GB"))
        self.assertEqual([r["name"] for r in rest], ["⬇ 1080p", "⬇ 4K"])
        self.assertTrue(rest[1]["description"].startswith("4K · 5.5 GB"))
        self.assertIn("uhd.mkv", rest[1]["description"])
        self.assertNotIn("url", first)


class TitleTests(unittest.TestCase):
    def test_matches(self):
        self.assertTrue(dr.title_matches("Paddington 2", "Paddington.2.2017.1080p.BluRay.mkv"))
        self.assertTrue(dr.title_matches("Breaking Bad", "Breaking Bad s01e01-Pilot-1080p.x265.mkv"))
        self.assertTrue(dr.title_matches("Mission: Impossible", "Mission.Impossible.1996.720p.mkv"))
        self.assertTrue(dr.title_matches("Amélie", "Amelie.2001.1080p.mkv"))

    def test_another_film(self):
        self.assertFalse(dr.title_matches("Inception", "The Island of Dr. Moreau (1996) Director's Cut.mkv"))
        self.assertFalse(dr.title_matches("Paddington 2", "Paddington.2014.1080p.mkv"))

    def test_word_boundaries(self):
        self.assertFalse(dr.title_matches("Up", "Upgrade.2018.1080p.mkv"))

    def test_no_filename_is_kept(self):
        self.assertTrue(dr.title_matches("Inception", ""))

    def test_options_drop_other_films(self):
        moreau = stream("🕵️ [RD⚡] Torrentio 720p", "720p", int(0.7 * GB), url="https://x/moreau", filename="The Island of Dr. Moreau (1996).mkv")
        own = stream("🕵️ [RD⚡] Torrentio 720p", "720p", int(1.0 * GB), url="https://x/own", filename="Inception.2010.720p.mkv")
        self.assertEqual(urls(dr.options([moreau, own], title="Inception")), ["https://x/own"])
        self.assertEqual(urls(dr.options([moreau], title="Inception")), [])


class RowTests(unittest.TestCase):
    def test_row(self):
        row = dr.row(SMALL_1080)
        self.assertEqual(row["name"], "⬇ 1080p")
        self.assertEqual(row["externalUrl"], "https://x/small1080")
        self.assertNotIn("url", row)
        self.assertTrue(row["description"].startswith("1080p · 1.6 GB"))
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

    def __init__(self, streams=None, fail_first_with=None, error=None, title=None):
        self.title = title
        self.meta_calls = []
        self.streams = streams or []
        self.fail_first_with = fail_first_with
        self.error = error
        self.password_fetches = 0
        self.stream_calls = []

    def get_json(self, url, auth=None):
        if "/meta/" in url:
            self.meta_calls.append(url)
            if self.error:
                raise self.error
            meta = {"name": self.title, "year": getattr(self, "year", None)}
            return {"meta": meta} if self.title else {}
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
    def make(self, upstream, variant=None):
        return dr.Addon(
            base="http://localhost:3000", uuid="u-1", password="pw", get_json=upstream.get_json,
            variant=variant, cinemeta="http://cinemeta",
        )

    def test_title_comes_from_the_show_not_the_episode(self):
        up = FakeUpstream([SMALL_1080])
        self.make(up).streams("series", "tt0903747:1:1")
        self.assertEqual(up.meta_calls, ["http://cinemeta/meta/series/tt0903747.json"])

    def test_drops_files_of_other_titles(self):
        own = stream("🕵️ [RD⚡] Torrentio 720p", "720p", GB, url="https://x/own", filename="Inception.2010.720p.mkv")
        up = FakeUpstream([SMALL_1080, own], title="Inception")  # SMALL_1080 is a Paddington file
        # Only the Inception file, saved under its clean name.
        self.assertEqual(urls(self.make(up).streams("movie", "tt1375666")["streams"]), ["https://x/Inception%20720p.mkv"])

    def test_asks_the_named_variant(self):
        up = FakeUpstream([SMALL_1080])
        self.make(up, variant="download").streams("series", "tt0903747:1:1")
        self.assertEqual(
            up.stream_calls,
            ["http://localhost:3000/stremio/u-1/enc%2F1/v/download/stream/series/tt0903747:1:1.json"],
        )

    def test_rows(self):
        up = FakeUpstream([REMUX_1080, SMALL_1080])
        result = self.make(up).streams("movie", "tt4468740")
        # The 23 GB remux is over the 15 GB ladder cap, so one row.
        self.assertEqual(urls(result["streams"]), ["https://x/small1080"])
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


class CleanNameTests(unittest.TestCase):
    def test_movie(self):
        self.assertEqual(dr.clean_name("Inception", "2010", "tt1375666", 720, "Inception.2010.720p.x265.mkv"), "Inception (2010) 720p.mkv")

    def test_episode(self):
        self.assertEqual(
            dr.clean_name("Breaking Bad", "2008", "tt0903747:1:1", 1080, "Breaking.Bad.S01E01.mp4"),
            "Breaking Bad S01E01 1080p.mp4",
        )

    def test_4k_and_unsafe_characters(self):
        self.assertEqual(
            dr.clean_name("Mission: Impossible / Fallout?", "2018", "tt4912910", 2160, "x.mkv"),
            "Mission - Impossible - Fallout (2018) 4K.mkv",
        )

    def test_unknown_extension_and_year(self):
        self.assertEqual(dr.clean_name("Inception", None, "tt1375666", None, "file"), "Inception.mkv")

    def test_named_link_replaces_the_last_segment(self):
        self.assertEqual(
            dr.named_link("https://x/api/v1/proxy/abc/Release.Name.mkv", "Inception (2010) 720p.mkv"),
            "https://x/api/v1/proxy/abc/Inception%20%282010%29%20720p.mkv",
        )

    def test_rows_use_the_clean_name(self):
        rows = dr.options([SMALL_1080], name_for=lambda s: "Paddington 2 (2017) 1080p.mkv")
        self.assertTrue(rows[0]["externalUrl"].endswith("/Paddington%202%20%282017%29%201080p.mkv"))
        self.assertIn("Paddington 2 BONE.mkv", rows[0]["description"])  # where it comes from


INVENTORY = {
    "dir": "/sdcard/Download",
    "files": [
        {"name": "Inception (2010) 720p.mkv", "size": 1_039_639_206, "mtime": 200},
        {"name": "Inception (2010) 720p (1).mkv", "size": 1_039_639_206, "mtime": 300},
        {"name": "Breaking Bad S01E01 1080p.mkv", "size": 3_800_000_000, "mtime": 100},
        {"name": "holiday.mp4", "size": 5_000_000, "mtime": 400},
    ],
}


class LibraryTests(unittest.TestCase):
    def make(self, path=None):
        lib = dr.Library(path)
        lib.remember("Inception (2010) 720p.mkv", "movie", "tt1375666", "Inception")
        lib.remember("Breaking Bad S01E01 1080p.mkv", "series", "tt0903747:1:1", "Breaking Bad")
        lib.set_inventory(INVENTORY, now=1000)
        return lib

    def test_catalog_lists_titles_on_the_tablet_newest_first(self):
        lib = self.make()
        self.assertEqual(
            lib.catalog("movie"),
            [{
                "id": "tt1375666", "type": "movie", "name": "Inception",
                "poster": "https://images.metahub.space/poster/medium/tt1375666/img",
            }],
        )
        self.assertEqual([m["id"] for m in lib.catalog("series")], ["tt0903747"])

    def test_files_it_did_not_name_are_ignored(self):
        self.assertNotIn("holiday", json.dumps(self.make().catalog("movie")))

    def test_play_rows_for_the_title(self):
        rows = self.make().play_rows("tt1375666")
        self.assertEqual(len(rows), 2)  # the file and Chrome's " (1)" copy
        self.assertEqual(rows[0]["name"], "▶ On the tablet")
        self.assertEqual(rows[0]["externalUrl"], "vlc://file:///sdcard/Download/Inception%20%282010%29%20720p%20%281%29.mkv")
        self.assertIn("1.0 GB", rows[0]["description"])
        self.assertEqual(self.make().play_rows("tt0903747:1:2"), [])
        self.assertEqual(len(self.make().play_rows("tt0903747:1:1")), 1)

    def test_a_deleted_file_drops_out(self):
        lib = self.make()
        lib.set_inventory({"dir": "/sdcard/Download", "files": []}, now=2000)
        self.assertEqual(lib.catalog("movie"), [])
        self.assertEqual(lib.play_rows("tt1375666"), [])

    def test_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d)
            again = dr.Library(d)
            self.assertEqual([m["id"] for m in again.catalog("movie")], ["tt1375666"])

    def test_rejects_a_bad_inventory(self):
        lib = self.make()
        for bad in ({}, {"dir": "/x", "files": "nope"}, {"dir": "/x", "files": [{"name": 3}]}):
            with self.assertRaises(ValueError):
                lib.set_inventory(bad)
        self.assertEqual(len(lib.catalog("movie")), 1)


class MoreRouteTests(unittest.TestCase):
    def test_catalog(self):
        self.assertEqual(dr.route("/t0ken/catalog/movie/downloaded.json", "t0ken"), ("catalog", "movie"))
        self.assertIsNone(dr.route("/t0ken/catalog/movie/other.json", "t0ken"))

    def test_inventory(self):
        self.assertEqual(dr.route("/t0ken/inventory", "t0ken"), ("inventory",))
        self.assertIsNone(dr.route("/nope/inventory", "t0ken"))

    def test_manifest_lists_the_catalogs(self):
        self.assertIn("catalog", dr.MANIFEST["resources"])
        self.assertEqual({c["id"] for c in dr.MANIFEST["catalogs"]}, {"downloaded"})


class StreamsWithLibraryTests(unittest.TestCase):
    def test_play_row_first_and_names_remembered(self):
        lib = dr.Library(None)
        own = stream("🕵️ [RD⚡] Torrentio 720p", "720p", GB, url="https://x/api/v1/proxy/e/Inception.2010.720p.mkv", filename="Inception.2010.720p.mkv")
        up = FakeUpstream([own], title="Inception")
        up.year = "2010"
        addon = dr.Addon(
            base="http://localhost:3000", uuid="u-1", password="pw", get_json=up.get_json,
            cinemeta="http://cinemeta", library=lib,
        )
        first = addon.streams("movie", "tt1375666")["streams"]
        self.assertTrue(first[0]["externalUrl"].endswith("/Inception%20%282010%29%20720p.mkv"))
        # Saved before clean names existed: the release name maps back too.
        self.assertEqual(lib.names["Inception.2010.720p.mkv"]["id"], "tt1375666")
        lib.set_inventory({"dir": "/sdcard/Download", "files": [{"name": "Inception (2010) 720p.mkv", "size": GB, "mtime": 1}]})
        second = addon.streams("movie", "tt1375666")["streams"]
        self.assertEqual(second[0]["name"], "▶ On the tablet")
        self.assertEqual(second[1]["name"], "⬇ Recommended")
