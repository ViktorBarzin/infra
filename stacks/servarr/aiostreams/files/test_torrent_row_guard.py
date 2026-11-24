"""Tests for torrent_row_guard.py. Run: cd files && python3 -m unittest test_torrent_row_guard"""
import unittest
import urllib.error

import torrent_row_guard as g

AIO = "https://aiostreams.example/stremio/u/p/manifest.json"


def addon(url, resources, id_prefixes=("tt",), types=("movie", "series"), name="x"):
    return {"transportUrl": url, "manifest": {"name": name, "resources": list(resources),
                                              "types": list(types), "idPrefixes": list(id_prefixes)}}


class Fake:
    def __init__(self, addons, streams):
        self.addons, self.streams, self.calls = addons, streams, []

    def __call__(self, url, body=None):
        self.calls.append(url)
        if url.endswith("/addonCollectionGet"):
            if self.addons is None:
                return {"error": {"code": 1, "message": "Session does not exist"}}
            return {"result": {"addons": self.addons}}
        for prefix, streams in self.streams.items():
            if url.startswith(prefix):
                if isinstance(streams, Exception):
                    raise streams
                return {"streams": streams}
        return {"streams": []}


class Checks(unittest.TestCase):
    def test_counts_torrent_rows_per_addon(self):
        fake = Fake([addon(AIO, ["stream"], name="AIOStreams")],
                    {"https://aiostreams.example": [{"infoHash": "a" * 40}, {"url": "https://x"}]})
        result = g.check("key", fake)
        self.assertEqual(result.torrent_rows, {"AIOStreams": 3})  # one per test title
        self.assertTrue(result.ok)

    def test_url_rows_are_fine(self):
        fake = Fake([addon(AIO, ["stream"], name="AIOStreams")], {"https://aiostreams.example": [{"url": "https://x"}]})
        self.assertEqual(g.check("key", fake).torrent_rows, {"AIOStreams": 0})

    def test_only_stream_addons_for_imdb_ids_are_asked(self):
        fake = Fake([
            addon("https://cat.example/manifest.json", ["catalog"], name="Catalog"),
            addon("https://sport.example/manifest.json", [{"name": "stream", "types": ["sport"]}],
                  id_prefixes=("streamed",), types=("sport",), name="Sport"),
            addon("http://127.0.0.1:11470/local-addon/manifest.json", ["meta", "stream"], id_prefixes=("local:", "bt:"), name="Local"),
            addon(AIO, [{"name": "stream", "types": ["movie", "series"], "idPrefixes": ["tt"]}], name="AIOStreams"),
        ], {})
        g.check("key", fake)
        asked = [c for c in fake.calls if "/stream/" in c]
        self.assertTrue(asked)
        self.assertTrue(all(c.startswith("https://aiostreams.example/stremio/u/p/stream/") for c in asked))

    def test_an_addon_that_fails_counts_as_unchecked_not_clean(self):
        fake = Fake([addon(AIO, ["stream"], name="AIOStreams")],
                    {"https://aiostreams.example": urllib.error.URLError("down")})
        result = g.check("key", fake)
        self.assertEqual(result.torrent_rows, {})
        self.assertEqual(result.failed, ["AIOStreams"])
        self.assertTrue(result.ok)

    def test_a_dead_session_is_a_failed_run(self):
        result = g.check("key", Fake(None, {}))
        self.assertFalse(result.ok)
        self.assertIn("Session", result.error)

    def test_metrics_text(self):
        result = g.Result(ok=True, torrent_rows={"AIO Streams": 2}, failed=["Down"])
        text = g.metrics(result, now=100)
        self.assertIn('stremio_torrent_rows{addon="AIO Streams"} 2', text)
        self.assertIn('stremio_torrent_guard_addon_failed{addon="Down"} 1', text)
        self.assertIn("stremio_torrent_guard_success 1", text)
        self.assertIn("stremio_torrent_guard_last_run_timestamp 100", text)


if __name__ == "__main__":
    unittest.main()
