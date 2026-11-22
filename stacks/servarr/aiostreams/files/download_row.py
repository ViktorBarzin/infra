"""A Stremio addon that adds "Download" rows to each film or episode.

The row opens one of AIOStreams' own links in the browser. The proxy sends
Content-Disposition: attachment, so the browser saves the file, and VLC plays
it offline (the London tablet, for flights). Stremio rows do one thing each
(play, or open a link), so the download cannot sit on the play row itself.

It asks AIOStreams on localhost for Viktor's streams and returns externalUrl
rows: a recommended file first, then a short ladder of other sizes per
resolution, each labelled with its resolution and size. Files whose name lacks
the film's title (from Cinemeta) are left out. Each link ends in a clean file
name, "Inception (2010) 720p.mkv"; the AIOStreams proxy ignores that segment,
and the browser saves the file under it.

What is on the tablet: a devvm timer (tablet-downloads-sync) lists the video
files in its Downloads folder every hour and POSTs them to /<token>/inventory.
Files this addon named map back to their titles, which give a "Downloaded"
catalog on the Home board and a "▶ On the tablet" row that opens the file in
VLC (vlc://file://...). Stremio itself cannot play local files on Android.

Install URL: https://<host>/<token>/manifest.json. The token is the only gate,
as for AIOStreams' own install URLs.

Standard library only, so nothing is installed at start.
Tests: cd files && python3 -m unittest test_download_row
"""
import json
import os
import re
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8082"))
# Largest file the row offers when a smaller one exists: about 20 minutes at
# the 41 Mbit/s the tablet measured in London on 2026-11-22.
MAX_BYTES = 6_000_000_000
# Resolutions in the order the recommended row prefers them. 1080p looks
# right on an 11-inch screen and keeps files small.
PREFERENCE = (1080, 2160, 720, 480)
# Below the recommended row, a ladder per resolution: the smallest file, and
# the largest one up to LADDER_MAX_BYTES when it is at least LADDER_STEP times
# bigger. Remuxes of 20-80 GB stay out unless nothing smaller exists.
LADDER_MAX_BYTES = 15_000_000_000
LADDER_STEP = 1.3
TYPES = ("movie", "series")
ID = re.compile(r"^tt\d+(?::\d+:\d+)?$")
RES = re.compile(r"(2160|1080|720|480)p", re.IGNORECASE)
# AIOStreams' formatter lists audio languages after 🌎, then subtitles after 📝.
AUDIO = re.compile(r"🌎([^📝\n]*)")
# On a dual-audio file VLC often starts on the other language, so a file whose
# audio is English alone wins over a bigger one; a file with no language line
# counts as English, the usual case for English releases.
AUDIO_LANGUAGE = "English"

VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v")
# Chrome saves a second copy of a name as "<name> (1).<ext>".
COPY_SUFFIX = re.compile(r" \(\d+\)(?=\.[A-Za-z0-9]+$)")
UNSAFE = re.compile(r'\s*[\\/:*?"<>|]+\s*')
POSTER = "https://images.metahub.space/poster/medium/{}/img"
MAX_BODY = 1_000_000

MANIFEST = {
    "id": "me.viktorbarzin.download",
    "version": "1.1.0",
    "name": "Download",
    "description": "Saves films for offline viewing and lists what is on the tablet.",
    "resources": ["catalog", "stream"],
    "types": list(TYPES),
    "idPrefixes": ["tt"],
    "catalogs": [{"type": t, "id": "downloaded", "name": "Downloaded"} for t in TYPES],
}


def resolution_of(stream: dict) -> int | None:
    hints = stream.get("behaviorHints") or {}
    for text in (hints.get("bingeGroup"), stream.get("name"), hints.get("filename")):
        match = RES.search(text or "")
        if match:
            return int(match.group(1))
    return None


def size_of(stream: dict) -> int:
    return int((stream.get("behaviorHints") or {}).get("videoSize") or 0)


def audio_languages(stream: dict) -> list[str]:
    match = AUDIO.search(stream.get("description") or "")
    return [x.strip() for x in match.group(1).split("|") if x.strip()] if match else []


def single_language(stream: dict) -> bool:
    return set(audio_languages(stream)) <= {AUDIO_LANGUAGE}


def words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", text)


def title_matches(title: str, filename: str) -> bool:
    """The title's words appear in a row in the filename. Mislabeled torrents
    carry another film's file (a 720p "Inception" was The Island of Dr. Moreau),
    and the smallest-file slots find them first. No filename: keep it."""
    want, have = words(title), words(filename)
    if not want or not have:
        return True
    n = len(want)
    return any(have[i : i + n] == want for i in range(len(have) - n + 1))


def is_candidate(stream: dict) -> bool:
    # A direct link (P2P rows and AIOStreams' own download rows have none),
    # cached in Real-Debrid (the formatter marks uncached files with ⏳), and
    # of known size, so the row can say how big it is.
    return bool(stream.get("url")) and "⏳" not in (stream.get("name") or "") and size_of(stream) > 0


def filename_of(stream: dict) -> str:
    return (stream.get("behaviorHints") or {}).get("filename") or ""


def choose(streams: list[dict], max_bytes: int = MAX_BYTES) -> dict | None:
    """The largest file that fits under max_bytes at the most preferred
    resolution, English-only audio first; the smallest file of all when none fits."""
    candidates = [s for s in streams if is_candidate(s)]
    for res in PREFERENCE:
        fitting = [s for s in candidates if resolution_of(s) == res and size_of(s) <= max_bytes]
        if fitting:
            return max(fitting, key=lambda s: (single_language(s), size_of(s)))
    fitting = [s for s in candidates if size_of(s) <= max_bytes]
    if fitting:
        return max(fitting, key=lambda s: (single_language(s), size_of(s)))
    return min(candidates, key=size_of, default=None)


def label(res: int | None) -> str | None:
    return "4K" if res == 2160 else f"{res}p" if res else None


def clean_name(title: str, year: str | None, media_id: str, res: int | None, original: str) -> str:
    """"Inception (2010) 720p.mkv", "Breaking Bad S01E01 1080p.mkv"."""
    parts = media_id.split(":")
    name = UNSAFE.sub(" - ", title).strip(" -")
    if len(parts) == 3:
        name += f" S{int(parts[1]):02d}E{int(parts[2]):02d}"
    elif year:
        name += f" ({str(year)[:4]})"
    if res:
        name += f" {label(res)}"
    ext = os.path.splitext(original)[1].lower()
    return name + (ext if ext in VIDEO_EXT else ".mkv")


def named_link(url: str, name: str) -> str:
    """The same link with name as its last segment, which the proxy ignores and
    the browser uses as the file name."""
    base = url.rsplit("/", 1)[0]
    return f"{base}/{urllib.parse.quote(name)}"


def ladder(streams: list[dict]) -> list[dict]:
    """Per resolution, lowest first: the smallest file, then the largest up to
    LADDER_MAX_BYTES when it is clearly bigger. English-only audio files fill
    a resolution's slots when there are any. 480p only when 720p is missing."""
    candidates = [s for s in streams if is_candidate(s)]
    found = {resolution_of(s) for s in candidates}
    out = []
    for res in (480, 720, 1080, 2160):
        if res == 480 and 720 in found:
            continue
        pool = [s for s in candidates if resolution_of(s) == res]
        pool = [s for s in pool if single_language(s)] or pool
        if not pool:
            continue
        small = min(pool, key=size_of)
        out.append(small)
        fitting = [s for s in pool if size_of(s) <= LADDER_MAX_BYTES]
        big = max(fitting, key=size_of, default=None)
        if big is not None and size_of(big) >= LADDER_STEP * size_of(small):
            out.append(big)
    return out


def row(stream: dict, recommended: bool = False, saved_as: str | None = None) -> dict:
    tag = label(resolution_of(stream))
    size = f"{size_of(stream) / 1e9:.1f} GB"
    details = f"{tag} · {size}" if tag else size
    name = "Recommended" if recommended else tag or "Download"
    return {
        "name": f"⬇ {name}",
        # The release name says where the copy comes from.
        "description": "\n".join(x for x in (details, filename_of(stream)) if x),
        "externalUrl": named_link(stream["url"], saved_as) if saved_as else stream["url"],
    }


def options(streams: list[dict], title: str | None = None, name_for=None) -> list[dict]:
    """The recommended file first, then the ladder without it. With a title,
    files named after another title are left out. name_for(stream) gives the
    file name the browser saves it under."""
    if title:
        streams = [s for s in streams if title_matches(title, filename_of(s))]
    best = choose(streams)
    if best is None:
        return []
    rest = [s for s in ladder(streams) if s.get("url") != best.get("url")]
    name = name_for or (lambda s: None)
    return [row(best, recommended=True, saved_as=name(best))] + [row(s, saved_as=name(s)) for s in rest]


class Library:
    """The names this addon gave its downloads, and the tablet's last file list.
    Both persist as JSON under path, so a restart keeps them."""

    def __init__(self, path: str | None):
        self.path = path
        self.names: dict[str, dict] = {}
        self.inventory: dict = {"dir": "", "files": [], "updated": 0}
        self._lock = threading.Lock()
        if path:
            os.makedirs(path, exist_ok=True)
            self.names = self._load("names.json", {})
            self.inventory = self._load("inventory.json", self.inventory)

    def _load(self, name: str, default):
        try:
            with open(os.path.join(self.path, name)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return default

    def _save(self, name: str, data) -> None:
        if not self.path:
            return
        tmp = os.path.join(self.path, name + ".tmp")
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, os.path.join(self.path, name))

    def remember(self, name: str, kind: str, media_id: str, title: str) -> None:
        entry = {"type": kind, "id": media_id, "title": title}
        with self._lock:
            if self.names.get(name) != entry:
                self.names[name] = entry
                self._save("names.json", self.names)

    def set_inventory(self, payload: dict, now: float | None = None) -> None:
        files = payload.get("files") if isinstance(payload, dict) else None
        if not isinstance(payload.get("dir") if isinstance(payload, dict) else None, str) or not isinstance(files, list):
            raise ValueError("expected {dir, files}")
        clean = []
        for f in files[:5000]:
            if not (isinstance(f, dict) and isinstance(f.get("name"), str) and isinstance(f.get("size"), int)):
                raise ValueError("each file needs a name and a size")
            clean.append({"name": f["name"][:300], "size": f["size"], "mtime": int(f.get("mtime") or 0)})
        with self._lock:
            self.inventory = {"dir": payload["dir"], "files": clean, "updated": int(now or time.time())}
            self._save("inventory.json", self.inventory)

    def _on_tablet(self):
        """(file, entry) for files this addon named, newest first."""
        files = sorted(self.inventory.get("files", []), key=lambda f: f.get("mtime", 0), reverse=True)
        for f in files:
            entry = self.names.get(COPY_SUFFIX.sub("", f["name"]))
            if entry:
                yield f, entry

    def catalog(self, kind: str) -> list[dict]:
        metas, seen = [], set()
        for _, entry in self._on_tablet():
            show_id = entry["id"].split(":")[0]
            if entry["type"] != kind or show_id in seen:
                continue
            seen.add(show_id)
            metas.append({"id": show_id, "type": kind, "name": entry["title"], "poster": POSTER.format(show_id)})
        return metas

    def play_rows(self, media_id: str) -> list[dict]:
        folder = self.inventory.get("dir", "").rstrip("/")
        rows = []
        for f, entry in self._on_tablet():
            if entry["id"] != media_id:
                continue
            rows.append({
                "name": "▶ On the tablet",
                "description": f"{f['size'] / 1e9:.1f} GB · plays in VLC\n{f['name']}",
                "externalUrl": "vlc://file://" + urllib.parse.quote(f"{folder}/{f['name']}"),
            })
        return rows


def route(path: str, token: str) -> tuple | None:
    path = urllib.parse.urlsplit(path).path
    if path in ("/", "/healthz"):
        return ("health",)
    parts = path.strip("/").split("/")
    if len(parts) < 2 or parts[0] != token:
        return None
    if parts[1:] == ["manifest.json"]:
        return ("manifest",)
    if parts[1:] == ["inventory"]:
        return ("inventory",)
    if len(parts) == 4 and parts[1] == "catalog" and parts[2] in TYPES and parts[3] == "downloaded.json":
        return ("catalog", parts[2])
    if len(parts) == 4 and parts[1] == "stream" and parts[2] in TYPES and parts[3].endswith(".json"):
        media_id = urllib.parse.unquote(parts[3][: -len(".json")])
        if ID.match(media_id):
            return ("stream", parts[2], media_id)
    return None


def http_get_json(url: str, auth: tuple[str, str] | None = None) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "download-row"})
    if auth:
        token = b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        request.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.load(response)


class Addon:
    def __init__(
        self, base: str, uuid: str, password: str, get_json=http_get_json,
        variant: str | None = None, cinemeta: str | None = None, library: Library | None = None,
    ):
        self.base, self.uuid, self.password, self.get_json = base, uuid, password, get_json
        # Cinemeta, for the title the filenames must carry. AIOStreams' own title
        # matching needs a TMDB key, which this setup does not have.
        self.cinemeta = cinemeta
        # An AIOStreams variant of Viktor's config. "download" lifts the result
        # limits, which otherwise keep 3 files per resolution, mostly remuxes.
        self.variant = variant
        self.library = library or Library(None)
        self._encrypted = None
        self._lock = threading.Lock()

    def _encrypted_password(self, refresh: bool = False) -> str:
        with self._lock:
            if refresh or self._encrypted is None:
                data = self.get_json(f"{self.base}/api/v1/user", auth=(self.uuid, self.password))
                self._encrypted = data["data"]["encryptedPassword"]
            return self._encrypted

    def _upstream(self, kind: str, media_id: str, refresh: bool) -> list[dict]:
        enc = urllib.parse.quote(self._encrypted_password(refresh), safe="")
        sid = urllib.parse.quote(media_id, safe=":")
        variant = f"/v/{self.variant}" if self.variant else ""
        url = f"{self.base}/stremio/{self.uuid}/{enc}{variant}/stream/{kind}/{sid}.json"
        return self.get_json(url).get("streams", [])

    def meta(self, kind: str, media_id: str) -> dict:
        """The film's or show's Cinemeta entry; {} (no title check, release
        names kept) when Cinemeta fails."""
        if not self.cinemeta:
            return {}
        try:
            meta = self.get_json(f"{self.cinemeta}/meta/{kind}/{media_id.split(':')[0]}.json")
            return meta.get("meta") or {}
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            log(f"no title for {kind} {media_id}: {e!r}")
            return {}

    def streams(self, kind: str, media_id: str) -> dict:
        try:
            try:
                upstream = self._upstream(kind, media_id, refresh=False)
            except urllib.error.HTTPError as e:
                if e.code not in (401, 403):
                    raise
                upstream = self._upstream(kind, media_id, refresh=True)
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as e:
            log(f"no row for {kind} {media_id}: {e!r}")
            return {"streams": self.library.play_rows(media_id)}
        meta = self.meta(kind, media_id)
        title = meta.get("name")
        year = meta.get("year") or (meta.get("releaseInfo") or "")[:4] or None

        def name_for(stream: dict) -> str | None:
            if not title:
                return None
            name = clean_name(title, year, media_id, resolution_of(stream), filename_of(stream))
            self.library.remember(name, kind, media_id, title)
            # Files saved before links carried clean names keep the release name.
            if filename_of(stream):
                self.library.remember(filename_of(stream), kind, media_id, title)
            return name

        return {"streams": self.library.play_rows(media_id) + options(upstream, title, name_for)}


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def make_handler(addon: Addon, token: str):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            target = route(self.path, token)
            if target is None:
                self._send(404, {"error": "not found"})
            elif target[0] == "health":
                self._send(200, {"ok": True})
            elif target[0] == "manifest":
                self._send(200, MANIFEST)
            elif target[0] == "catalog":
                self._send(200, {"metas": addon.library.catalog(target[1])})
            elif target[0] == "stream":
                self._send(200, addon.streams(target[1], target[2]))
            else:
                self._send(405, {"error": "use POST"})

        def do_POST(self):
            if route(self.path, token) != ("inventory",):
                self._send(404, {"error": "not found"})
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self._send(413, {"error": "too large"})
                return
            try:
                addon.library.set_inventory(json.loads(self.rfile.read(length)))
            except ValueError as e:
                self._send(400, {"error": str(e)})
                return
            self._send(200, {"ok": True, "files": len(addon.library.inventory["files"])})

        def _send(self, code: int, body: dict):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass  # the token is in every path; keep it out of the logs

    return Handler


def main() -> None:
    addon = Addon(
        base=os.environ.get("AIOSTREAMS_BASE", "http://localhost:3000"),
        uuid=os.environ["AIOSTREAMS_UUID"],
        password=os.environ["AIOSTREAMS_PASSWORD"],
        variant=os.environ.get("AIOSTREAMS_VARIANT") or None,
        cinemeta=os.environ.get("CINEMETA_BASE") or None,
        library=Library(os.environ.get("DATA_DIR") or None),
    )
    ThreadingHTTPServer(("", PORT), make_handler(addon, os.environ["DOWNLOAD_ROW_TOKEN"])).serve_forever()


if __name__ == "__main__":
    main()
