"""Tests for saves.py and the account routes in library.py.

Fakes stand in for AIOStreams, Real-Debrid, qBittorrent and Cinemeta, so no
test touches the network. Run: cd stacks/stremio/files && python3 -m unittest test_saves
"""
import http.client
import io
import json
import os
import re
import tempfile
import threading
import unittest
import urllib.parse
from http.server import ThreadingHTTPServer

import library
import saves

DAY = 86400
T0 = 1_800_000_000.0  # 2027-01-15
TOKEN = "t0ken"
HASH_A = "a" * 40
HASH_B = "b" * 40
HASH_C = "c" * 40
UNDERCOVER = "tt1909015"
INCEPTION = "tt1375666"


def p2p(name, res, size, infohash, filename, audio=None, file_idx=0):
    """A P2P row as AIOStreams sends it (shape of a 2026-11-23 response)."""
    s = {
        "name": f"🚨 P2P · VPN-ONLY 🚨 Comet {res}",
        "infoHash": infohash,
        "fileIdx": file_idx,
        "sources": [f"dht:{infohash}", "tracker:udp://tracker.example:1337/announce"],
        "description": f"🚨 P2P — VPN ONLY 🚨 {name}\n📦 size 👥 12" + (f"\n🌎 {audio}" if audio else ""),
        "behaviorHints": {"bingeGroup": f"com.aiostreams.viren070|{res}|WEB-DL", "videoSize": size, "filename": filename},
    }
    return s


def cached(res, size, url, filename, audio=None):
    """A Real-Debrid cached row (⚡): a link and no info hash."""
    return {
        "name": f"🕵️ [RD⚡] Comet {res}",
        "url": url,
        "description": "🎥 BluRay\n📦 size" + (f"\n🌎 {audio}" if audio else ""),
        "behaviorHints": {"bingeGroup": f"com.aiostreams.viren070|{res}|BluRay", "videoSize": size, "filename": filename},
    }


class FakeAio:
    def __init__(self):
        self.streams: dict[tuple[str | None, str], list] = {}
        self.calls: list[tuple[str | None, str]] = []

    def handle(self, method, path, form, headers):
        if path == "/api/v1/user":
            if headers.get("Authorization") != "Basic dXVpZDpwdw==":  # uuid:pw
                return 401, {}
            return 200, {"data": {"encryptedPassword": "enc/+="}}
        m = re.match(r"^/stremio/uuid/([^/]+)(?:/v/([^/]+))?/stream/(movie|series)/([^/]+)\.json$", path)
        if not m or urllib.parse.unquote(m.group(1)) != "enc/+=":
            return 404, {}
        vid = urllib.parse.unquote(m.group(4))
        self.calls.append((m.group(2), vid))
        return 200, {"streams": self.streams.get((m.group(2), vid), [])}


class FakeRD:
    """Torrents keyed by id. A hash in `refuse` gets 451; in `stalled` it never
    leaves magnet_conversion; otherwise it downloads at `step` percent per info call."""

    def __init__(self):
        self.torrents: dict[str, dict] = {}
        self.refuse: set[str] = set()
        self.stalled: set[str] = set()
        self.files: dict[str, list[tuple[str, int]]] = {}
        self.step = 50
        self.calls: list[tuple[str, str]] = []
        self.fail_with: int | None = None
        self.unrestricted: list[str] = []

    def handle(self, method, path, form, headers):
        self.calls.append((method, path))
        if headers.get("Authorization") != "Bearer rdkey":
            return 401, {"error": "bad_token"}
        if self.fail_with:
            return self.fail_with, {"error": "too_many_requests"}
        if path == "/torrents/addMagnet":
            h = re.search(r"btih:([0-9a-f]{40})", form["magnet"]).group(1)
            if h in self.refuse:
                return 451, {"error": "infringing_file", "error_code": 35}
            tid = f"RD{len(self.torrents) + 1}"
            files = [{"id": i + 1, "path": "/" + n, "bytes": b, "selected": 0} for i, (n, b) in enumerate(self.files[h])]
            self.torrents[tid] = {"id": tid, "hash": h, "status": "waiting_files_selection", "progress": 0, "files": files, "links": []}
            return 201, {"id": tid, "uri": f"https://api.real-debrid.com/rest/1.0/torrents/info/{tid}"}
        m = re.match(r"^/torrents/selectFiles/(\w+)$", path)
        if m:
            t = self.torrents[m.group(1)]
            for f in t["files"]:
                f["selected"] = 1 if str(f["id"]) in form["files"].split(",") else 0
            t["status"] = "magnet_conversion" if t["hash"] in self.stalled else "downloading"
            return 204, None
        m = re.match(r"^/torrents/info/(\w+)$", path)
        if m:
            t = self.torrents[m.group(1)]
            if t["status"] == "downloading":
                t["progress"] = min(100, t["progress"] + self.step)
                if t["progress"] >= 100:
                    t["status"] = "downloaded"
                    t["links"] = [f"https://real-debrid.com/d/{t['id']}{f['id']}" for f in t["files"] if f["selected"]]
            return 200, t
        m = re.match(r"^/torrents/delete/(\w+)$", path)
        if m:
            self.torrents.pop(m.group(1), None)
            return 204, None
        if path == "/unrestrict/link":
            self.unrestricted.append(form["link"])
            return 200, {"download": "https://dl.real-debrid.example/" + form["link"].rsplit("/", 1)[1] + "/file.mkv", "filesize": 1000}
        return 404, {"error": "unknown"}


class FakeQB:
    def __init__(self, root: str):
        self.root = root
        self.torrents: dict[str, dict] = {}
        self.contents: dict[str, list[tuple[str, int]]] = {}
        self.calls: list[tuple[str, dict]] = []

    def adopt(self, infohash, imdb, name, files):
        """A torrent added by hand before the saves database existed."""
        self.torrents[infohash] = {
            "hash": infohash, "infohash_v1": infohash, "category": "stremio", "progress": 1,
            "save_path": f"/downloads/stremio/{imdb}", "content_path": f"/downloads/stremio/{imdb}/{name}",
            "files": [{"index": i, "name": n, "size": s, "progress": 1, "priority": 1} for i, (n, s) in enumerate(files)],
        }

    def complete(self, infohash):
        t = self.torrents[infohash]
        t["progress"] = 1
        imdb = t["save_path"].rsplit("/", 1)[1]
        for f in t["files"]:
            if f["priority"] == 0:
                continue
            f["progress"] = 1
            full = os.path.join(self.root, imdb, f["name"])
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as fh:
                fh.write(b"v" * f["size"])

    def handle(self, method, path, form, headers):
        self.calls.append((path, dict(form or {})))
        query = {}
        if "?" in path:
            path, q = path.split("?", 1)
            query = dict(urllib.parse.parse_qsl(q))
        if path == "/torrents/add":
            h = re.search(r"btih:([0-9a-f]{40})", form["urls"]).group(1)
            if h in self.torrents:
                return 409, "Conflict"
            files = self.contents.get(h, [("file.mkv", 100)])
            self.torrents[h] = {
                "hash": h, "infohash_v1": h, "category": form["category"], "progress": 0,
                "save_path": form["savepath"], "content_path": form["savepath"] + "/" + files[0][0],
                "files": [{"index": i, "name": n, "size": s, "progress": 0, "priority": 1} for i, (n, s) in enumerate(files)],
            }
            return 200, "Ok."
        if path == "/torrents/info":
            rows = list(self.torrents.values())
            if "hashes" in query:
                rows = [t for t in rows if t["hash"] == query["hashes"]]
            if "category" in query:
                rows = [t for t in rows if t["category"] == query["category"]]
            return 200, [{k: v for k, v in t.items() if k != "files"} for t in rows]
        if path == "/torrents/files":
            t = self.torrents.get(query["hash"])
            return (200, t["files"]) if t else (404, "Not Found")
        if path == "/torrents/setShareLimits":
            self.torrents[form["hashes"]]["ratio_limit"] = form["ratioLimit"]
            return 200, ""
        if path == "/torrents/filePrio":
            t = self.torrents[form["hash"]]
            for i in form["id"].split("|"):
                t["files"][int(i)]["priority"] = int(form["priority"])
            return 200, ""
        if path == "/torrents/delete":
            t = self.torrents.pop(form["hashes"])
            if form["deleteFiles"] == "true":
                imdb = t["save_path"].rsplit("/", 1)[1]
                for f in t["files"]:
                    full = os.path.join(self.root, imdb, f["name"])
                    if os.path.exists(full):
                        os.remove(full)
            return 200, ""
        return 404, "Not Found"


class FakeWeb:
    """fetch(method, url, form, headers): routes by base URL to a fake."""

    def __init__(self, root):
        self.aio, self.rd, self.qb = FakeAio(), FakeRD(), FakeQB(root)
        self.metas: dict[tuple[str, str], dict] = {}
        self.down: set[str] = set()

    def __call__(self, method, url, form=None, headers=None, timeout=60):
        headers = headers or {}
        for base, fake in (
            ("http://aio", self.aio),
            ("https://api.real-debrid.com/rest/1.0", self.rd),
            ("http://qb/api/v2", self.qb),
        ):
            if url.startswith(base + "/"):
                if base in self.down:
                    raise OSError("connection refused")
                status, body = fake.handle(method, url[len(base):], form, headers)
                return status, (body if isinstance(body, str) else json.dumps(body) if body is not None else "").encode()
        m = re.match(r"^http://cinemeta/meta/(movie|series)/(tt\d+)\.json$", url)
        if m:
            meta = self.metas.get((m.group(1), m.group(2)))
            return (200, json.dumps({"meta": meta}).encode()) if meta else (404, b"{}")
        raise AssertionError(f"unexpected URL {url}")


class FakeUpstream:
    """What urllib.request.urlopen returns, for the Real-Debrid proxy."""

    def __init__(self, data: bytes, rng: str | None):
        start, end = 0, len(data) - 1
        self.status = 200
        self.headers = {"Content-Type": "video/x-matroska", "Accept-Ranges": "bytes"}
        if rng:
            a, _, b = rng[6:].partition("-")
            start, end = int(a), int(b) if b else len(data) - 1
            self.status = 206
            self.headers["Content-Range"] = f"bytes {start}-{end}/{len(data)}"
        self.headers["Content-Length"] = str(end - start + 1)
        self.body = io.BytesIO(data[start : end + 1])

    def read(self, n=-1):
        return self.body.read(n)

    def close(self):
        pass


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "media")
        os.makedirs(self.root)
        self.clips = os.path.join(self.tmp.name, "clips")
        os.makedirs(self.clips)
        for kind in saves.CLIPS:
            for lang in ("en", "bg"):
                with open(os.path.join(self.clips, f"{kind}-{lang}.mp4"), "wb") as f:
                    f.write(f"clip {kind} {lang}".encode())
        self.web = FakeWeb(self.root)
        self.now = T0
        self.opened: list[tuple[str, str | None]] = []
        self.upstream_bytes = bytes(range(250)) * 4  # 1000 bytes
        self.logs: list[str] = []
        self.web.metas[("series", UNDERCOVER)] = {"name": "Undercover", "videos": []}
        self.web.metas[("movie", INCEPTION)] = {"name": "Inception", "year": 2010}
        self.saves = self.make()

    def make(self, **overrides):
        cfg = saves.Config(
            db_path=os.path.join(self.tmp.name, "saves.db"),
            root=self.root,
            clips_dir=self.clips,
            accounts={
                "viktor": saves.Account("viktor", "en", "original", None, "https://lib.example"),
                "emo": saves.Account("emo", "bg", "Bulgarian", "sofia", "https://lib-lan.example"),
            },
            aio_base="http://aio",
            aio_uuid="uuid",
            aio_password="pw",
            rd_key="rdkey",
            qb_base="http://qb/api/v2",
            cinemeta_base="http://cinemeta",
            token=TOKEN,
            **overrides,
        )
        return saves.Saves(cfg, fetch=self.web, opener=self.open, clock=lambda: self.now, log=self.logs.append)

    def open(self, url, rng):
        self.opened.append((url, rng))
        return FakeUpstream(self.upstream_bytes, rng)

    def tearDown(self):
        self.saves.close()
        self.tmp.cleanup()

    def labels(self, account, kind, vid):
        return [r["title"].split("\n")[0] for r in self.saves.rows(account, kind, vid)]

    def row(self, account, kind, vid, label):
        for r in self.saves.rows(account, kind, vid):
            if r["title"].split("\n")[0] == label:
                return r
        raise AssertionError(f"no row {label!r} in {self.labels(account, kind, vid)}")

    def tap(self, account, url):
        """What a player gets for a row's URL: ('clip', kind) or ('play', ...)."""
        path = urllib.parse.urlsplit(url).path
        _, token, _, acct, action, vid = path.split("/", 5)
        self.assertEqual((token, acct), (TOKEN, account))
        return self.saves.tap(account, action, urllib.parse.unquote(vid))

    def episode(self, n, res="1080p", size=1000, infohash=None, audio="Bulgarian", group="BULTOR"):
        name = f"Undercover 2011 s06e{n:02d} {res} WEB-DL BULGARIAN AVC AAC-{group}.mp4"
        return p2p(name, res, size, infohash or f"{n:040x}", name, audio)


class PickTests(unittest.TestCase):
    GB = 1_000_000_000

    def test_largest_1080p_up_to_6_gb_first(self):
        small = p2p("s", "1080p", 2 * self.GB, HASH_A, "Inception.2010.1080p.small.mkv")
        mid = cached("1080p", 5 * self.GB, "https://x/mid", "Inception.2010.1080p.mid.mkv")
        remux = cached("1080p", 30 * self.GB, "https://x/remux", "Inception.2010.1080p.REMUX.mkv")
        uhd = cached("2160p", 4 * self.GB, "https://x/uhd", "Inception.2010.2160p.mkv")
        self.assertIs(saves.choose([small, mid, remux, uhd], "original"), mid)

    def test_then_2160p_720p_480p(self):
        remux = cached("1080p", 30 * self.GB, "https://x/remux", "Inception.2010.1080p.REMUX.mkv")
        uhd = cached("2160p", 5 * self.GB, "https://x/uhd", "Inception.2010.2160p.mkv")
        hd = cached("720p", 1 * self.GB, "https://x/hd", "Inception.2010.720p.mkv")
        self.assertIs(saves.choose([remux, uhd, hd], "original"), uhd)
        self.assertIs(saves.choose([remux, hd], "original"), hd)
        self.assertIs(saves.choose([remux], "original"), remux)  # nothing fits: the smallest

    def test_uncached_rows_and_rows_of_unknown_size_are_left_out(self):
        uncached = cached("1080p", 2 * self.GB, "https://x/u", "Inception.2010.1080p.mkv")
        uncached["name"] = "🕵️ [RD⏳] Comet 1080p"
        unknown = p2p("u", "1080p", 0, HASH_B, "Inception.2010.1080p.mkv")
        external = {"name": "x", "externalUrl": "https://x", "behaviorHints": {"videoSize": 5}}
        self.assertEqual(saves.candidates([uncached, unknown, external], "Inception", INCEPTION), [])

    def test_files_named_after_another_title_or_episode_are_left_out(self):
        moreau = cached("720p", self.GB, "https://x/m", "The Island of Dr. Moreau (1996) 720p.mkv")
        right = cached("720p", self.GB, "https://x/r", "Inception.2010.720p.mkv")
        self.assertEqual(saves.candidates([moreau, right], "Inception", INCEPTION), [right])
        e2 = p2p("e", "1080p", self.GB, HASH_A, "Undercover 2011 s06e02 1080p.mp4")
        e3 = p2p("e", "1080p", self.GB, HASH_B, "Undercover 2011 s06e03 1080p.mp4")
        self.assertEqual(saves.candidates([e2, e3], "Undercover", f"{UNDERCOVER}:6:3"), [e3])

    def test_emo_gets_bulgarian_audio_first_even_at_a_lower_resolution(self):
        english = cached("1080p", 4 * self.GB, "https://x/en", "Shrek.2.2004.1080p.mkv", audio="English")
        bulgarian = cached("720p", 2 * self.GB, "https://x/bg", "Shrek.2.2004.720p.BG.mkv", audio="Bulgarian | English")
        self.assertIs(saves.choose([english, bulgarian], "Bulgarian"), bulgarian)
        self.assertIs(saves.choose([english, bulgarian], "original"), english)

    def test_emo_without_a_bulgarian_copy_gets_the_usual_pick(self):
        english = cached("1080p", 4 * self.GB, "https://x/en", "Shrek.2.2004.1080p.mkv", audio="English")
        self.assertIs(saves.choose([english], "Bulgarian"), english)


class SaveFlowTests(Base):
    def test_save_then_status_then_play_on_the_same_url(self):
        vid = f"{UNDERCOVER}:6:8"
        self.web.aio.streams[(None, vid)] = [self.episode(8, infohash=HASH_A)]
        self.web.rd.files[HASH_A] = [(self.episode(8)["behaviorHints"]["filename"], 1000)]
        self.web.rd.step = 45
        save = self.row("viktor", "series", vid, "Save this episode")
        self.assertIn("Save the season from here", self.labels("viktor", "series", vid))
        url = save["url"]
        self.assertEqual(url, f"https://lib.example/{TOKEN}/a/viktor/v/{vid}")
        self.assertEqual(self.tap("viktor", url), ("clip", "saved"))
        self.saves.run_cycle()  # search, add to Real-Debrid, select files
        self.saves.run_cycle()  # 45%
        status = self.saves.rows("viktor", "series", vid)[0]
        self.assertEqual(status["url"], url)
        self.assertEqual(status["title"].split("\n")[0], "Saving 45%")
        self.assertIn("Remove save", self.labels("viktor", "series", vid))
        self.now += 300
        self.assertEqual(self.tap("viktor", url), ("clip", "saving"))
        self.saves.run_cycle()  # 90%
        self.saves.run_cycle()  # downloaded
        saved = self.saves.rows("viktor", "series", vid)[0]
        self.assertEqual((saved["url"], saved["title"].split("\n")[0]), (url, "Saved"))
        play = self.tap("viktor", url)
        self.assertEqual(play[0], "rd")

    def test_the_first_minutes_keep_the_saved_clip_while_the_player_reads_it(self):
        film = cached("1080p", 1000, "https://aiostreams-direct.viktorbarzin.me/api/v1/proxy/x/Inception.mkv", "Inception.2010.1080p.mkv")
        self.web.aio.streams[(None, INCEPTION)] = [film]
        url = self.row("viktor", "movie", INCEPTION, "Save this film")["url"]
        self.assertEqual(self.tap("viktor", url), ("clip", "saved"))
        self.saves.run_cycle()  # a cached copy is ready at once
        self.assertEqual(self.tap("viktor", url), ("clip", "saved"))
        self.now += 180
        self.assertEqual(self.tap("viktor", url)[0], "rd")

    def test_a_cached_copy_plays_through_aiostreams_inside_the_cluster(self):
        film = cached("1080p", 1000, "https://aiostreams-direct.viktorbarzin.me/api/v1/proxy/abc/Inception.mkv", "Inception.2010.1080p.mkv")
        self.web.aio.streams[(None, INCEPTION)] = [film]
        self.saves.tap("viktor", "v", INCEPTION)
        self.saves.run_cycle()
        self.now += 180
        _, copy = self.saves.tap("viktor", "v", INCEPTION)
        self.assertEqual(self.saves.upstream_url(copy), "http://aio/api/v1/proxy/abc/Inception.mkv")
        self.assertEqual(self.web.rd.calls, [])

    def test_emo_searches_his_variant_and_uses_his_own_host(self):
        vid = f"{UNDERCOVER}:6:8"
        url = self.row("emo", "series", vid, "Запази този епизод")["url"]
        self.assertTrue(url.startswith(f"https://lib-lan.example/{TOKEN}/a/emo/v/"))
        self.saves.tap("emo", "v", vid)
        self.saves.run_cycle()
        self.assertEqual(self.web.aio.calls, [("sofia", vid)])

    def test_bulgarian_labels_for_emo(self):
        vid = f"{UNDERCOVER}:6:8"
        self.assertEqual(self.labels("emo", "series", vid), ["Запази този епизод", "Запази сезона оттук"])
        self.assertEqual(self.labels("emo", "movie", INCEPTION), ["Запази този филм"])
        self.saves.tap("emo", "v", vid)
        self.assertEqual(self.labels("emo", "series", vid), ["Запазва се", "Премахни"])
        self.assertEqual(self.saves.tap("emo", "v", vid), ("clip", "saved"))
        self.assertEqual(self.saves.clip_path("emo", "saved"), os.path.join(self.clips, "saved-bg.mp4"))
        self.assertEqual(saves.manifest(self.saves.accounts["emo"])["catalogs"][0]["name"], "Запазени")

    def test_torrent_rows_come_from_the_torrent_variant(self):
        # Since 2026-11-24 Viktor's main AIOStreams config returns no torrent
        # rows; its "p2p" variant does. A save asks both and picks from all.
        self.saves.close()
        self.saves = self.make(torrent_variant="p2p")
        vid = f"{UNDERCOVER}:6:8"
        ep = self.episode(8, infohash=HASH_A)
        self.web.aio.streams[("p2p", vid)] = [ep]
        self.web.rd.files[HASH_A] = [(ep["behaviorHints"]["filename"], 1000)]
        self.saves.tap("viktor", "v", vid)
        self.saves.run_cycle()
        self.assertIn((None, vid), self.web.aio.calls)
        self.assertIn(("p2p", vid), self.web.aio.calls)
        self.assertIn(("POST", "/torrents/addMagnet"), self.web.rd.calls)

    def test_rd_refusal_falls_back_to_qbittorrent(self):
        vid = f"{UNDERCOVER}:6:8"
        ep = self.episode(8, infohash=HASH_A)
        name = ep["behaviorHints"]["filename"]
        self.web.aio.streams[(None, vid)] = [ep]
        self.web.rd.refuse.add(HASH_A)
        self.web.qb.contents[HASH_A] = [(name, 1000)]
        self.saves.tap("viktor", "v", vid)
        self.saves.run_cycle()
        add = [f for p, f in self.web.qb.calls if p == "/torrents/add"]
        self.assertEqual(len(add), 1)
        self.assertEqual((add[0]["category"], add[0]["savepath"]), ("stremio", f"/downloads/stremio/{UNDERCOVER}"))
        self.assertIn(f"btih:{HASH_A}", add[0]["urls"])
        self.saves.run_cycle()
        self.assertEqual(self.web.qb.torrents[HASH_A]["ratio_limit"], "1")
        self.web.qb.complete(HASH_A)
        self.saves.run_cycle()
        self.now += 180
        play = self.saves.tap("viktor", "v", vid)
        self.assertEqual(play[0], "server")
        self.assertEqual(play[1], os.path.join(self.root, UNDERCOVER, name))

    def test_rd_without_progress_for_two_hours_falls_back(self):
        vid = f"{UNDERCOVER}:6:8"
        self.web.aio.streams[(None, vid)] = [self.episode(8, infohash=HASH_A)]
        self.web.rd.files[HASH_A] = [("Undercover 2011 s06e08 1080p.mp4", 1000)]
        self.web.rd.stalled.add(HASH_A)
        self.saves.tap("viktor", "v", vid)
        self.saves.run_cycle()
        self.now += 3600
        self.saves.run_cycle()
        self.assertEqual(len(self.web.rd.torrents), 1)
        self.now += 3601
        self.saves.run_cycle()
        self.assertEqual(self.web.rd.torrents, {})  # deleted on Real-Debrid
        self.assertIn(HASH_A, self.web.qb.torrents)

    def test_a_429_stops_the_cycle(self):
        self.web.aio.streams[(None, INCEPTION)] = [p2p("i", "1080p", 1000, HASH_A, "Inception.2010.1080p.mkv")]
        self.web.aio.streams[(None, f"{UNDERCOVER}:6:8")] = [self.episode(8, infohash=HASH_B)]
        self.web.rd.fail_with = 429
        self.saves.tap("viktor", "v", INCEPTION)
        self.saves.tap("viktor", "v", f"{UNDERCOVER}:6:8")
        self.saves.run_cycle()
        self.assertEqual(len(self.web.rd.calls), 1)
        self.assertTrue(any("429" in line for line in self.logs))
        self.assertEqual(self.web.qb.torrents, {})

    def test_remove_and_try_again_are_their_own_urls(self):
        vid = f"{UNDERCOVER}:6:8"
        self.saves.tap("viktor", "v", vid)
        remove = self.row("viktor", "series", vid, "Remove save")["url"]
        self.assertTrue(remove.endswith(f"/a/viktor/remove/{vid}"))
        self.assertEqual(self.tap("viktor", remove), ("clip", "removed"))
        self.assertEqual(self.labels("viktor", "series", vid), ["Save this episode", "Save the season from here"])


class FollowTests(Base):
    def test_unaired_episodes_wait_and_their_14_days_start_on_the_air_date(self):
        self.web.metas[("series", UNDERCOVER)]["videos"] = [
            {"season": 6, "episode": 1, "released": "2027-01-10T20:00:00.000Z"},
            {"season": 6, "episode": 2, "released": "2027-01-25T20:00:00.000Z"},
        ]
        e1 = f"{UNDERCOVER}:6:1"
        e2 = f"{UNDERCOVER}:6:2"
        self.web.aio.streams[(None, e1)] = [cached("1080p", 1000, "https://x/e1", "Undercover.S06E01.1080p.mkv")]
        follow = self.row("viktor", "series", e1, "Save the season from here")["url"]
        self.assertEqual(self.tap("viktor", follow), ("clip", "season"))
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", e1)[0], "Saved")
        self.assertEqual(self.labels("viktor", "series", e2)[0], "Saving when it comes out")
        self.assertNotIn((None, e2), self.web.aio.calls)
        air = saves.parse_time("2027-01-25T20:00:00.000Z")
        self.now = air + 60
        self.saves.run_cycle()
        self.assertIn((None, e2), self.web.aio.calls)
        self.assertEqual(self.labels("viktor", "series", e2)[0], "Saving")
        self.now = air + 14 * DAY - 60
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", e2)[0], "Saving")
        self.now = air + 14 * DAY + 60
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", e2), ["No copy found", "Try again", "Remove save"])
        retry = self.row("viktor", "series", e2, "Try again")["url"]
        self.web.aio.streams[(None, e2)] = [cached("1080p", 1000, "https://x/e2", "Undercover.S06E02.1080p.mkv")]
        self.assertEqual(self.tap("viktor", retry), ("clip", "saving"))
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", e2)[0], "Saved")

    def test_episode_lists_are_fetched_at_most_every_6_hours(self):
        # The episode list comes from a public addon (TMDB on elfhosted); a
        # follow must not ask it on every 5-minute cycle.
        asked = []
        web = self.web

        def counting(method, url, form=None, headers=None, timeout=60):
            if "/meta/" in url:
                asked.append(url)
            return web(method, url, form=form, headers=headers, timeout=timeout)

        self.saves.fetch = counting
        self.web.metas[("series", UNDERCOVER)]["videos"] = [
            {"season": 6, "episode": 1, "released": "2027-01-10T20:00:00.000Z"},
        ]
        self.saves.tap("viktor", "follow", f"{UNDERCOVER}:6:1")
        for _ in range(10):
            self.saves.run_cycle()
            self.now += 5 * 60
        self.assertEqual(len(asked), 1)
        self.now += 6 * 3600
        self.saves.run_cycle()
        self.assertEqual(len(asked), 2)

    def test_episodes_cinemeta_does_not_list_are_looked_for_one_after_another(self):
        # Cinemeta lists no season 6 of Undercover (seen 2026-11-23), so the
        # follow asks AIOStreams for the next episode number every 6 hours.
        e3 = f"{UNDERCOVER}:6:3"
        self.saves.tap("viktor", "follow", f"{UNDERCOVER}:6:1")
        self.web.aio.streams[(None, f"{UNDERCOVER}:6:1")] = [cached("1080p", 1000, "https://x/1", "Undercover.S06E01.1080p.mkv")]
        self.web.aio.streams[(None, f"{UNDERCOVER}:6:2")] = [cached("1080p", 1000, "https://x/2", "Undercover.S06E02.1080p.mkv")]
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", f"{UNDERCOVER}:6:2")[0], "Saved")
        self.assertEqual(self.labels("viktor", "series", e3)[0], "Saving when it comes out")
        self.now += 7 * DAY
        self.web.aio.streams[(None, e3)] = [cached("1080p", 1000, "https://x/3", "Undercover.S06E03.1080p.mkv")]
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", e3)[0], "Saved")
        self.now += 15 * DAY  # no episode 4 for 14 days: the season has ended
        self.saves.run_cycle()
        self.saves.run_cycle()
        self.assertEqual(self.labels("viktor", "series", f"{UNDERCOVER}:6:4")[0], "Save this episode")
        calls = len(self.web.aio.calls)
        self.now += 7 * DAY
        self.saves.run_cycle()
        self.assertEqual(len(self.web.aio.calls), calls)


class WatchedAndCleanupTests(Base):
    def server_copy(self, n, size=1000, accounts=("viktor",), infohash=None):
        vid = f"{UNDERCOVER}:6:{n}"
        ep = self.episode(n, size=size, infohash=infohash)
        h = ep["infoHash"]
        self.web.aio.streams[(None, vid)] = [ep]
        self.web.aio.streams[("sofia", vid)] = [ep]
        self.web.rd.refuse.add(h)
        self.web.qb.contents[h] = [(ep["behaviorHints"]["filename"], size)]
        for a in accounts:
            self.saves.tap(a, "v", vid)
        self.saves.run_cycle()
        self.web.qb.complete(h)
        self.saves.run_cycle()
        self.now += 180
        play = self.saves.tap(accounts[0], "v", vid)
        self.assertEqual(play[0], "server")
        return vid, play[2], h

    def test_watched_means_bytes_past_90_percent_through_the_account_url(self):
        vid, copy_id, _ = self.server_copy(8)
        self.saves.delivered("viktor", copy_id, 0, 500, 1000)
        self.assertFalse(self.saves.watched("viktor", copy_id))
        self.saves.delivered("viktor", copy_id, 985, 1000, 1000)  # the player reading the index at the end
        self.assertFalse(self.saves.watched("viktor", copy_id))
        self.saves.delivered("viktor", copy_id, 500, 920, 1000)
        self.assertTrue(self.saves.watched("viktor", copy_id))

    def test_watched_is_recorded_from_a_real_request(self):
        vid, copy_id, _ = self.server_copy(8)
        server = ThreadingHTTPServer(("127.0.0.1", 0), library.make_handler(self.root, TOKEN, "https://lib.example", self.saves))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            conn = http.client.HTTPConnection("127.0.0.1", server.server_port)
            conn.request("GET", f"/{TOKEN}/a/viktor/v/{vid}", headers={"Range": "bytes=800-"})
            resp = conn.getresponse()
            self.assertEqual((resp.status, len(resp.read())), (206, 200))
            conn.close()
        finally:
            server.shutdown()
            server.server_close()
        self.assertTrue(self.saves.watched("viktor", copy_id))
        self.assertFalse(self.saves.watched("emo", copy_id))

    def test_a_copy_goes_7_days_after_every_saver_watched_it(self):
        vid, copy_id, h = self.server_copy(8, accounts=("viktor", "emo"))
        self.assertEqual(self.saves.tap("emo", "v", vid)[2], copy_id)  # one copy, two savers
        self.saves.delivered("viktor", copy_id, 0, 1000, 1000)
        self.now += 8 * DAY
        self.saves.run_cycle()
        self.assertIn(h, self.web.qb.torrents)  # emo has not watched it
        self.saves.delivered("emo", copy_id, 0, 1000, 1000)
        self.now += 7 * DAY - 60
        self.saves.run_cycle()
        self.assertIn(h, self.web.qb.torrents)
        self.now += 120
        self.saves.run_cycle()
        self.assertNotIn(h, self.web.qb.torrents)
        delete = [f for p, f in self.web.qb.calls if p == "/torrents/delete"]
        self.assertEqual(delete, [{"hashes": h, "deleteFiles": "true"}])
        self.assertEqual(self.labels("viktor", "series", vid)[0], "Save this episode")

    def test_a_torrent_outside_the_stremio_category_is_never_deleted(self):
        # qBittorrent also holds MAM farming and the arr apps; cleanup may only
        # remove what this addon put in its own category.
        vid, copy_id, h = self.server_copy(8)
        self.web.qb.torrents[h]["category"] = "mam-farming"
        self.saves.delivered("viktor", copy_id, 0, 1000, 1000)
        self.now += 8 * DAY
        self.saves.run_cycle()
        self.assertIn(h, self.web.qb.torrents)
        self.assertNotIn("/torrents/delete", [p for p, _ in self.web.qb.calls])

    def test_the_300_gb_cap_deletes_the_oldest_unwatched_copies_first(self):
        old, _, h_old = self.server_copy(1, size=400)
        self.now += DAY
        mid, _, h_mid = self.server_copy(2, size=400)
        self.now += DAY
        self.saves.close()
        self.saves = self.make(cap_bytes=1000)
        new, _, h_new = self.server_copy(3, size=400)
        self.assertNotIn(h_old, self.web.qb.torrents)
        self.assertIn(h_mid, self.web.qb.torrents)
        self.assertIn(h_new, self.web.qb.torrents)

    def test_watched_copies_go_before_unwatched_ones_under_the_cap(self):
        old, _, h_old = self.server_copy(1, size=400)
        self.now += DAY
        mid, mid_copy, h_mid = self.server_copy(2, size=400)
        self.saves.delivered("viktor", mid_copy, 0, 400, 400)
        self.now += DAY
        self.saves.close()
        self.saves = self.make(cap_bytes=1000)
        self.server_copy(3, size=400)
        self.assertIn(h_old, self.web.qb.torrents)
        self.assertNotIn(h_mid, self.web.qb.torrents)

    def test_real_debrid_copies_are_never_deleted(self):
        film = cached("1080p", 1000, "https://x/inception", "Inception.2010.1080p.mkv")
        self.web.aio.streams[(None, INCEPTION)] = [film]
        self.saves.tap("viktor", "v", INCEPTION)
        self.saves.run_cycle()
        self.now += 180
        _, copy = self.saves.tap("viktor", "v", INCEPTION)
        self.saves.delivered("viktor", copy["id"], 0, 1000, 1000)
        self.now += 60 * DAY
        self.saves.close()
        self.saves = self.make(cap_bytes=1)
        self.saves.run_cycle()
        self.assertEqual(self.saves.tap("viktor", "v", INCEPTION)[0], "rd")
        self.assertFalse(any(m == "DELETE" for m, _ in self.web.rd.calls))

    def test_remove_on_a_real_debrid_copy_only_removes_the_save(self):
        vid = f"{UNDERCOVER}:6:8"
        self.web.aio.streams[(None, vid)] = [self.episode(8, infohash=HASH_A)]
        self.web.aio.streams[("sofia", vid)] = [self.episode(8, infohash=HASH_A)]
        self.web.rd.files[HASH_A] = [("Undercover 2011 s06e08 1080p.mp4", 1000)]
        self.web.rd.step = 100
        self.saves.tap("viktor", "v", vid)
        self.saves.tap("emo", "v", vid)
        for _ in range(3):
            self.saves.run_cycle()
        self.now += 180
        self.assertEqual(self.saves.tap("viktor", "v", vid)[0], "rd")
        self.assertEqual(self.saves.tap("viktor", "remove", vid), ("clip", "removed"))
        self.assertEqual(self.labels("viktor", "series", vid)[0], "Save this episode")
        self.assertEqual(self.saves.tap("emo", "v", vid)[0], "rd")
        self.assertEqual(self.saves.tap("emo", "remove", vid), ("clip", "removed"))
        self.assertFalse(any(m == "DELETE" for m, _ in self.web.rd.calls))
        self.assertEqual(len(self.web.rd.torrents), 1)
        self.assertEqual(self.saves.count_copies(), 1)  # kept for the next saver of this release

    def test_remove_by_the_last_saver_deletes_a_server_copy(self):
        vid, _, h = self.server_copy(8, accounts=("viktor", "emo"))
        self.saves.tap("viktor", "remove", vid)
        self.assertIn(h, self.web.qb.torrents)
        self.saves.tap("emo", "remove", vid)
        self.assertNotIn(h, self.web.qb.torrents)

    def test_savers_wanting_different_releases_get_different_copies(self):
        vid = f"{UNDERCOVER}:6:8"
        original = self.episode(8, infohash=HASH_A, audio=None, group="ORIG")
        dub = self.episode(8, infohash=HASH_B, size=900, audio="Bulgarian", group="BGAUDIO")
        self.web.aio.streams[(None, vid)] = [original, dub]
        self.web.aio.streams[("sofia", vid)] = [original, dub]
        self.web.rd.refuse.update({HASH_A, HASH_B})
        self.web.qb.contents[HASH_A] = [(original["behaviorHints"]["filename"], 1000)]
        self.web.qb.contents[HASH_B] = [(dub["behaviorHints"]["filename"], 900)]
        self.saves.tap("viktor", "v", vid)
        self.saves.tap("emo", "v", vid)
        self.saves.run_cycle()
        self.assertEqual(sorted(self.web.qb.torrents), [HASH_A, HASH_B])


class AdoptionTests(Base):
    def put(self, n):
        name = f"Undercover 2011 s06e{n:02d} 1080p WEB-DL BULGARIAN AVC AAC-BULTOR"
        folder = os.path.join(self.root, UNDERCOVER, name)
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name + ".mp4"), "wb") as f:
            f.write(b"u" * 100)
        with open(os.path.join(folder, name + ".nfo"), "wb") as f:
            f.write(b"nfo")
        self.web.qb.adopt(f"{n:040x}", UNDERCOVER, name, [(f"{name}/{name}.mp4", 100), (f"{name}/{name}.nfo", 3)])

    def test_files_on_the_server_become_copies_and_the_seed_follow_takes_them(self):
        for n in (1, 2):
            self.put(n)
        self.saves.close()
        self.saves = self.make(seed_follows=("viktor:tt1909015:6:1",))
        self.saves.run_cycle()
        for n in (1, 2):
            vid = f"{UNDERCOVER}:6:{n}"
            self.assertEqual(self.labels("viktor", "series", vid)[0], "Saved")
            self.now += 180
            play = self.saves.tap("viktor", "v", vid)
            self.assertEqual(play[0], "server")
        self.assertEqual(self.labels("viktor", "series", f"{UNDERCOVER}:6:3")[0], "Saving when it comes out")
        self.assertEqual([c for c in self.web.aio.calls if c[1].endswith((":6:1", ":6:2"))], [])
        # A restart adopts nothing twice and does not apply the seed again.
        self.saves.tap("viktor", "remove", f"{UNDERCOVER}:6:1")
        self.saves.close()
        self.saves = self.make(seed_follows=("viktor:tt1909015:6:1",))
        self.saves.run_cycle()
        self.assertEqual(self.saves.count_copies(), 1)  # E1's copy went with its last saver
        self.assertEqual(self.labels("viktor", "series", f"{UNDERCOVER}:6:1")[0], "Save this episode")

    def test_an_adopted_release_is_shared_with_a_saver_who_picks_it(self):
        self.put(1)
        self.saves.run_cycle()
        vid = f"{UNDERCOVER}:6:1"
        name = "Undercover 2011 s06e01 1080p WEB-DL BULGARIAN AVC AAC-BULTOR"
        self.web.aio.streams[("sofia", vid)] = [p2p(name, "1080p", 100, f"{1:040x}", name + ".mp4", "Bulgarian")]
        self.saves.tap("emo", "v", vid)
        self.saves.run_cycle()
        self.assertEqual(self.saves.count_copies(), 1)
        self.assertEqual(self.web.rd.calls, [])


class RoutesTests(Base):
    def setUp(self):
        super().setUp()
        handler = library.make_handler(self.root, TOKEN, "https://lib.example", self.saves)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        super().tearDown()

    def get(self, path, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        conn.request("GET", path, headers=headers or {})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp, body

    def test_each_account_has_its_manifest_and_the_old_one_is_viktor(self):
        for path, name in ((f"/{TOKEN}/a/viktor/manifest.json", "Our server"), (f"/{TOKEN}/a/emo/manifest.json", "Нашият сървър"), (f"/{TOKEN}/manifest.json", "Our server")):
            resp, body = self.get(path)
            self.assertEqual(resp.status, 200, path)
            m = json.loads(body)
            self.assertEqual(m["name"], name)
            self.assertIn("catalog", m["resources"])
        resp, body = self.get(f"/{TOKEN}/stream/series/{UNDERCOVER}:6:8.json")
        self.assertEqual(json.loads(body)["streams"][0]["url"], f"https://lib.example/{TOKEN}/a/viktor/v/{UNDERCOVER}:6:8")

    def test_a_tap_plays_a_clip_with_ranges(self):
        resp, body = self.get(f"/{TOKEN}/a/viktor/v/{INCEPTION}")
        self.assertEqual((resp.status, body), (200, b"clip saved en"))
        self.assertEqual(resp.getheader("Content-Type"), "video/mp4")
        resp, body = self.get(f"/{TOKEN}/a/viktor/v/{INCEPTION}", {"Range": "bytes=0-3"})
        self.assertEqual((resp.status, body), (206, b"clip"))

    def test_a_real_debrid_copy_is_proxied_with_ranges(self):
        vid = f"{UNDERCOVER}:6:8"
        self.web.aio.streams[(None, vid)] = [self.episode(8, infohash=HASH_A)]
        self.web.rd.files[HASH_A] = [("Undercover 2011 s06e08 1080p.mp4", 1000)]
        self.web.rd.step = 100
        self.saves.tap("viktor", "v", vid)
        for _ in range(3):
            self.saves.run_cycle()
        self.now += 180
        resp, body = self.get(f"/{TOKEN}/a/viktor/v/{vid}", {"Range": "bytes=10-19"})
        self.assertEqual((resp.status, body), (206, self.upstream_bytes[10:20]))
        self.assertEqual(resp.getheader("Content-Range"), "bytes 10-19/1000")
        self.get(f"/{TOKEN}/a/viktor/v/{vid}", {"Range": "bytes=20-29"})
        self.assertEqual(len(self.web.rd.unrestricted), 1)  # the link is kept for hours
        self.assertEqual(self.opened[-1], ("https://dl.real-debrid.example/RD11/file.mkv", "bytes=20-29"))

    def test_the_saved_catalog_lists_titles_newest_first(self):
        self.saves.tap("viktor", "v", INCEPTION)
        self.now += 60
        self.saves.tap("viktor", "v", f"{UNDERCOVER}:6:8")
        self.saves.run_cycle()
        resp, body = self.get(f"/{TOKEN}/a/viktor/catalog/movie/saved.json")
        metas = json.loads(body)["metas"]
        self.assertEqual([(m["id"], m["type"], m["name"]) for m in metas], [(UNDERCOVER, "series", "Undercover"), (INCEPTION, "movie", "Inception")])
        resp, body = self.get(f"/{TOKEN}/a/emo/catalog/movie/saved.json")
        self.assertEqual(json.loads(body)["metas"], [])

    def test_wrong_tokens_accounts_and_paths_get_nothing(self):
        for path in (
            "/nope/a/viktor/manifest.json",
            f"/{TOKEN}/a/mallory/manifest.json",
            f"/{TOKEN}/a/viktor/v/..%2F..%2Fetc%2Fpasswd",
            f"/{TOKEN}/a/viktor/v/tt1:2",
            f"/{TOKEN}/a/viktor/delete/{INCEPTION}",
            f"/{TOKEN}/a/viktor/file/{UNDERCOVER}/..%2F..%2Fsaves.db",
            f"/{TOKEN}/a/emo/stream/series/x.json",
        ):
            resp, _ = self.get(path)
            self.assertEqual(resp.status, 404, path)


if __name__ == "__main__":
    unittest.main()
