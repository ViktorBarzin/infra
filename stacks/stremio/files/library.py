"""A Stremio addon that plays films and episodes downloaded to our server.

qBittorrent saves a title into /downloads/stremio/<imdb id>/ (category
"stremio"), for releases Real-Debrid refuses or does not have. This addon lists
those files as stream rows ("Our server") and serves them over HTTPS with byte
ranges, so Stremio plays them like any other link and fetches subtitles for
them as usual.

Rows: for a series id tt…:S:E, every video file under the title's folder
whose name carries SxxEyy for that episode; for a film, every video file in
its folder. qBittorrent names an unfinished file "<name>.!qB", so it never
shows. Files are served only when they are on that list, so no other path on
the share is reachable.

Install URL: https://<host>/<token>/manifest.json. The token is the only gate,
as for AIOStreams' own install URLs. The host is DNS-only (not proxied by
Cloudflare), whose terms bar serving video through its CDN.

Standard library only. Tests: cd files && python3 -m unittest test_library
"""
import hmac
import json
import os
import re
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v")
CONTENT_TYPES = {".mkv": "video/x-matroska", ".mp4": "video/mp4", ".m4v": "video/mp4", ".avi": "video/x-msvideo"}
EPISODE = re.compile(r"(?i)\bs(\d{1,2})[ ._-]?e(\d{1,3})\b")
IMDB = re.compile(r"^tt\d+$")
STREAM_ID = re.compile(r"^(tt\d+)(?::(\d+):(\d+))?$")
RES = re.compile(r"(?i)(2160|1080|720|480)p")
CHUNK = 1 << 20

MANIFEST = {
    "id": "me.viktorbarzin.library",
    "version": "1.0.0",
    "name": "Our server",
    "description": "Films and episodes downloaded to our server.",
    "resources": ["stream"],
    "types": ["movie", "series"],
    "idPrefixes": ["tt"],
    "catalogs": [],
}


def quote(path: str) -> str:
    return urllib.parse.quote(path, safe="/")


def episode_of(name: str) -> tuple[int, int] | None:
    m = EPISODE.search(name)
    return (int(m.group(1)), int(m.group(2))) if m else None


def videos(root: str, imdb: str) -> list[str]:
    """Finished video files under root/imdb, as paths relative to that folder."""
    if not IMDB.match(imdb):
        return []
    base = os.path.join(root, imdb)
    found = []
    for folder, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.lower().endswith(VIDEO_EXT) and not f.startswith("."):
                found.append(os.path.relpath(os.path.join(folder, f), base))
    return sorted(found)


def size_label(size: int) -> str:
    return f"{size / 1e9:.2f} GB" if size >= 1e8 else f"{size / 1e6:.0f} MB"


def rows(root: str, public_url: str, token: str, kind: str, media_id: str) -> list[dict]:
    m = STREAM_ID.match(media_id)
    if not m:
        return []
    imdb, season, episode = m.group(1), m.group(2), m.group(3)
    out = []
    for rel in videos(root, imdb):
        name = os.path.basename(rel)
        if kind == "series":
            if season is None or episode_of(name) != (int(season), int(episode)):
                continue
        elif season is not None:
            continue
        size = os.path.getsize(os.path.join(root, imdb, rel))
        res = RES.search(name)
        out.append(
            {
                "name": "Our server" + (f"\n{res.group(1)}p" if res else ""),
                "title": f"{name}\n💾 {size_label(size)}",
                "url": f"{public_url}/{token}/file/{imdb}/{quote(rel)}",
                "behaviorHints": {"filename": name, "videoSize": size, "bingeGroup": "me.viktorbarzin.library"},
            }
        )
    return out


def parse_range(header: str | None, size: int) -> tuple[int, int] | None | str:
    """(start, end) inclusive; None for the whole file; "bad" when unsatisfiable."""
    if not header or not header.startswith("bytes=") or "," in header:
        return None
    first, _, last = header[6:].strip().partition("-")
    try:
        if first == "":
            n = int(last)
            if n <= 0:
                return "bad"
            return max(0, size - n), size - 1
        start = int(first)
        end = int(last) if last else size - 1
    except ValueError:
        return None
    if start >= size or end < start:
        return "bad"
    return start, min(end, size - 1)


def make_handler(root: str, token: str, public_url: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args) -> None:  # one line per request, token hidden
            sys.stderr.write("%s %s\n" % (self.command, self.path.replace(token, "<token>")[:200]))

        def send_json(self, data: dict) -> None:
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def not_found(self) -> None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_HEAD(self) -> None:
            self.handle_request(head=True)

        def do_GET(self) -> None:
            self.handle_request(head=False)

        def handle_request(self, head: bool) -> None:
            path = urllib.parse.urlsplit(self.path).path
            if path in ("/", "/healthz"):  # / for the uptime monitor, which probes the root
                self.send_json({"ok": True})
                return
            parts = path.split("/", 2)  # "", token, rest
            if len(parts) < 3 or not hmac.compare_digest(parts[1].encode(), token.encode()):
                self.not_found()
                return
            rest = parts[2]
            if rest == "manifest.json":
                self.send_json(MANIFEST)
                return
            m = re.match(r"^stream/(movie|series)/([^/]+)\.json$", rest)
            if m:
                media_id = urllib.parse.unquote(m.group(2))
                self.send_json({"streams": rows(root, public_url, token, m.group(1), media_id)})
                return
            m = re.match(r"^file/(tt\d+)/(.+)$", rest)
            if m:
                rel = urllib.parse.unquote(m.group(2))
                if rel in videos(root, m.group(1)):
                    self.send_file(os.path.join(root, m.group(1), rel), head)
                    return
            self.not_found()

        def send_file(self, full: str, head: bool) -> None:
            size = os.path.getsize(full)
            rng = parse_range(self.headers.get("Range"), size)
            if rng == "bad":
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = rng if rng else (0, size - 1)
            self.send_response(206 if rng else 200)
            ext = os.path.splitext(full)[1].lower()
            self.send_header("Content-Type", CONTENT_TYPES.get(ext, "application/octet-stream"))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(end - start + 1))
            if rng:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            with open(full, "rb") as f:
                f.seek(start)
                left = end - start + 1
                try:
                    while left > 0:
                        chunk = f.read(min(CHUNK, left))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        left -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # the player seeks by dropping the connection

    return Handler


def main() -> None:
    root = os.environ.get("LIBRARY_DIR", "/media")
    token = os.environ["LIBRARY_TOKEN"]
    public_url = os.environ["PUBLIC_URL"].rstrip("/")
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(root, token, public_url))
    server.daemon_threads = True
    sys.stderr.write(f"library: serving {root} on :{port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
