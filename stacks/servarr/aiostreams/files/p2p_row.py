"""A Stremio addon that plays torrent rows from the Sofia streaming server.

The shared Stremio account shows P2P rows on every device (Viktor). A device
that plays a raw torrent row torrents from its own network, and the London
flat's ISP objects to BitTorrent. So Viktor's main AIOStreams config returns no
torrent rows, and this addon ("P2P via Sofia") returns them instead, as plain
HTTPS rows:

    https://<host>/<token>/play/<infohash>/<fileIdx|auto>/<file name>

It asks AIOStreams on localhost for variant "p2p" of Viktor's config, which
keeps only the torrent rows. /play asks the streaming server in the cluster
(stacks/stremio, the stremio service) for the file and relays its bytes, Range
requests included, adding the server's basic-auth login, so players never hold
it. The server torrents from the Sofia line. A row without a file index plays
through "auto": the server starts the torrent, and the file named in the row,
else the requested episode, else the largest video, is played.

Install URL: https://<host>/<token>/manifest.json. The token is the only gate,
as for AIOStreams' own install URLs. Video crosses this host, so it is a
grey-cloud name (Cloudflare's CDN terms bar video on proxied hosts).

Standard library only, so nothing is installed at start.
Tests: cd files && python3 -m unittest test_p2p_row
"""
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8083"))
TYPES = ("movie", "series")
ID = re.compile(r"^tt\d+(?::\d+:\d+)?$")
HASH = re.compile(r"^[0-9a-f]{40}$")
INDEX = re.compile(r"^(\d+|auto)$")
VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v", ".webm", ".ts")
WARNING = re.compile(r"🚨 ?P2P [·—-] ?VPN[- ]ONLY ?🚨 ?")
CHUNK = 256 * 1024
# How long "auto" waits for the torrent's file list (the server needs the
# metadata from peers first).
FILES_WAIT_S = 25
# How long a started torrent counts as started.
STARTED_S = 3600
# Headers relayed from the streaming server to the player.
RELAYED = ("Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag")

MANIFEST = {
    "id": "me.viktorbarzin.p2p-sofia",
    "version": "1.0.0",
    "name": "P2P via Sofia",
    "description": "Torrent streams, played by the Sofia streaming server so this device never torrents.",
    "resources": ["stream"],
    "types": list(TYPES),
    "idPrefixes": ["tt"],
    "catalogs": [],
}


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def http_get_json(url: str, auth: tuple[str, str] | None = None) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "p2p-row"})
    if auth:
        request.add_header("Authorization", basic(auth))
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.load(response)


def basic(auth: tuple[str, str]) -> str:
    return "Basic " + b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()


def file_name(stream: dict) -> str:
    return (stream.get("behaviorHints") or {}).get("filename") or ""


def safe_segment(name: str) -> str:
    """The last URL segment: the file name, so players see a sensible title."""
    name = re.sub(r"[^\w.\- ]+", "", name).strip() or "video"
    if not name.lower().endswith(VIDEO_EXT):
        name += ".mkv"
    return urllib.parse.quote(name)


def episode_of(media_id: str) -> tuple[int, int] | None:
    parts = media_id.split(":")
    if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
        return int(parts[1]), int(parts[2])
    return None


def pick_file(files: list[dict], wanted: str, media_id: str) -> int | None:
    """The file to play: the one the row names, else the requested episode,
    else the largest video. None when the torrent has no video."""
    videos = [(i, f) for i, f in enumerate(files) if (f.get("name") or "").lower().endswith(VIDEO_EXT)]
    if not videos:
        return None
    stem = wanted.lower().rsplit(".", 1)[0] if wanted.lower().endswith(VIDEO_EXT) else wanted.lower()
    if stem:
        for i, f in videos:
            name = f["name"].lower()
            if name == wanted.lower() or name.rsplit(".", 1)[0] == stem or name.endswith("/" + stem + "." + name.rsplit(".", 1)[-1]):
                return i
    ep = episode_of(media_id)
    if ep:
        pattern = re.compile(rf"(?<!\d)(s0*{ep[0]}\s*e0*{ep[1]}|0*{ep[0]}x0*{ep[1]})(?!\d)", re.IGNORECASE)
        matches = [(i, f) for i, f in videos if pattern.search(f["name"])]
        if matches:
            return max(matches, key=lambda x: x[1].get("length") or 0)[0]
    return max(videos, key=lambda x: x[1].get("length") or 0)[0]


def route(path: str, token: str) -> tuple | None:
    path = urllib.parse.urlsplit(path).path
    if path in ("/", "/healthz"):
        return ("health",)
    parts = path.strip("/").split("/")
    if len(parts) < 2 or parts[0] != token:
        return None
    if parts[1:] == ["manifest.json"]:
        return ("manifest",)
    if len(parts) == 4 and parts[1] == "stream" and parts[2] in TYPES and parts[3].endswith(".json"):
        media_id = urllib.parse.unquote(parts[3][: -len(".json")])
        if ID.match(media_id):
            return ("stream", parts[2], media_id)
    if len(parts) in (4, 5) and parts[1] == "play" and HASH.match(parts[2]) and INDEX.match(parts[3]):
        return ("play", parts[2], parts[3])
    return None


class Addon:
    def __init__(self, base: str, uuid: str, password: str, public_url: str, token: str,
                 get_json=http_get_json, variant: str = "p2p",
                 stremio: str = "http://stremio.stremio.svc.cluster.local",
                 stremio_auth: tuple[str, str] | None = None):
        self.base, self.uuid, self.password, self.get_json = base, uuid, password, get_json
        self.public_url, self.token, self.variant = public_url.rstrip("/"), token, variant
        self.stremio, self.stremio_auth = stremio.rstrip("/"), stremio_auth
        self.resolved: dict[str, int] = {}
        self.started: dict[str, float] = {}
        self._encrypted = None
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ rows
    def _encrypted_password(self, refresh: bool = False) -> str:
        with self._lock:
            if refresh or self._encrypted is None:
                data = self.get_json(f"{self.base}/api/v1/user", auth=(self.uuid, self.password))
                self._encrypted = data["data"]["encryptedPassword"]
            return self._encrypted

    def _upstream(self, kind: str, media_id: str, refresh: bool) -> list[dict]:
        enc = urllib.parse.quote(self._encrypted_password(refresh), safe="")
        sid = urllib.parse.quote(media_id, safe=":")
        url = f"{self.base}/stremio/{self.uuid}/{enc}/v/{self.variant}/stream/{kind}/{sid}.json"
        return self.get_json(url).get("streams", [])

    def row(self, stream: dict, media_id: str) -> dict:
        h = stream["infoHash"].lower()
        idx = stream.get("fileIdx")
        name = file_name(stream)
        url = f"{self.public_url}/{self.token}/play/{h}/"
        if isinstance(idx, int) and idx >= 0:
            url += f"{idx}/{safe_segment(name)}"
        else:
            query = urllib.parse.urlencode({"id": media_id, "f": name})
            url += f"auto/{safe_segment(name)}?{query}"
        hints = dict(stream.get("behaviorHints") or {})
        hints["bingeGroup"] = "p2p-sofia|" + (hints.get("bingeGroup") or h)
        # Web players need the server to remux anything but mp4.
        hints["notWebReady"] = not name.lower().endswith(".mp4")
        return {
            "name": "☁️ Sofia P2P · " + WARNING.sub("", stream.get("name") or "").strip(),
            "description": WARNING.sub("", stream.get("description") or "").strip(),
            "url": url,
            "behaviorHints": hints,
        }

    def streams(self, kind: str, media_id: str) -> dict:
        try:
            try:
                upstream = self._upstream(kind, media_id, refresh=False)
            except urllib.error.HTTPError as e:
                if e.code not in (401, 403):
                    raise
                upstream = self._upstream(kind, media_id, refresh=True)
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as e:
            log(f"no rows for {kind} {media_id}: {e!r}")
            return {"streams": []}
        return {"streams": [self.row(s, media_id) for s in upstream if s.get("infoHash")]}

    # ------------------------------------------------------------------ play
    def _server(self, path: str, method: str = "GET", data: bytes | None = None,
                headers: dict | None = None, timeout: float = 30):
        request = urllib.request.Request(f"{self.stremio}{path}", data=data, method=method, headers=headers or {})
        if self.stremio_auth:
            request.add_header("Authorization", basic(self.stremio_auth))
        return urllib.request.urlopen(request, timeout=timeout)

    def start(self, h: str) -> None:
        """Start the torrent on the server. A plain GET of a file does not: the
        server then has no trackers and finds peers through DHT alone. /create
        with an empty body uses the server's own tracker list. Again after an
        hour, in case the server dropped the torrent."""
        now = time.monotonic()
        if now - self.started.get(h, -STARTED_S) < STARTED_S:
            return
        with self._server(f"/{h}/create", method="POST", data=b"{}", headers={"Content-Type": "application/json"}):
            pass
        self.started[h] = now

    def resolve(self, h: str, wanted: str, media_id: str) -> int | None:
        if h in self.resolved:
            return self.resolved[h]
        self.start(h)
        deadline = time.monotonic() + FILES_WAIT_S
        while time.monotonic() < deadline:
            with self._server(f"/{h}/stats.json", timeout=15) as r:
                files = (json.load(r) or {}).get("files") or []
            if files:
                idx = pick_file(files, wanted, media_id)
                if idx is not None:
                    self.resolved[h] = idx
                return idx
            time.sleep(1)
        return None


def make_handler(addon: Addon, token: str):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _json(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _empty(self, status: int) -> None:
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            self._handle(head=False)

        def do_HEAD(self):
            self._handle(head=True)

        def _handle(self, head: bool):
            target = route(self.path, token)
            if target is None:
                return self._empty(404)
            if target[0] == "health":
                return self._json(200, {"ok": True})
            if target[0] == "manifest":
                return self._json(200, MANIFEST)
            if target[0] == "stream":
                return self._json(200, addon.streams(target[1], target[2]))
            self._play(target[1], target[2], head)

        def _play(self, h: str, idx: str, head: bool):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            try:
                addon.start(h)
                if idx == "auto":
                    found = addon.resolve(h, (query.get("f") or [""])[0], (query.get("id") or [""])[0])
                    if found is None:
                        log(f"play {h}: no video file found")
                        return self._empty(404)
                    idx = str(found)
                headers = {}
                if self.headers.get("Range"):
                    headers["Range"] = self.headers["Range"]
                upstream = addon._server(f"/{h}/{idx}", method="HEAD" if head else "GET", headers=headers, timeout=60)
            except urllib.error.HTTPError as e:
                log(f"play {h}/{idx}: server answered {e.code}")
                return self._empty(e.code if e.code in (404, 416) else 502)
            except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
                log(f"play {h}/{idx}: {e!r}")
                return self._empty(502)
            with upstream:
                self.send_response(upstream.status)
                for name in RELAYED:
                    if upstream.headers.get(name):
                        self.send_header(name, upstream.headers[name])
                self.end_headers()
                if head:
                    return
                try:
                    while True:
                        chunk = upstream.read(CHUNK)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass  # the player seeked or stopped

    return Handler


def main() -> None:
    token = os.environ["P2P_ROW_TOKEN"]
    addon = Addon(
        base=os.environ.get("AIOSTREAMS_BASE", "http://localhost:3000"),
        uuid=os.environ["AIOSTREAMS_UUID"],
        password=os.environ["AIOSTREAMS_PASSWORD"],
        public_url=os.environ["PUBLIC_URL"],
        token=token,
        variant=os.environ.get("AIOSTREAMS_VARIANT", "p2p"),
        stremio=os.environ.get("STREMIO_BASE", "http://stremio.stremio.svc.cluster.local"),
        stremio_auth=(os.environ["STREMIO_SERVER_USER"], os.environ["STREMIO_SERVER_PASSWORD"]),
    )
    ThreadingHTTPServer(("", PORT), make_handler(addon, token)).serve_forever()


if __name__ == "__main__":
    main()
