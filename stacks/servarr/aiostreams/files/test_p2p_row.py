"""Tests for p2p_row.py. Run: cd files && python3 -m unittest test_p2p_row"""
import json
import threading
import unittest
import urllib.error
import urllib.request
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import p2p_row

HASH = "9219a5e5a0ef4fb9c40620ddef25cb3502edf091"
TOKEN = "t0ken"


def p2p(**over):
    s = {
        "name": "🚨 P2P · VPN-ONLY 🚨 Comet 1080p",
        "description": "🚨 P2P — VPN ONLY 🚨 🎥 WEB-DL 🎞️ AVC 🏷️ BULTOR\n📦 2.21 GB",
        "infoHash": HASH,
        "fileIdx": 0,
        "sources": [f"dht:{HASH}"],
        "behaviorHints": {
            "bingeGroup": "com.aiostreams|1080p|WEB-DL|BULTOR",
            "videoSize": 2211908157,
            "filename": "Undercover 2011 s06e02 1080p WEB-DL BULGARIAN AVC AAC-BULTOR",
        },
    }
    s.update(over)
    return s


class FakeAIOStreams:
    def __init__(self, streams):
        self.streams = streams
        self.calls = []

    def __call__(self, url, auth=None):
        self.calls.append(url)
        if url.endswith("/api/v1/user"):
            return {"data": {"encryptedPassword": "enc/pw"}}
        return {"streams": self.streams}


def addon(streams, **kw):
    fake = FakeAIOStreams(streams)
    a = p2p_row.Addon(
        base="http://aio", uuid="u", password="p", get_json=fake,
        public_url="https://p2p.example", token=TOKEN, **kw,
    )
    return a, fake


class Rows(unittest.TestCase):
    def test_asks_the_p2p_variant(self):
        a, fake = addon([p2p()])
        a.streams("series", "tt1909015:6:2")
        self.assertIn("/stremio/u/enc%2Fpw/v/p2p/stream/series/tt1909015:6:2.json", fake.calls[-1])

    def test_a_torrent_row_becomes_a_url_row_on_this_host(self):
        a, _ = addon([p2p()])
        (row,) = a.streams("series", "tt1909015:6:2")["streams"]
        self.assertNotIn("infoHash", row)
        self.assertNotIn("sources", row)
        self.assertTrue(row["url"].startswith(f"https://p2p.example/{TOKEN}/play/{HASH}/0/"))
        self.assertTrue(row["url"].endswith(".mkv"))

    def test_the_vpn_warning_gives_way_to_the_sofia_label(self):
        a, _ = addon([p2p()])
        (row,) = a.streams("series", "tt1909015:6:2")["streams"]
        self.assertEqual(row["name"], "☁️ Sofia P2P · Comet 1080p")
        self.assertNotIn("VPN", row["description"])
        self.assertIn("BULTOR", row["description"])

    def test_hints_keep_size_and_name_and_mkv_is_not_web_ready(self):
        a, _ = addon([p2p()])
        (row,) = a.streams("series", "tt1909015:6:2")["streams"]
        hints = row["behaviorHints"]
        self.assertEqual(hints["videoSize"], 2211908157)
        self.assertEqual(hints["filename"], p2p()["behaviorHints"]["filename"])
        self.assertTrue(hints["bingeGroup"].startswith("p2p-sofia|"))
        self.assertTrue(hints["notWebReady"])

    def test_no_file_index_asks_this_host_to_find_the_file(self):
        a, _ = addon([p2p(fileIdx=None)])
        (row,) = a.streams("series", "tt1909015:6:2")["streams"]
        self.assertIn(f"/play/{HASH}/auto/", row["url"])
        self.assertIn("id=tt1909015%3A6%3A2", row["url"])

    def test_rows_without_a_torrent_are_left_out(self):
        a, _ = addon([{"name": "🔍 Removal Reasons", "description": "x", "externalUrl": "https://x"}, p2p()])
        self.assertEqual(len(a.streams("series", "tt1909015:6:2")["streams"]), 1)

    def test_aiostreams_down_gives_no_rows(self):
        def broken(url, auth=None):
            raise urllib.error.URLError("down")
        a = p2p_row.Addon(base="http://aio", uuid="u", password="p", get_json=broken,
                          public_url="https://p2p.example", token=TOKEN)
        self.assertEqual(a.streams("movie", "tt0111161"), {"streams": []})


class PickFile(unittest.TestCase):
    FILES = [
        {"name": "Sample.mkv", "length": 40_000_000},
        {"name": "Show.S06E01.1080p.mkv", "length": 1_900_000_000},
        {"name": "Show.S06E02.1080p.mkv", "length": 1_800_000_000},
        {"name": "Show.S06E02.srt", "length": 50_000},
    ]

    def test_the_named_file_wins(self):
        self.assertEqual(p2p_row.pick_file(self.FILES, "Show.S06E01.1080p", "tt1:6:2"), 1)

    def test_then_the_episode_in_the_name(self):
        self.assertEqual(p2p_row.pick_file(self.FILES, "", "tt1:6:2"), 2)

    def test_then_the_largest_video(self):
        self.assertEqual(p2p_row.pick_file(self.FILES, "", "tt1"), 1)

    def test_no_video_no_file(self):
        self.assertIsNone(p2p_row.pick_file([{"name": "a.srt", "length": 1}], "", "tt1"))


class Route(unittest.TestCase):
    def test_routes(self):
        r = p2p_row.route
        self.assertEqual(r("/healthz", TOKEN), ("health",))
        self.assertEqual(r(f"/{TOKEN}/manifest.json", TOKEN), ("manifest",))
        self.assertEqual(r(f"/{TOKEN}/stream/series/tt1909015%3A6%3A2.json", TOKEN), ("stream", "series", "tt1909015:6:2"))
        self.assertEqual(r(f"/{TOKEN}/play/{HASH}/0/a.mkv", TOKEN), ("play", HASH, "0"))
        self.assertEqual(r(f"/{TOKEN}/play/{HASH}/auto/a.mkv?id=tt1", TOKEN), ("play", HASH, "auto"))

    def test_wrong_token_or_bad_hash_is_refused(self):
        r = p2p_row.route
        self.assertIsNone(r("/nope/manifest.json", TOKEN))
        self.assertIsNone(r(f"/{TOKEN}/play/not-a-hash/0/a.mkv", TOKEN))
        self.assertIsNone(r(f"/{TOKEN}/play/{HASH}/../a.mkv", TOKEN))


class FakeStremio(BaseHTTPRequestHandler):
    """The Sofia streaming server: basic auth, Range on /<hash>/<idx>, create and stats."""
    body = bytes(range(256)) * 400  # 102400 bytes
    auth = "Basic " + b64encode(b"user:pass").decode()
    created = []

    def log_message(self, *a):
        pass

    def _ok(self):
        if self.headers.get("Authorization") != self.auth:
            self.send_response(401)
            self.end_headers()
            return False
        return True

    def do_POST(self):
        if not self._ok():
            return
        self.created.append(self.path)
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def do_GET(self):
        if not self._ok():
            return
        if self.path.endswith("/stats.json"):
            data = json.dumps({"files": [{"name": "x.S06E02.mkv", "length": 9}, {"name": "big.mkv", "length": 99}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)
            return
        start, end = 0, len(self.body) - 1
        rng = self.headers.get("Range")
        if rng:
            a, b = rng.split("=")[1].split("-")
            start, end = int(a), int(b) if b else len(self.body) - 1
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(self.body)}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(self.body[start:end + 1])

    def do_HEAD(self):
        self.do_GET()


class Play(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeStremio)
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        a, _ = addon([])
        a.stremio = f"http://127.0.0.1:{cls.upstream.server_port}"
        a.stremio_auth = ("user", "pass")
        cls.addon = a
        cls.front = ThreadingHTTPServer(("127.0.0.1", 0), p2p_row.make_handler(a, TOKEN))
        threading.Thread(target=cls.front.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.front.server_port}/{TOKEN}"

    @classmethod
    def tearDownClass(cls):
        cls.front.shutdown()
        cls.upstream.shutdown()

    def get(self, path, headers=None, method="GET"):
        req = urllib.request.Request(self.base + path, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    def test_a_range_is_relayed_with_the_servers_login(self):
        status, headers, body = self.get(f"/play/{HASH}/1/a.mkv", {"Range": "bytes=100-199"})
        self.assertEqual(status, 206)
        self.assertEqual(headers["Content-Range"], "bytes 100-199/102400")
        self.assertEqual(body, FakeStremio.body[100:200])

    def test_the_whole_file_streams(self):
        status, headers, body = self.get(f"/play/{HASH}/1/a.mkv")
        self.assertEqual(status, 200)
        self.assertEqual(len(body), 102400)
        self.assertEqual(headers["Accept-Ranges"], "bytes")

    def test_head_answers_without_a_body(self):
        status, headers, body = self.get(f"/play/{HASH}/1/a.mkv", method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")

    def test_a_known_file_still_starts_the_torrent_first(self):
        # Without /create the server has no trackers to find peers with.
        h = "a" * 40
        status, _, _ = self.get(f"/play/{h}/1/a.mkv", {"Range": "bytes=0-9"})
        self.assertEqual(status, 206)
        self.assertIn(f"/{h}/create", FakeStremio.created)

    def test_auto_starts_the_torrent_and_picks_the_episode(self):
        status, _, body = self.get(f"/play/{HASH}/auto/a.mkv?id=tt1%3A6%3A2", {"Range": "bytes=0-9"})
        self.assertEqual(status, 206)
        self.assertEqual(body, FakeStremio.body[0:10])
        self.assertIn(f"/{HASH}/create", FakeStremio.created)
        self.assertEqual(self.addon.resolved[HASH], 0)  # x.S06E02.mkv

    def test_a_wrong_token_is_not_found(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.front.server_port}/nope/play/{HASH}/0/a.mkv")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(cm.exception.code, 404)

    def test_manifest(self):
        status, _, body = self.get("/manifest.json")
        m = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual(m["id"], "me.viktorbarzin.p2p-sofia")
        self.assertEqual(m["resources"], ["stream"])


if __name__ == "__main__":
    unittest.main()
