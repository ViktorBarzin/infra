"""Tests for library.py. Run: cd stacks/stremio/files && python3 -m unittest test_library"""
import http.client
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

import library

TOKEN = "t0ken"


class LibraryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        show = os.path.join(root, "tt1909015")
        os.makedirs(show)
        self.e2 = "Undercover 2011 s06e02 1080p WEB-DL BULGARIAN AVC AAC-BULTOR.mp4"
        with open(os.path.join(show, self.e2), "wb") as f:
            f.write(bytes(range(256)) * 4)  # 1024 bytes
        # qBittorrent names a file it is still downloading "<name>.!qB".
        with open(os.path.join(show, "Undercover 2011 s06e03 1080p.mp4.!qB"), "wb") as f:
            f.write(b"x")
        sub = os.path.join(show, "Undercover 2011 s06e04 1080p")  # a torrent with a folder
        os.makedirs(sub)
        with open(os.path.join(sub, "Pod.Prikritie.S06E04.mkv"), "wb") as f:
            f.write(b"y" * 10)
        with open(os.path.join(sub, "sample.txt"), "wb") as f:
            f.write(b"not video")
        film = os.path.join(root, "tt1375666")
        os.makedirs(film)
        with open(os.path.join(film, "Inception.2010.1080p.mkv"), "wb") as f:
            f.write(b"z" * 5)
        handler = library.make_handler(root, TOKEN, "https://lib.example")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def get(self, path: str, headers: dict | None = None, method: str = "GET"):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        conn.request(method, path, headers=headers or {})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return resp, body

    def streams(self, kind: str, media_id: str) -> list:
        resp, body = self.get(f"/{TOKEN}/stream/{kind}/{media_id}.json")
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.getheader("Access-Control-Allow-Origin"), "*")
        return json.loads(body)["streams"]

    def test_manifest_is_a_stream_addon_for_imdb_ids(self) -> None:
        resp, body = self.get(f"/{TOKEN}/manifest.json")
        manifest = json.loads(body)
        self.assertEqual(resp.status, 200)
        self.assertEqual(manifest["resources"], ["stream"])
        self.assertEqual(manifest["idPrefixes"], ["tt"])
        self.assertEqual(sorted(manifest["types"]), ["movie", "series"])

    def test_the_root_answers_for_the_uptime_monitor(self) -> None:
        for path in ("/", "/healthz"):
            resp, _ = self.get(path)
            self.assertEqual(resp.status, 200, path)

    def test_a_wrong_token_gets_nothing(self) -> None:
        for path in ("/nope/manifest.json", f"/nope/file/tt1909015/{library.quote(self.e2)}", "/manifest.json"):
            resp, _ = self.get(path)
            self.assertEqual(resp.status, 404, path)

    def test_an_episode_gets_a_row_with_a_direct_link(self) -> None:
        [row] = self.streams("series", "tt1909015:6:2")
        self.assertEqual(row["url"], "https://lib.example/t0ken/file/tt1909015/" + library.quote(self.e2))
        self.assertEqual(row["behaviorHints"]["filename"], self.e2)
        self.assertEqual(row["behaviorHints"]["videoSize"], 1024)
        self.assertIn("1080p", row["name"])

    def test_an_episode_inside_a_torrent_folder_is_found(self) -> None:
        [row] = self.streams("series", "tt1909015:6:4")
        self.assertTrue(row["url"].endswith("/file/tt1909015/" + library.quote("Undercover 2011 s06e04 1080p/Pod.Prikritie.S06E04.mkv")))

    def test_an_unfinished_download_has_no_row(self) -> None:
        self.assertEqual(self.streams("series", "tt1909015:6:3"), [])

    def test_other_episodes_and_unknown_titles_have_no_rows(self) -> None:
        self.assertEqual(self.streams("series", "tt1909015:6:1"), [])
        self.assertEqual(self.streams("series", "tt1909015:5:2"), [])
        self.assertEqual(self.streams("series", "tt0000001:1:1"), [])

    def test_a_film_gets_its_video_files(self) -> None:
        [row] = self.streams("movie", "tt1375666")
        self.assertTrue(row["url"].endswith("/file/tt1375666/Inception.2010.1080p.mkv"))

    def test_a_file_is_served_whole(self) -> None:
        resp, body = self.get(f"/{TOKEN}/file/tt1909015/{library.quote(self.e2)}")
        self.assertEqual(resp.status, 200)
        self.assertEqual(len(body), 1024)
        self.assertEqual(resp.getheader("Content-Type"), "video/mp4")
        self.assertEqual(resp.getheader("Accept-Ranges"), "bytes")

    def test_a_range_is_served_partially(self) -> None:
        path = f"/{TOKEN}/file/tt1909015/{library.quote(self.e2)}"
        resp, body = self.get(path, {"Range": "bytes=10-19"})
        self.assertEqual(resp.status, 206)
        self.assertEqual(body, bytes(range(10, 20)))
        self.assertEqual(resp.getheader("Content-Range"), "bytes 10-19/1024")
        resp, body = self.get(path, {"Range": "bytes=1000-"})
        self.assertEqual((resp.status, len(body)), (206, 24))
        resp, body = self.get(path, {"Range": "bytes=-4"})
        self.assertEqual((resp.status, body), (206, bytes([252, 253, 254, 255])))
        resp, _ = self.get(path, {"Range": "bytes=5000-"})
        self.assertEqual(resp.status, 416)

    def test_head_gives_the_size_without_a_body(self) -> None:
        resp, body = self.get(f"/{TOKEN}/file/tt1909015/{library.quote(self.e2)}", method="HEAD")
        self.assertEqual((resp.status, body), (200, b""))
        self.assertEqual(resp.getheader("Content-Length"), "1024")

    def test_only_listed_video_files_are_served(self) -> None:
        for path in (
            "/file/tt1909015/..%2F..%2Fetc%2Fpasswd",
            "/file/tt1909015/Undercover%202011%20s06e04%201080p/sample.txt",
            "/file/tt1909015/Undercover%202011%20s06e03%201080p.mp4.%21qB",
            "/file/..%2Ftt1909015/x.mp4",
        ):
            resp, _ = self.get("/" + TOKEN + path)
            self.assertEqual(resp.status, 404, path)


class EpisodeTest(unittest.TestCase):
    def test_episode_numbers_come_from_the_file_name(self) -> None:
        self.assertEqual(library.episode_of("Undercover 2011 s06e02 1080p.mp4"), (6, 2))
        self.assertEqual(library.episode_of("Pod.Prikritie.S06E12.HDTV.mkv"), (6, 12))
        self.assertIsNone(library.episode_of("Inception.2010.1080p.mkv"))


if __name__ == "__main__":
    unittest.main()
