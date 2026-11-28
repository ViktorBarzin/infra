"""A Stremio addon that plays films and episodes from our server, and saves
films and episodes to watch later (saves.py).

Files: qBittorrent saves a title into /downloads/stremio/<imdb id>/ (category
"stremio"). This addon lists those files as stream rows ("Our server") and
serves them over HTTPS with byte ranges, so Stremio plays them like any other
link and fetches subtitles for them as usual. For a series id tt…:S:E, every
video file under the title's folder whose name carries SxxEyy for that
episode; for a film, every video file in its folder. qBittorrent names an
unfinished file "<name>.!qB", so it never shows. Files are served only when
they are on that list, so no other path on the share is reachable.

Saves: each Stremio account installs its own manifest,
/<token>/a/<account>/manifest.json (viktor, emo), whose rows offer "Save this
episode", show "Saving 45%" and play the copy once it is "Saved"; saves.py
explains the rules. The old /<token>/manifest.json is the viktor account.

Subtitles: the accounts in SUBTITLES_ACCOUNTS (viktor) also get a subtitles
resource, "English (synced)", timed to the sound of the file that plays;
subtitles.py explains how.

The token is the only gate, as for AIOStreams' own install URLs. The public
host is DNS-only (not proxied by Cloudflare), whose terms bar serving video
through its CDN; emo's rows use the internal host, as his TV on the Sofia LAN
has no hairpin NAT to our public address.

Standard library, plus ffmpeg and ffsubsync on the image (images/stremio-library).
Tests: cd files && python3 -m unittest test_library test_saves test_subtitles
"""
import hmac
import json
import os
import re
import sys
import urllib.error
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import saves as saves_module
from saves import RES, STREAM_ID, Refused, Saves, ServiceError, Stop, episode_of, videos
from subtitles import Subtitles, parse_extra

CONTENT_TYPES = {".mkv": "video/x-matroska", ".mp4": "video/mp4", ".m4v": "video/mp4", ".avi": "video/x-msvideo"}
CHUNK = 1 << 20
ACTIONS = ("v", "follow", "remove", "retry")

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


def size_label(size: int) -> str:
    return f"{size / 1e9:.2f} GB" if size >= 1e8 else f"{size / 1e6:.0f} MB"


def rows(root: str, base: str, kind: str, media_id: str, skip: set[str] | frozenset[str] = frozenset()) -> list[dict]:
    """Rows for the files on our server; base is https://<host>/<token>[/a/<account>]."""
    m = STREAM_ID.match(media_id)
    if not m:
        return []
    imdb, season, episode = m.group(1), m.group(2), m.group(3)
    out = []
    for rel in videos(root, imdb):
        if rel in skip:
            continue
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
                "url": f"{base}/file/{imdb}/{quote(rel)}",
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


def content_range_start(value: str | None) -> tuple[int, int] | None:
    """(start, total) from "bytes 10-19/1000"."""
    m = re.match(r"^bytes (\d+)-\d+/(\d+)$", value or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def make_handler(root: str, token: str, public_url: str, saves: Saves | None = None, subs: Subtitles | None = None):
    def account_manifest(account: str) -> dict:
        assert saves is not None
        data = saves_module.manifest(saves.accounts[account])
        if subs and account in subs.accounts:
            data["resources"] = [*data["resources"], "subtitles"]
        return data

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: object) -> None:  # one line per request, token hidden
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
            m = re.match(r"^a/([a-z]+)/(.+)$", rest)
            if m:
                if saves is None or m.group(1) not in saves.accounts:
                    self.not_found()
                    return
                account = m.group(1)
                self.account_route(account, m.group(2), f"{saves.accounts[account].public_url}/{token}/a/{account}", head)
                return
            # The old install URL: files only, or the viktor account when saves run.
            if saves is not None and "viktor" in saves.accounts and rest != "manifest.json":
                self.account_route("viktor", rest, f"{public_url}/{token}", head)
                return
            if rest == "manifest.json":
                self.send_json(account_manifest("viktor") if saves and "viktor" in saves.accounts else MANIFEST)
                return
            self.account_route(None, rest, f"{public_url}/{token}", head)

        def account_route(self, account: str | None, rest: str, file_base: str, head: bool) -> None:
            if rest == "manifest.json" and saves and account:
                self.send_json(account_manifest(account))
                return
            if subs and account in subs.accounts:
                m = re.match(r"^subtitles/(movie|series)/([^/]+?)(?:/([^/]+))?\.json$", rest)
                if m:
                    vid = urllib.parse.unquote(m.group(2))
                    found = subs.listing(m.group(1), vid, parse_extra(m.group(3) or ""), file_base) if STREAM_ID.match(vid) else []
                    self.send_json({"subtitles": found})
                    return
                m = re.match(r"^sub/([0-9a-f]{16})\.srt$", rest)
                if m:
                    self.send_subtitle(subs.file(m.group(1)), head)
                    return
            if rest == "catalog/movie/saved.json" and saves and account:
                self.send_json({"metas": saves.catalog(account)})
                return
            m = re.match(r"^stream/(movie|series)/([^/]+)\.json$", rest)
            if m:
                kind, media_id = m.group(1), urllib.parse.unquote(m.group(2))
                if account and saves:
                    if not STREAM_ID.match(media_id):
                        self.not_found()
                        return
                    imdb = media_id.split(":")[0]
                    found = saves.rows(account, kind, media_id) + rows(root, file_base, kind, media_id, saves.saved_paths(account, imdb))
                else:
                    found = rows(root, file_base, kind, media_id)
                self.send_json({"streams": found})
                return
            m = re.match(r"^file/(tt\d+)/(.+)$", rest)
            if m:
                imdb, rel = m.group(1), urllib.parse.unquote(m.group(2))
                if rel in videos(root, imdb):
                    copy_id = saves.server_copy_at(imdb, rel) if saves and account else None
                    self.send_file(os.path.join(root, imdb, rel), head, account, copy_id)
                    return
            m = re.match(r"^([a-z]+)/([^/]+)$", rest)
            if m and m.group(1) in ACTIONS and saves and account:
                vid = urllib.parse.unquote(m.group(2))
                if STREAM_ID.match(vid):
                    self.tap(account, m.group(1), vid, head)
                    return
            self.not_found()

        def send_subtitle(self, body: bytes | None, head: bool) -> None:
            if body is None:
                self.not_found()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/x-subrip; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def tap(self, account: str, action: str, vid: str, head: bool) -> None:
            assert saves is not None
            if head:  # a HEAD never records anything
                save = saves.save_of(account, vid)
                copy = saves.copy_of(account, vid) if save and save["state"] != "removed" else None
                if copy is None or copy["status"] != "ready" or copy["place"] != "server":
                    self.send_file(saves.clip_path(account, "saved" if save is None else "saving"), True, None, None, clip=True)
                    return
                self.send_file(os.path.join(root, vid.split(":")[0], copy["path"]), True, None, None)
                return
            result = saves.tap(account, action, vid)
            if result[0] == "clip":
                self.send_file(saves.clip_path(account, result[1]), head, None, None, clip=True)
            elif result[0] == "server":
                self.send_file(result[1], head, account, result[2])
            else:
                self.proxy(account, result[1])

        def send_file(self, full: str, head: bool, account: str | None, copy_id: int | None, clip: bool = False) -> None:
            try:
                size = os.path.getsize(full)
            except OSError:
                self.not_found()
                return
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
            if clip:
                self.send_header("Cache-Control", "no-store")
            if rng:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            sent = 0
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
                        sent += len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # the player seeks by dropping the connection
            if saves and account and copy_id is not None:
                saves.delivered(account, copy_id, start, start + sent, size)

        def proxy(self, account: str, copy: dict) -> None:
            """A Real-Debrid copy: the bytes come through Sofia, so Real-Debrid
            sees one IP for every player."""
            assert saves is not None
            rng = self.headers.get("Range")
            try:
                upstream = saves.opener(saves.upstream_url(copy), rng)
            except Refused:
                saves.refused_at_play(copy)
                self.send_file(saves.clip_path(account, "saving"), False, None, None, clip=True)
                return
            except (Stop, ServiceError, OSError, urllib.error.URLError) as e:
                saves.log(f"no playback of {copy['release']}: {e!r}")
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                status = upstream.status
                headers = upstream.headers
                self.send_response(status)
                # Real-Debrid answers application/force-download; players get the
                # video type from the file name, as for files on our server.
                ext = os.path.splitext(str(copy.get("release") or ""))[1].lower()
                kind = CONTENT_TYPES.get(ext) or headers.get("Content-Type")
                if kind:
                    self.send_header("Content-Type", str(kind))
                for name in ("Content-Length", "Content-Range", "Accept-Ranges"):
                    value = headers.get(name)
                    if value:
                        self.send_header(name, str(value))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                if status >= 400:
                    return
                span = content_range_start(headers.get("Content-Range"))
                start, size = span if span else (0, int(headers.get("Content-Length") or copy["size"] or 0))
                sent = 0
                try:
                    while True:
                        chunk = upstream.read(CHUNK)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        sent += len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                saves.delivered(account, copy["id"], start, start + sent, size or copy["size"])
            finally:
                upstream.close()

    return Handler


def main() -> None:
    root = os.environ.get("LIBRARY_DIR", "/media")
    token = os.environ["LIBRARY_TOKEN"]
    public_url = os.environ["PUBLIC_URL"].rstrip("/")
    port = int(os.environ.get("PORT", "8080"))
    saves = None
    subs = None
    if os.environ.get("DATA_DIR"):
        saves = Saves(saves_module.config_from_env(dict(os.environ), root, token))
        saves.start()
        accounts = frozenset(a.strip() for a in os.environ.get("SUBTITLES_ACCOUNTS", "").split(",") if a.strip())
        if accounts:
            subs = Subtitles(os.path.join(os.environ["DATA_DIR"], "subs"), root, saves.rd, saves_module.http_fetch, accounts & set(saves.accounts))
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(root, token, public_url, saves, subs))
    server.daemon_threads = True
    sys.stderr.write(f"library: serving {root} on :{port}" + (" with saves" if saves else "") + "\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
