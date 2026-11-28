"""Tests for subtitles.py through the addon's HTTP routes.

Fakes stand in for OpenSubtitles, Real-Debrid, ffmpeg and ffsubsync, so no
test touches the network or runs a tool. Run: python3 -m unittest test_subtitles
"""
import http.client
import json
import os
import tempfile
import threading
import unittest
import urllib.parse
from http.server import ThreadingHTTPServer

import library
import saves
import subtitles

TOKEN = "t0ken"
FILM = "tt5155780"
SUB_URL = "https://subs5.strem.io/en/download/file/1"
ORIGINAL = b"1\n00:00:12,000 --> 00:00:14,000\nHello\n"
SYNCED = b"1\n00:00:02,000 --> 00:00:04,000\nHello\n"


class FakeWeb:
    def __init__(self):
        self.subtitles: list[dict] = [
            {"id": "99", "url": "https://subs5.strem.io/bg/x", "lang": "bul"},
            {"id": "1", "url": SUB_URL, "lang": "eng"},
        ]
        self.downloads: list[list[dict]] = []  # one answer per call; the last one repeats
        self.rd_status = 200
        self.calls: list[str] = []

    def __call__(self, method, url, form=None, headers=None, timeout=60):
        self.calls.append(url)
        if url.startswith(subtitles.OPENSUBTITLES):
            return 200, json.dumps({"subtitles": self.subtitles}).encode()
        if url == SUB_URL:
            return 200, ORIGINAL
        if url.startswith(saves.RealDebrid.BASE + "/downloads"):
            if self.rd_status != 200:
                return self.rd_status, b'{"error": "too_many_requests"}'
            answer = self.downloads.pop(0) if len(self.downloads) > 1 else (self.downloads[0] if self.downloads else [])
            return 200, json.dumps(answer).encode()
        return 404, b""


class FakeTools:
    """ffmpeg writes the sound file; ffsubsync writes SYNCED, or fails."""

    def __init__(self):
        self.argvs: list[list[str]] = []
        self.ffsubsync_code = 0
        self.gate = threading.Event()
        self.gate.set()

    def __call__(self, argv, timeout):
        self.argvs.append(argv)
        if argv[0] == "ffmpeg":
            with open(argv[-1], "wb") as f:
                f.write(b"RIFF")
            return 0, ""
        self.gate.wait(5)
        if self.ffsubsync_code:
            return self.ffsubsync_code, "error"
        with open(argv[argv.index("-o") + 1], "wb") as f:
            f.write(SYNCED)
        return 0, "offset seconds: -10.000\nframerate scale factor: 1.000"

    def inputs(self) -> list[str]:
        return [a[a.index("-i") + 1] for a in self.argvs if a[0] == "ffmpeg"]


class SubtitlesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "media")
        os.makedirs(os.path.join(self.root, FILM))
        self.local = os.path.join(self.root, FILM, "The.Discovery.2017.1080p.mkv")
        with open(self.local, "wb") as f:
            f.write(b"v" * 1234)
        self.web = FakeWeb()
        self.tools = FakeTools()
        self.logs: list[str] = []
        cfg = saves.Config(
            db_path=os.path.join(self.tmp.name, "saves.db"), root=self.root, clips_dir=self.tmp.name,
            accounts={
                "viktor": saves.Account("viktor", "en", "original", None, "https://lib.example"),
                "emo": saves.Account("emo", "bg", "Bulgarian", "sofia", "https://lib-lan.example"),
            },
            aio_base="http://aio", aio_uuid="uuid", aio_password="pw", rd_key="rdkey",
            qb_base="http://qb/api/v2", cinemeta_base="http://cinemeta", token=TOKEN,
        )
        self.saves = saves.Saves(cfg, fetch=self.web, log=self.logs.append)
        self.subs = self.make_subs()
        self.serve(self.subs)

    def make_subs(self):
        return subtitles.Subtitles(os.path.join(self.tmp.name, "subs"), self.root, self.saves.rd, self.web,
                                   frozenset({"viktor"}), run=self.tools, sleep=lambda s: None, log=self.logs.append)

    def serve(self, subs):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), library.make_handler(self.root, TOKEN, "https://lib.example", self.saves, subs))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.saves.close()
        self.tmp.cleanup()

    def get(self, path):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp, body

    def listing(self, size, account="viktor", kind="movie", vid=FILM):
        extra = urllib.parse.urlencode({"filename": "The Discovery (2017) 1080p", "videoSize": size}) if size else ""
        path = f"/{TOKEN}/a/{account}/subtitles/{kind}/{urllib.parse.quote(vid)}" + (f"/{extra}" if extra else "") + ".json"
        resp, body = self.get(path)
        self.assertEqual(resp.status, 200 if account == "viktor" else 404)
        return json.loads(body)["subtitles"] if resp.status == 200 else None

    def track(self, size):
        [row] = self.listing(size)
        self.assertEqual(row["lang"], "eng")
        prefix = f"https://lib.example/{TOKEN}/a/viktor/"
        self.assertTrue(row["url"].startswith(prefix + "sub/"))
        resp, body = self.get("/" + TOKEN + "/a/viktor/" + row["url"][len(prefix):])
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.getheader("Access-Control-Allow-Origin"), "*")
        return body

    def test_only_the_subtitle_accounts_list_the_resource(self):
        _, body = self.get(f"/{TOKEN}/a/viktor/manifest.json")
        self.assertIn("subtitles", json.loads(body)["resources"])
        _, body = self.get(f"/{TOKEN}/a/emo/manifest.json")
        self.assertNotIn("subtitles", json.loads(body)["resources"])
        self.assertIsNone(self.listing(1234, account="emo"))

    def test_a_file_on_our_server_gets_the_synced_subtitle(self):
        self.assertEqual(self.track(1234), SYNCED)
        self.assertEqual(self.tools.inputs(), [self.local])
        ffmpeg = self.tools.argvs[0]
        self.assertEqual(ffmpeg[ffmpeg.index("-t") + 1], "600")  # the first 10 minutes only
        self.assertTrue(any("offset -10.000 s" in m for m in self.logs), self.logs)

    def test_a_real_debrid_file_is_found_by_size_once_the_player_opens_it(self):
        self.web.downloads = [
            [{"filename": "other.mkv", "filesize": 1, "download": "https://rd.example/d/other"}],
            [{"filename": "The.Discovery.mkv", "filesize": 4638564680, "download": "https://rd.example/d/disc"}],
        ]
        self.assertEqual(self.track(4638564680), SYNCED)
        self.assertEqual(self.tools.inputs(), ["https://rd.example/d/disc"])

    def test_the_original_plays_when_no_file_matches(self):
        self.assertEqual(self.track(999), ORIGINAL)
        self.assertEqual(self.tools.argvs, [])
        rd_calls = [c for c in self.web.calls if "/downloads" in c]
        self.assertEqual(len(rd_calls), subtitles.RD_TRIES)

    def test_the_original_plays_when_the_sync_fails(self):
        self.tools.ffsubsync_code = 1
        self.assertEqual(self.track(1234), ORIGINAL)

    def test_the_original_plays_when_the_sync_is_late(self):
        self.tools.gate.clear()
        [row] = self.listing(1234)
        key = row["url"].rsplit("/", 1)[1][:-4]
        self.assertEqual(self.subs.file(key, wait=0.2), ORIGINAL)
        self.tools.gate.set()
        self.subs.jobs[key].done.wait(5)
        self.assertEqual(self.subs.file(key, wait=0), SYNCED)

    def test_a_real_debrid_refusal_stops_further_calls(self):
        self.web.rd_status = 429
        self.assertEqual(self.track(999), ORIGINAL)
        self.assertEqual(self.track(998), ORIGINAL)
        self.assertEqual(len([c for c in self.web.calls if "/downloads" in c]), 1)
        self.assertTrue(any("stopped asking Real-Debrid" in m for m in self.logs))

    def test_a_synced_subtitle_is_kept_for_the_next_play_and_after_a_restart(self):
        self.assertEqual(self.track(1234), SYNCED)
        self.assertEqual(self.track(1234), SYNCED)
        self.server.shutdown()
        self.server.server_close()
        self.serve(self.make_subs())
        self.assertEqual(self.track(1234), SYNCED)
        self.assertEqual(len(self.tools.inputs()), 1)

    def test_no_track_without_a_size_or_without_an_english_subtitle(self):
        self.assertEqual(self.listing(None), [])
        self.web.subtitles = [s for s in self.web.subtitles if s["lang"] != "eng"]
        self.assertEqual(self.listing(1234), [])

    def test_an_episode_is_asked_by_its_episode_id(self):
        self.listing(1234, kind="series", vid="tt1909015:6:2")
        [ask] = [c for c in self.web.calls if c.startswith(subtitles.OPENSUBTITLES)]
        self.assertIn("/subtitles/series/tt1909015:6:2/", ask)
        self.assertIn("videoSize=1234", ask)

    def test_unknown_keys_get_nothing(self):
        for key in ("0123456789abcdef", "../../etc/passwd"):
            resp, _ = self.get(f"/{TOKEN}/a/viktor/sub/{urllib.parse.quote(key, safe='')}.srt")
            self.assertEqual(resp.status, 404, key)


if __name__ == "__main__":
    unittest.main()
