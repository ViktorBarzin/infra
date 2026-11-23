"""A Stremio addon that adds "Download" rows to each film or episode.

The row opens one of AIOStreams' own links in the browser. The proxy sends
Content-Disposition: attachment, so the browser saves the file, and VLC plays
it offline (the London tablet, for flights). Stremio rows do one thing each
(play, or open a link), so the download cannot sit on the play row itself.

It asks AIOStreams on localhost for Viktor's streams and returns externalUrl
rows: a recommended file first, then a short ladder of other sizes per
resolution, each labelled with its resolution and size. Files whose name lacks
the film's title (from Cinemeta) are left out. Install URL: https://<host>/<token>/manifest.json.
The token is the only gate, as for AIOStreams' own install URLs.

Standard library only, so nothing is installed at start.
Tests: cd files && python3 -m unittest test_download_row
"""
import json
import os
import re
import sys
import threading
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

MANIFEST = {
    "id": "me.viktorbarzin.download",
    "version": "1.0.0",
    "name": "Download",
    "description": "One row per film or episode that saves a file for offline viewing.",
    "resources": ["stream"],
    "types": list(TYPES),
    "idPrefixes": ["tt"],
    "catalogs": [],
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


def row(stream: dict, recommended: bool = False) -> dict:
    tag = label(resolution_of(stream))
    size = f"{size_of(stream) / 1e9:.1f} GB"
    filename = (stream.get("behaviorHints") or {}).get("filename") or ""
    details = f"{tag} · {size}" if tag else size
    name = "Recommended" if recommended else tag or "Download"
    return {
        "name": f"⬇ {name}",
        "description": "\n".join(x for x in (details, filename) if x),
        "externalUrl": stream["url"],
    }


def options(streams: list[dict], title: str | None = None) -> list[dict]:
    """The recommended file first, then the ladder without it. With a title,
    files named after another title are left out."""
    if title:
        streams = [s for s in streams if title_matches(title, filename_of(s))]
    best = choose(streams)
    if best is None:
        return []
    rest = [s for s in ladder(streams) if s.get("url") != best.get("url")]
    return [row(best, recommended=True)] + [row(s) for s in rest]


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
        variant: str | None = None, cinemeta: str | None = None,
    ):
        self.base, self.uuid, self.password, self.get_json = base, uuid, password, get_json
        # Cinemeta, for the title the filenames must carry. AIOStreams' own title
        # matching needs a TMDB key, which this setup does not have.
        self.cinemeta = cinemeta
        # An AIOStreams variant of Viktor's config. "download" lifts the result
        # limits, which otherwise keep 3 files per resolution, mostly remuxes.
        self.variant = variant
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

    def title(self, kind: str, media_id: str) -> str | None:
        """The film's or show's name; None (no title check) when Cinemeta fails."""
        if not self.cinemeta:
            return None
        try:
            meta = self.get_json(f"{self.cinemeta}/meta/{kind}/{media_id.split(':')[0]}.json")
            return (meta.get("meta") or {}).get("name") or None
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            log(f"no title for {kind} {media_id}: {e!r}")
            return None

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
            return {"streams": []}
        return {"streams": options(upstream, self.title(kind, media_id))}


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
            else:
                self._send(200, addon.streams(target[1], target[2]))

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
    )
    ThreadingHTTPServer(("", PORT), make_handler(addon, os.environ["DOWNLOAD_ROW_TOKEN"])).serve_forever()


if __name__ == "__main__":
    main()
