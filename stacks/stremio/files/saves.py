"""Saved films and episodes for the "Our server" Stremio addon.

A viewer taps "Save this episode" (or "Save this film", or "Save the season
from here", a Follow) under a title in Stremio. The addon then keeps one copy
of a release ready to watch later: on Real-Debrid when it accepts the release,
otherwise on our server through qBittorrent. Words as in GLOSSARY.md, "Saved
films and episodes": Save, Follow, Saver, Copy, Watched. (A "Download" is the
London tablet's offline file, a different feature.)

Rows and the Continue Watching rule. Stremio core remembers the last row
tapped for a title and Continue Watching opens that row again (see the
docstring of stacks/servarr/aiostreams/files/download_row.py). So the Save row
and the Saved row of one video share one URL per account,
/<token>/a/<account>/v/<video id>. A tap on it records the save and plays a
short clip that says "Saved"; while the copy is on its way it plays a
"Saving" clip; once the copy is ready it plays the video itself. Remove save
and Try again have their own URLs, which act and then play a clip.

Copies. The release is picked from AIOStreams (Viktor's config; emo's saves
use its "sofia" variant, which puts Bulgarian audio first): 1080p first, then
2160p, 720p, 480p, the largest file up to 6 GB, and for emo a Bulgarian-audio
file first when there is one. A Real-Debrid cached row (a link, no info hash)
is a ready copy at once. A P2P row (an info hash) goes to Real-Debrid with
addMagnet and selectFiles; on HTTP 451 (infringing_file), an error, or no
progress for 2 hours, the Real-Debrid torrent is deleted and qBittorrent gets
the magnet (category stremio, ratio limit 1). A save with no copy is tried
again every 6 hours for 14 days, then shows "No copy found" and "Try again".

Follow. Cinemeta gives a season's episodes and air dates; an episode waits
until it airs, and its 14 days start on its air date. Cinemeta does not list
every season (it has no season 6 of Undercover), so a Follow also looks for
the next episode number after the last one found, and stops when 14 days pass
without it.

Watched and cleanup. An account has watched a copy when a request through its
/a/<account>/ URL delivered bytes past 90% of the file. Requests that start in
the last 2% do not count: players read the index at the end of a file when
they open it. A server copy goes 7 days after every saver watched it, when its
last saver removes it, or when server copies pass 300 GB (copies that every
saver watched first, then the oldest). Real-Debrid copies are never deleted.

State is one SQLite file on a block volume (never NFS). Standard library only.
Tests: cd files && python3 -m unittest test_saves
"""
import datetime
import json
import os
import re
import sqlite3
import threading
import time
import traceback
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from base64 import b64encode
from dataclasses import dataclass
from typing import Callable, Protocol

DAY = 86400.0
RETRY_EVERY = 6 * 3600.0
ADVANCE_EVERY = 300.0
META_EVERY = 6 * 3600  # metadata (episode lists, air dates) is asked at most this often
GIVE_UP_AFTER = 14 * DAY
RD_STALL = 2 * 3600.0
KEEP_AFTER_WATCHED = 7 * DAY
SERVER_CAP = 300_000_000_000
WATCHED_AT = 0.9
INDEX_READ = 0.98
# A tap that records a save plays the "Saved" clip for this long, so a player
# reading the clip in several requests never gets the video halfway through.
FRESH = 120.0
RD_LINK_TTL = 3 * 3600.0
MAX_BYTES = 6_000_000_000
PREFERENCE = (1080, 2160, 720, 480)
QB_ROOT = "/downloads/stremio"  # qBittorrent's view of the folder this pod mounts at /media
QB_CATEGORY = "stremio"
AIO_PUBLIC_HOSTS = ("aiostreams-direct.viktorbarzin.me", "aiostreams.viktorbarzin.me")
POSTER = "https://images.metahub.space/poster/medium/{}/img"

VIDEO_EXT = (".mkv", ".mp4", ".avi", ".m4v")
EPISODE = re.compile(r"(?i)\bs(\d{1,2})[ ._-]?e(\d{1,3})\b")
IMDB = re.compile(r"^tt\d+$")
STREAM_ID = re.compile(r"^(tt\d+)(?::(\d+):(\d+))?$")
RES = re.compile(r"(?i)(2160|1080|720|480)p")
HASH = re.compile(r"^[0-9a-f]{40}$")
AUDIO = re.compile(r"🌎([^📝\n]*)")
CLIPS = ("saved", "saving", "no_copy", "removed", "season")

LABELS = {
    "en": {
        "addon": "Our server",
        "description": "Save films and episodes to watch later. Also plays files on our server.",
        "catalog": "Saved",
        "save_episode": "Save this episode",
        "save_film": "Save this film",
        "save_season": "Save the season from here",
        "saving": "Saving",
        "saving_pct": "Saving {pct}%",
        "waiting": "Saving when it comes out",
        "saved": "Saved",
        "no_copy": "No copy found",
        "try_again": "Try again",
        "remove": "Remove save",
    },
    "bg": {
        "addon": "Нашият сървър",
        "description": "Запази за по-късно филми и епизоди. Пуска и файлове от нашия сървър.",
        "catalog": "Запазени",
        "save_episode": "Запази този епизод",
        "save_film": "Запази този филм",
        "save_season": "Запази сезона оттук",
        "saving": "Запазва се",
        "saving_pct": "Запазва се {pct}%",
        "waiting": "Запазва се, когато излезе",
        "saved": "Запазено",
        "no_copy": "Няма намерено копие",
        "try_again": "Опитай пак",
        "remove": "Премахни",
    },
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS saves (
  account TEXT NOT NULL,
  video_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  follow INTEGER NOT NULL DEFAULT 0,  -- 1: made by a Follow
  probe INTEGER NOT NULL DEFAULT 0,   -- 1: a Follow looking for an episode Cinemeta does not list
  title TEXT,
  state TEXT NOT NULL DEFAULT 'wanted',  -- wanted | gave_up | removed
  created_at REAL NOT NULL,
  air_date REAL,
  window_start REAL,
  last_try REAL,
  PRIMARY KEY (account, video_id)
);
CREATE TABLE IF NOT EXISTS follows (
  account TEXT NOT NULL,
  imdb TEXT NOT NULL,
  season INTEGER NOT NULL,
  from_episode INTEGER NOT NULL,
  created_at REAL NOT NULL,
  ended INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account, imdb, season)
);
CREATE TABLE IF NOT EXISTS copies (
  id INTEGER PRIMARY KEY,
  video_id TEXT NOT NULL,
  place TEXT NOT NULL,       -- rd | server
  status TEXT NOT NULL,      -- adding (on Real-Debrid) | downloading (qBittorrent) | ready | deleted
  pref TEXT NOT NULL,        -- the audio preference it was picked for: original | Bulgarian
  release TEXT NOT NULL,     -- the release's file name
  release_key TEXT NOT NULL, -- info hash, or link:<name>:<size> for a cached row
  infohash TEXT,
  magnet TEXT,
  link TEXT,                 -- AIOStreams link of a cached row
  rd_id TEXT,
  path TEXT,                 -- server: path under /media/<imdb>; rd: the torrent's file link
  size INTEGER NOT NULL DEFAULT 0,
  progress REAL NOT NULL DEFAULT 0,
  flags TEXT NOT NULL DEFAULT '',
  created_at REAL NOT NULL,
  progress_at REAL NOT NULL,
  ready_at REAL
);
CREATE TABLE IF NOT EXISTS savers (
  copy_id INTEGER NOT NULL,
  account TEXT NOT NULL,
  at REAL NOT NULL,
  PRIMARY KEY (copy_id, account)
);
CREATE TABLE IF NOT EXISTS watched (
  copy_id INTEGER NOT NULL,
  account TEXT NOT NULL,
  at REAL NOT NULL,
  PRIMARY KEY (copy_id, account)
);
CREATE TABLE IF NOT EXISTS seeds (
  seed TEXT PRIMARY KEY,
  at REAL NOT NULL
);
"""


class Stop(Exception):
    """Real-Debrid answered 401, 403 or 429: stop this cycle, as the call budget says."""


class Refused(Exception):
    """Real-Debrid will not hold this release (HTTP 451, infringing_file)."""


class ServiceError(Exception):
    """Any other failed answer from Real-Debrid, qBittorrent or AIOStreams."""


class Fetch(Protocol):
    def __call__(
        self, method: str, url: str, form: dict[str, str] | None = None,
        headers: dict[str, str] | None = None, timeout: float = 60,
    ) -> tuple[int, bytes]: ...


class Headers(Protocol):
    def get(self, name: str, default: None = None) -> str | None: ...


class Upstream(Protocol):
    status: int
    headers: Headers

    def read(self, n: int = -1) -> bytes: ...
    def close(self) -> None: ...


Opener = Callable[[str, "str | None"], Upstream]


@dataclass(frozen=True)
class Account:
    name: str
    lang: str          # en | bg: the labels and clips
    prefer: str        # original | Bulgarian: the audio the pick puts first
    variant: str | None  # the AIOStreams variant of Viktor's config
    public_url: str    # the host this account's rows point at


@dataclass(frozen=True)
class Config:
    db_path: str
    root: str
    clips_dir: str
    accounts: dict[str, Account]
    aio_base: str
    aio_uuid: str
    aio_password: str
    rd_key: str
    qb_base: str
    cinemeta_base: str
    token: str = ""
    seed_follows: tuple[str, ...] = ()
    cap_bytes: int = SERVER_CAP
    # The AIOStreams variant that returns torrent rows (Viktor's main config
    # has none since 2026-11-24); asked on top of each account's own variant.
    torrent_variant: str | None = None


def http_fetch(method: str, url: str, form: dict[str, str] | None = None,
               headers: dict[str, str] | None = None, timeout: float = 60) -> tuple[int, bytes]:
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": "stremio-library", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def http_open(url: str, rng: str | None) -> Upstream:
    """The upstream video for the proxy; Range passes through, redirects are followed."""
    headers = {"User-Agent": "stremio-library"}
    if rng:
        headers["Range"] = rng
    try:
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30)
    except urllib.error.HTTPError as e:
        return e


# ---------------------------------------------------------------------------
# Files and picking (picking copied from stacks/servarr/aiostreams/files/download_row.py)


def episode_of(name: str) -> tuple[int, int] | None:
    m = EPISODE.search(name)
    return (int(m.group(1)), int(m.group(2))) if m else None


def videos(root: str, imdb: str) -> list[str]:
    """Finished video files under root/imdb, as paths relative to that folder.
    qBittorrent names an unfinished file "<name>.!qB", so it is never listed."""
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


def parse_video_id(vid: str) -> tuple[str, int, int] | tuple[str, None, None] | None:
    m = STREAM_ID.match(vid)
    if not m:
        return None
    if m.group(2) is None:
        return m.group(1), None, None
    return m.group(1), int(m.group(2)), int(m.group(3))


def parse_time(text: str | None) -> float | None:
    if not text:
        return None
    try:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def resolution_of(stream: dict) -> int | None:
    hints = stream.get("behaviorHints") or {}
    for text in (hints.get("bingeGroup"), stream.get("name"), hints.get("filename")):
        m = RES.search(text or "")
        if m:
            return int(m.group(1))
    return None


def size_of(stream: dict) -> int:
    return int((stream.get("behaviorHints") or {}).get("videoSize") or 0)


def filename_of(stream: dict) -> str:
    return (stream.get("behaviorHints") or {}).get("filename") or ""


def audio_languages(stream: dict) -> list[str]:
    m = AUDIO.search(stream.get("description") or "")
    return [x.strip() for x in m.group(1).split("|") if x.strip()] if m else []


def words(text: str) -> list[str]:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", text)


def title_matches(title: str, filename: str) -> bool:
    """The title's words appear in a row in the file name: mislabeled torrents
    carry another film's file. No file name: keep it."""
    want, have = words(title), words(filename)
    if not want or not have:
        return True
    n = len(want)
    return any(have[i : i + n] == want for i in range(len(have) - n + 1))


def candidates(streams: list[dict], title: str | None, vid: str, strict: bool = False) -> list[dict]:
    """Rows a copy can come from: P2P rows (an info hash) and Real-Debrid cached
    rows (a link, no ⏳), of known size, named after the title and, for an
    episode, after that episode. strict: the file name must carry SxxEyy."""
    parsed = parse_video_id(vid)
    want_ep = (parsed[1], parsed[2]) if parsed and parsed[1] is not None else None
    out = []
    for s in streams:
        if size_of(s) <= 0:
            continue
        infohash = (s.get("infoHash") or "").lower()
        if infohash:
            if not HASH.match(infohash):
                continue
        elif not s.get("url") or "⏳" in (s.get("name") or ""):
            continue
        name = filename_of(s)
        if title and not title_matches(title, name):
            continue
        if want_ep:
            ep = episode_of(name)
            if ep != want_ep and (ep is not None or strict):
                continue
        out.append(s)
    return out


def choose(streams: list[dict], prefer: str) -> dict | None:
    """1080p first, then 2160p, 720p, 480p: the largest file up to 6 GB; the
    smallest file when none fits. prefer "Bulgarian" picks among the
    Bulgarian-audio files when there are any."""
    pool = streams
    if prefer == "Bulgarian":
        pool = [s for s in streams if "Bulgarian" in audio_languages(s)] or streams
    for res in PREFERENCE:
        fitting = [s for s in pool if resolution_of(s) == res and size_of(s) <= MAX_BYTES]
        if fitting:
            return max(fitting, key=size_of)
    fitting = [s for s in pool if size_of(s) <= MAX_BYTES]
    if fitting:
        return max(fitting, key=size_of)
    return min(pool, key=size_of, default=None)


def release_key(stream: dict) -> str:
    infohash = (stream.get("infoHash") or "").lower()
    return infohash if infohash else f"link:{filename_of(stream)}:{size_of(stream)}"


def magnet_of(stream: dict) -> str:
    infohash = stream["infoHash"].lower()
    parts = [f"magnet:?xt=urn:btih:{infohash}", "dn=" + urllib.parse.quote(filename_of(stream) or infohash)]
    for source in stream.get("sources") or []:
        if source.startswith("tracker:"):
            parts.append("tr=" + urllib.parse.quote(source[len("tracker:"):], safe=""))
    return "&".join(parts)


def target_file(files: list[dict], release: str, vid: str, name_key: str, size_key: str) -> dict | None:
    """The file of a torrent that holds the copy: the release's file name, else
    the episode's SxxEyy, else (a film) the largest video file."""
    vids = [f for f in files if str(f.get(name_key, "")).lower().endswith(VIDEO_EXT)]
    for f in vids:
        if os.path.basename(str(f[name_key])) == release:
            return f
    parsed = parse_video_id(vid)
    if parsed and parsed[1] is not None:
        vids = [f for f in vids if episode_of(os.path.basename(str(f[name_key]))) == (parsed[1], parsed[2])]
    return max(vids, key=lambda f: int(f.get(size_key) or 0), default=None)


def manifest(account: Account) -> dict:
    labels = LABELS[account.lang]
    return {
        "id": "me.viktorbarzin.library",
        "version": "1.1.0",
        "name": labels["addon"],
        "description": labels["description"],
        "resources": ["catalog", "stream"],
        "types": ["movie", "series"],
        "idPrefixes": ["tt"],
        # One catalog, filed under "movie", holding films and shows alike (each
        # item keeps its own type): two catalogs would show an empty row.
        "catalogs": [{"type": "movie", "id": "saved", "name": labels["catalog"]}],
    }


# ---------------------------------------------------------------------------
# Services


class AioStreams:
    def __init__(self, base: str, uuid: str, password: str, fetch: Fetch):
        self.base, self.uuid, self.password, self.fetch = base.rstrip("/"), uuid, password, fetch
        self._encrypted: str | None = None

    def _encrypted_password(self, refresh: bool) -> str:
        if refresh or self._encrypted is None:
            auth = b64encode(f"{self.uuid}:{self.password}".encode()).decode()
            status, body = self.fetch("GET", f"{self.base}/api/v1/user", headers={"Authorization": f"Basic {auth}"}, timeout=30)
            if status != 200:
                raise ServiceError(f"AIOStreams user answered {status}")
            self._encrypted = json.loads(body)["data"]["encryptedPassword"]
        return self._encrypted

    def streams(self, kind: str, vid: str, variant: str | None) -> list[dict]:
        for refresh in (False, True):
            enc = urllib.parse.quote(self._encrypted_password(refresh), safe="")
            v = f"/v/{variant}" if variant else ""
            url = f"{self.base}/stremio/{self.uuid}/{enc}{v}/stream/{kind}/{urllib.parse.quote(vid, safe=':')}.json"
            status, body = self.fetch("GET", url, timeout=90)
            if status in (401, 403) and not refresh:
                continue
            if status != 200:
                raise ServiceError(f"AIOStreams streams answered {status}")
            return json.loads(body).get("streams") or []
        return []


class RealDebrid:
    BASE = "https://api.real-debrid.com/rest/1.0"

    def __init__(self, key: str, fetch: Fetch):
        self.key, self.fetch = key, fetch
        self.lock = threading.Lock()  # one request at a time

    def call(self, method: str, path: str, form: dict[str, str] | None = None) -> dict:
        data = self.request(method, path, form)
        return data if isinstance(data, dict) else {}

    def downloads(self) -> list[dict]:
        """Links unrestricted under this account, newest first (AIOStreams' plays too)."""
        data = self.request("GET", "/downloads?limit=100")
        return [d for d in data if isinstance(d, dict)] if isinstance(data, list) else []

    def request(self, method: str, path: str, form: dict[str, str] | None = None) -> dict | list:
        endpoint = re.sub(r"/[A-Z0-9]{6,}$", "/<id>", path.split("?")[0])
        if not self.key:
            raise Stop("no Real-Debrid key")
        with self.lock:
            status, body = self.fetch(method, self.BASE + path, form=form, headers={"Authorization": f"Bearer {self.key}"}, timeout=60)
        if status in (401, 403, 429):
            raise Stop(f"Real-Debrid {method} {endpoint} answered {status}")
        try:
            data = json.loads(body) if body else {}
        except ValueError:
            data = {}
        error = data.get("error") if isinstance(data, dict) else None
        if status == 451 or error == "infringing_file":
            raise Refused(f"Real-Debrid {method} {endpoint}: infringing_file")
        if status >= 400:
            raise ServiceError(f"Real-Debrid {method} {endpoint} answered {status} {error}")
        return data if isinstance(data, (dict, list)) else {}

    def add_magnet(self, magnet: str) -> str:
        return str(self.call("POST", "/torrents/addMagnet", {"magnet": magnet})["id"])

    def select(self, rd_id: str, ids: list[int]) -> None:
        self.call("POST", f"/torrents/selectFiles/{rd_id}", {"files": ",".join(str(i) for i in ids) or "all"})

    def info(self, rd_id: str) -> dict:
        return self.call("GET", f"/torrents/info/{rd_id}")

    def delete(self, rd_id: str) -> None:
        self.call("DELETE", f"/torrents/delete/{rd_id}")

    def unrestrict(self, link: str) -> str:
        return str(self.call("POST", "/unrestrict/link", {"link": link})["download"])


class QBittorrent:
    """qBittorrent's Web API. It needs no login from pod IPs (AuthSubnetWhitelist 10.0.0.0/8)."""

    def __init__(self, base: str, fetch: Fetch):
        self.base, self.fetch = base.rstrip("/"), fetch

    def _get(self, path: str, params: dict[str, str]) -> list | dict:
        status, body = self.fetch("GET", f"{self.base}/{path}?{urllib.parse.urlencode(params)}", timeout=30)
        if status != 200:
            raise ServiceError(f"qBittorrent {path} answered {status}")
        return json.loads(body)

    def _post(self, path: str, form: dict[str, str]) -> tuple[int, bytes]:
        status, body = self.fetch("POST", f"{self.base}/{path}", form=form, timeout=30)
        if status not in (200, 409):
            raise ServiceError(f"qBittorrent {path} answered {status}")
        return status, body

    def add(self, magnet: str, imdb: str) -> None:
        # qBittorrent creates the folder itself; one we created as root would break it.
        status, body = self._post("torrents/add", {"urls": magnet, "category": QB_CATEGORY, "savepath": f"{QB_ROOT}/{imdb}"})
        if status == 200 and body.strip() == b"Fails.":
            raise ServiceError("qBittorrent refused the magnet")

    def listing(self) -> list[dict]:
        rows = self._get("torrents/info", {"category": QB_CATEGORY})
        return rows if isinstance(rows, list) else []

    def find(self, infohash: str) -> dict | None:
        """qBittorrent 5 keys a hybrid (v1+v2) torrent by its v2 hash, so a miss
        by hash falls back to the category listing's infohash_v1."""
        rows = self._get("torrents/info", {"hashes": infohash})
        if isinstance(rows, list) and rows:
            return rows[0]
        for t in self.listing():
            if infohash in (t.get("hash"), t.get("infohash_v1")):
                return t
        return None

    def files(self, qid: str) -> list[dict]:
        rows = self._get("torrents/files", {"hash": qid})
        return rows if isinstance(rows, list) else []

    def share_limits(self, qid: str) -> None:
        # qBittorrent 5.x (WebAPI 2.16) answers 400 without shareLimitAction and
        # shareLimitsMode (seen 2026-11-24).
        self._post("torrents/setShareLimits", {
            "hashes": qid, "ratioLimit": "1", "seedingTimeLimit": "-2", "inactiveSeedingTimeLimit": "-2",
            "shareLimitAction": "Stop", "shareLimitsMode": "Custom",
        })

    def priority(self, qid: str, ids: list[int], priority: int) -> None:
        self._post("torrents/filePrio", {"hash": qid, "id": "|".join(str(i) for i in ids), "priority": str(priority)})

    def delete(self, qid: str) -> None:
        # The pod mounts the files read-only; qBittorrent deletes them.
        self._post("torrents/delete", {"hashes": qid, "deleteFiles": "true"})


# ---------------------------------------------------------------------------
# The saves


class Saves:
    def __init__(self, cfg: Config, fetch: Fetch = http_fetch, opener: Opener = http_open,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] | None = None):
        self.cfg = cfg
        self._metas: dict[tuple[str, str], tuple[float, dict]] = {}
        self.root = cfg.root
        self.token = cfg.token
        self.accounts = cfg.accounts
        self.fetch, self.opener, self.clock = fetch, opener, clock
        self.log = log or (lambda m: print(f"saves: {m}", flush=True))
        self.aio = AioStreams(cfg.aio_base, cfg.aio_uuid, cfg.aio_password, fetch)
        self.rd = RealDebrid(cfg.rd_key, fetch)
        self.qb = QBittorrent(cfg.qb_base, fetch)
        self.db = sqlite3.connect(cfg.db_path, check_same_thread=False, isolation_level=None, timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.lock = threading.RLock()
        self.wake = threading.Event()
        self._links: dict[int, tuple[str, float]] = {}
        self._thread: threading.Thread | None = None

    # -- database helpers ---------------------------------------------------

    def q(self, sql: str, args: tuple = ()) -> list[dict]:
        with self.lock:
            return [dict(r) for r in self.db.execute(sql, args).fetchall()]

    def one(self, sql: str, args: tuple = ()) -> dict | None:
        rows = self.q(sql, args)
        return rows[0] if rows else None

    def x(self, sql: str, args: tuple = ()) -> int:
        with self.lock:
            return self.db.execute(sql, args).lastrowid or 0

    def close(self) -> None:
        with self.lock:
            self.db.close()

    def save_of(self, account: str, vid: str) -> dict | None:
        return self.one("SELECT * FROM saves WHERE account=? AND video_id=?", (account, vid))

    def copy_of(self, account: str, vid: str) -> dict | None:
        return self.one(
            "SELECT c.* FROM copies c JOIN savers s ON s.copy_id=c.id "
            "WHERE s.account=? AND c.video_id=? AND c.status!='deleted' ORDER BY c.id DESC LIMIT 1",
            (account, vid),
        )

    def savers_of(self, copy_id: int) -> list[str]:
        return [r["account"] for r in self.q("SELECT account FROM savers WHERE copy_id=?", (copy_id,))]

    def watched(self, account: str, copy_id: int) -> bool:
        return self.one("SELECT 1 AS w FROM watched WHERE copy_id=? AND account=?", (copy_id, account)) is not None

    def count_copies(self) -> int:
        row = self.one("SELECT COUNT(*) AS n FROM copies WHERE status!='deleted'")
        return int(row["n"]) if row else 0

    def attach(self, copy_id: int, account: str) -> None:
        self.x("INSERT OR IGNORE INTO savers (copy_id, account, at) VALUES (?, ?, ?)", (copy_id, account, self.clock()))

    def put_save(self, account: str, vid: str, now: float, follow: int = 0, probe: int = 0, air: float | None = None) -> None:
        """Record a save, or bring back a removed one."""
        kind = "series" if ":" in vid else "movie"
        start = max(now, air) if air else now
        self.x(
            "INSERT INTO saves (account, video_id, kind, follow, probe, state, created_at, air_date, window_start) "
            "VALUES (?, ?, ?, ?, ?, 'wanted', ?, ?, ?) "
            "ON CONFLICT (account, video_id) DO UPDATE SET state='wanted', created_at=excluded.created_at, "
            "window_start=excluded.window_start, last_try=NULL, probe=excluded.probe, follow=MAX(follow, excluded.follow)",
            (account, vid, kind, follow, probe, now, air, start),
        )

    # -- what a tap does ----------------------------------------------------

    def clip_path(self, account: str, kind: str) -> str:
        return os.path.join(self.cfg.clips_dir, f"{kind}-{self.accounts[account].lang}.mp4")

    def tap(self, account: str, action: str, vid: str) -> tuple:
        """("clip", kind), ("server", full path, copy id) or ("rd", copy)."""
        now = self.clock()
        if action == "remove":
            self.remove(account, vid)
            return ("clip", "removed")
        if action == "retry":
            self.x(
                "UPDATE saves SET state='wanted', window_start=?, last_try=NULL WHERE account=? AND video_id=? AND state='gave_up'",
                (now, account, vid),
            )
            self.kick()
        if action == "follow" and self.start_follow(account, vid, now):
            self.kick()
            return ("clip", "season")
        save = self.save_of(account, vid)
        if save is None or save["state"] == "removed":
            self.put_save(account, vid, now)
            self.kick()
            return ("clip", "saved")
        if now - save["created_at"] < FRESH:
            return ("clip", "season" if action == "follow" else "saved")
        copy = self.copy_of(account, vid)
        if copy and copy["status"] == "ready":
            if copy["place"] == "server":
                return ("server", os.path.join(self.root, vid.split(":")[0], copy["path"]), copy["id"])
            return ("rd", copy)
        if save["state"] == "gave_up":
            return ("clip", "no_copy")
        return ("clip", "saving")

    def start_follow(self, account: str, vid: str, now: float) -> bool:
        """Follow the season from this episode on. True when it starts one."""
        parsed = parse_video_id(vid)
        if not parsed or parsed[1] is None:
            return False
        imdb, season, episode = parsed
        f = self.one("SELECT * FROM follows WHERE account=? AND imdb=? AND season=?", (account, imdb, season))
        started = False
        if f is None:
            self.x("INSERT INTO follows (account, imdb, season, from_episode, created_at) VALUES (?, ?, ?, ?, ?)", (account, imdb, season, episode, now))
            started = True
        elif f["ended"] or episode < f["from_episode"]:
            self.x(
                "UPDATE follows SET ended=0, from_episode=MIN(from_episode, ?) WHERE account=? AND imdb=? AND season=?",
                (episode, account, imdb, season),
            )
            started = True
        save = self.save_of(account, vid)
        if save is None or save["state"] == "removed":
            self.put_save(account, vid, now, follow=1)
        return started

    def remove(self, account: str, vid: str) -> None:
        self.x("UPDATE saves SET state='removed' WHERE account=? AND video_id=?", (account, vid))
        copy = self.copy_of(account, vid)
        if copy is None:
            return
        self.x("DELETE FROM savers WHERE copy_id=? AND account=?", (copy["id"], account))
        if self.savers_of(copy["id"]) or copy["place"] != "server":
            return  # another saver keeps it; a Real-Debrid copy stays
        try:
            self.delete_server(copy, "its last saver removed it")
        except (OSError, ValueError, ServiceError) as e:
            self.log(f"could not delete {copy['release']} now ({e}); the next cycle tries again")

    # -- rows -----------------------------------------------------------------

    def rows(self, account: str, kind: str, vid: str) -> list[dict]:
        acct = self.accounts[account]
        labels = LABELS[acct.lang]
        parsed = parse_video_id(vid)
        if not parsed or (kind == "series") != (parsed[1] is not None):
            return []
        base = f"{acct.public_url}/{self.token}/a/{account}"
        tap = f"{base}/v/{vid}"

        def row(label: str, url: str, detail: str = "", hints: dict | None = None, res: int | None = None) -> dict:
            r = {
                "name": labels["addon"] + (f"\n{res}p" if res else ""),
                "title": label + (f"\n{detail}" if detail else ""),
                "url": url,
            }
            if hints:
                r["behaviorHints"] = hints
            return r

        save = self.save_of(account, vid)
        if save is None or save["state"] == "removed":
            if kind == "movie":
                return [row(labels["save_film"], tap)]
            return [row(labels["save_episode"], tap), row(labels["save_season"], f"{base}/follow/{vid}")]
        remove = row(labels["remove"], f"{base}/remove/{vid}")
        if save["state"] == "gave_up":
            return [row(labels["no_copy"], tap), row(labels["try_again"], f"{base}/retry/{vid}"), remove]
        copy = self.copy_of(account, vid)
        if copy and copy["status"] == "ready":
            size = f"💾 {copy['size'] / 1e9:.2f} GB" if copy["size"] else ""
            hints = {"filename": copy["release"], "bingeGroup": f"me.viktorbarzin.library.saved.{account}"}
            if copy["size"]:
                hints["videoSize"] = copy["size"]
            m = RES.search(copy["release"])
            detail = "\n".join(x for x in (copy["release"], size) if x)
            return [row(labels["saved"], tap, detail, hints, int(m.group(1)) if m else None), remove]
        if copy:
            label = labels["saving_pct"].format(pct=int(copy["progress"]))
            return [row(label, tap, copy["release"]), remove]
        now = self.clock()
        waiting = (save["air_date"] and save["air_date"] > now) or save["probe"]
        return [row(labels["waiting"] if waiting else labels["saving"], tap), remove]

    def catalog(self, account: str) -> list[dict]:
        rows = self.q(
            "SELECT substr(video_id, 1, instr(video_id || ':', ':') - 1) AS imdb, MAX(kind) AS kind, "
            "MAX(title) AS title, MAX(created_at) AS at FROM saves WHERE account=? AND state!='removed' "
            "GROUP BY imdb ORDER BY at DESC",
            (account,),
        )
        return [{"id": r["imdb"], "type": r["kind"], "name": r["title"] or r["imdb"], "poster": POSTER.format(r["imdb"])} for r in rows]

    def saved_paths(self, account: str, imdb: str) -> set[str]:
        """Server files this account sees as Saved rows, so the plain file rows skip them."""
        rows = self.q(
            "SELECT c.path FROM copies c JOIN savers s ON s.copy_id=c.id JOIN saves v ON v.account=s.account AND v.video_id=c.video_id "
            "WHERE s.account=? AND c.place='server' AND c.status='ready' AND v.state!='removed' AND (c.video_id=? OR c.video_id LIKE ?)",
            (account, imdb, imdb + ":%"),
        )
        return {r["path"] for r in rows}

    def server_copy_at(self, imdb: str, rel: str) -> int | None:
        row = self.one(
            "SELECT id FROM copies WHERE place='server' AND status='ready' AND path=? AND (video_id=? OR video_id LIKE ?)",
            (rel, imdb, imdb + ":%"),
        )
        return int(row["id"]) if row else None

    # -- watched --------------------------------------------------------------

    def delivered(self, account: str, copy_id: int, start: int, end: int, size: int) -> None:
        """A request through this account's URL sent bytes [start, end) of a file of size bytes."""
        if size > 0 and end > WATCHED_AT * size and start < INDEX_READ * size:
            self.x("INSERT OR IGNORE INTO watched (copy_id, account, at) VALUES (?, ?, ?)", (copy_id, account, self.clock()))

    # -- playback through Real-Debrid -----------------------------------------

    def upstream_url(self, copy: dict) -> str:
        """Where the proxy fetches a Real-Debrid copy from, inside Sofia."""
        if copy["link"]:
            parts = urllib.parse.urlsplit(copy["link"])
            if parts.hostname in AIO_PUBLIC_HOSTS:
                return self.cfg.aio_base.rstrip("/") + parts.path + (f"?{parts.query}" if parts.query else "")
            return copy["link"]
        now = self.clock()
        cached_link = self._links.get(copy["id"])
        if cached_link and cached_link[1] > now:
            return cached_link[0]
        url = self.rd.unrestrict(copy["path"])
        self._links[copy["id"]] = (url, now + RD_LINK_TTL)
        return url

    def refused_at_play(self, copy: dict) -> None:
        """Real-Debrid refused a ready copy when it was played: move it to our server."""
        self.log(f"Real-Debrid refused {copy['release']} at play; moving it to our server")
        self._links.pop(copy["id"], None)
        try:
            self.to_server(copy, self.clock())
        except (OSError, ValueError, ServiceError) as e:
            self.log(f"qBittorrent did not take {copy['release']}: {e}")

    # -- the background cycle -------------------------------------------------

    def kick(self) -> None:
        self.wake.set()

    def start(self) -> None:
        def loop() -> None:
            while True:
                try:
                    self.run_cycle()
                except Exception:  # keep the worker alive; the next cycle tries again
                    self.log("cycle failed:\n" + traceback.format_exc())
                self.wake.wait(ADVANCE_EVERY)
                self.wake.clear()

        self._thread = threading.Thread(target=loop, name="saves", daemon=True)
        self._thread.start()

    def run_cycle(self) -> None:
        now = self.clock()
        try:
            self.adopt(now)
            self.apply_seeds(now)
            for _ in range(60):  # a follow walks through episodes it finds ready
                changed = self.expand_follows(now)
                changed = self.work_saves(now) or changed
                if not changed:
                    break
            self.advance_copies(now)
            self.cleanup(now)
        except Stop as e:
            self.log(f"stopped this cycle: {e}")

    def meta(self, kind: str, imdb: str) -> dict:
        """A title's metadata, asked at most every META_EVERY: the source is a
        public addon, and follows look at it on every cycle."""
        key = (kind, imdb)
        now = self.clock()
        cached = self._metas.get(key)
        if cached is not None and now - cached[0] < META_EVERY:
            return cached[1]
        try:
            status, body = self.fetch("GET", f"{self.cfg.cinemeta_base.rstrip('/')}/meta/{kind}/{imdb}.json", timeout=30)
            meta = (json.loads(body).get("meta") or {}) if status == 200 else {}
        except (OSError, ValueError) as e:
            self.log(f"no metadata for {kind} {imdb}: {e!r}")
            meta = {}
        self._metas[key] = (now, meta)
        return meta

    def adopt(self, now: float) -> None:
        """Files already under /media/<imdb id>/ become server copies, once each."""
        if not os.path.isdir(self.root):
            return
        known = {f"{r['video_id'].split(':')[0]}/{r['path']}" for r in self.q("SELECT video_id, path FROM copies WHERE place='server' AND path IS NOT NULL")}
        busy = {r["video_id"] for r in self.q("SELECT video_id FROM copies WHERE place='server' AND status='downloading'")}
        torrents: list[dict] | None = None
        for imdb in sorted(os.listdir(self.root)):
            for rel in videos(self.root, imdb):
                if f"{imdb}/{rel}" in known:
                    continue
                ep = episode_of(os.path.basename(rel))
                vid = f"{imdb}:{ep[0]}:{ep[1]}" if ep else imdb
                if vid in busy:
                    continue
                if torrents is None:
                    try:
                        torrents = self.qb.listing()
                    except (OSError, ValueError, ServiceError) as e:
                        self.log(f"qBittorrent listing failed, adopting without hashes: {e}")
                        torrents = []
                full = f"{QB_ROOT}/{imdb}/{rel}"
                infohash = next(
                    (t.get("infohash_v1") or t.get("hash") for t in torrents
                     if full == t.get("content_path") or full.startswith(str(t.get("content_path")) + "/")),
                    None,
                )
                path = os.path.join(self.root, imdb, rel)
                st = os.stat(path)
                self.x(
                    "INSERT INTO copies (video_id, place, status, pref, release, release_key, infohash, path, size, progress, created_at, progress_at, ready_at) "
                    "VALUES (?, 'server', 'ready', 'original', ?, ?, ?, ?, ?, 100, ?, ?, ?)",
                    (vid, os.path.basename(rel), infohash or f"file:{imdb}/{rel}", infohash, rel, st.st_size, st.st_mtime, now, now),
                )
                if infohash:
                    try:
                        self.qb.share_limits(infohash)
                    except (OSError, ValueError, ServiceError) as e:
                        self.log(f"could not set ratio 1 on {imdb}/{rel}: {e}")
                self.log(f"adopted {imdb}/{rel}")

    def apply_seeds(self, now: float) -> None:
        """One-time follows from the Terraform (SEED_FOLLOWS), each applied once."""
        for seed in self.cfg.seed_follows:
            if self.one("SELECT 1 AS s FROM seeds WHERE seed=?", (seed,)):
                continue
            account, _, vid = seed.partition(":")
            if account not in self.accounts or not parse_video_id(vid) or ":" not in vid:
                self.log(f"seed {seed!r} is not account:tt…:season:episode; skipped")
                continue
            self.start_follow(account, vid, now)
            self.x("INSERT INTO seeds (seed, at) VALUES (?, ?)", (seed, now))
            self.log(f"seed: {account} follows {vid}")

    def expand_follows(self, now: float) -> bool:
        """Saves for a followed season's episodes. True when it adds one."""
        added = False
        for f in self.q("SELECT * FROM follows"):
            account, imdb, season, first = f["account"], f["imdb"], f["season"], f["from_episode"]
            listed: dict[int, float | None] = {}
            for v in self.meta("series", imdb).get("videos") or []:
                if v.get("season") == season and isinstance(v.get("episode"), int) and v["episode"] >= first:
                    listed[v["episode"]] = parse_time(v.get("released"))
            have = {
                int(r["video_id"].rsplit(":", 1)[1]): r
                for r in self.q("SELECT * FROM saves WHERE account=? AND video_id LIKE ?", (account, f"{imdb}:{season}:%"))
            }
            for ep, air in sorted(listed.items()):
                if ep not in have:
                    self.put_save(account, f"{imdb}:{season}:{ep}", now, follow=1, air=air)
                    added = True
            if f["ended"] or any(air is None or air > now for air in listed.values()):
                continue
            # Look for the episode after the last one, which Cinemeta may not list.
            eps = [e for e in set(listed) | set(have) if e >= first]
            last = max(eps, default=first - 1)
            if last >= first:
                prev = self.save_of(account, f"{imdb}:{season}:{last}")
                done = prev is not None and (prev["state"] != "wanted" or self.copy_of(account, prev["video_id"]) is not None)
                if not done:
                    continue
            nxt = f"{imdb}:{season}:{last + 1}"
            if self.save_of(account, nxt) is None:
                self.put_save(account, nxt, now, follow=1, probe=1 if last >= first else 0)
                added = True
        return added

    def work_saves(self, now: float) -> bool:
        """Find copies for saves that have none. True when a save got one."""
        got = False
        for save in self.q("SELECT * FROM saves WHERE state='wanted' ORDER BY created_at, rowid"):
            account, vid = save["account"], save["video_id"]
            acct = self.accounts.get(account)
            if acct is None or self.copy_of(account, vid):
                continue
            imdb = vid.split(":")[0]
            meta = self.meta(save["kind"], imdb)
            title = meta.get("name") or save["title"]
            if title and title != save["title"]:
                self.x("UPDATE saves SET title=? WHERE account=? AND video_id=?", (title, account, vid))
            air = save["air_date"]
            if save["kind"] == "series":
                for v in meta.get("videos") or []:
                    if v.get("id") == vid or (f"{imdb}:{v.get('season')}:{v.get('episode')}" == vid):
                        listed_air = parse_time(v.get("released"))
                        if listed_air and listed_air != air:
                            air = listed_air
                            self.x(
                                "UPDATE saves SET air_date=?, window_start=MAX(created_at, ?), probe=0 WHERE account=? AND video_id=?",
                                (air, air, account, vid),
                            )
                            save["window_start"] = max(save["created_at"], air)
                            save["probe"] = 0
            if air and now < air:
                continue
            if now >= (save["window_start"] or save["created_at"]) + GIVE_UP_AFTER:
                if save["probe"]:
                    # The episode never came: the season has ended.
                    self.x("DELETE FROM saves WHERE account=? AND video_id=?", (account, vid))
                    parsed = parse_video_id(vid)
                    if parsed:
                        self.x("UPDATE follows SET ended=1 WHERE account=? AND imdb=? AND season=?", (account, imdb, parsed[1]))
                    self.log(f"{account}'s follow of {vid.rsplit(':', 1)[0]} ended: no episode {vid.rsplit(':', 1)[1]} in 14 days")
                else:
                    self.x("UPDATE saves SET state='gave_up' WHERE account=? AND video_id=?", (account, vid))
                    self.log(f"no copy of {vid} for {account} in 14 days")
                continue
            if save["last_try"] and now - save["last_try"] < RETRY_EVERY:
                continue
            self.x("UPDATE saves SET last_try=? WHERE account=? AND video_id=?", (now, account, vid))
            same = self.one("SELECT * FROM copies WHERE video_id=? AND pref=? AND status!='deleted' ORDER BY id LIMIT 1", (vid, acct.prefer))
            if same:
                self.attach(same["id"], account)
                got = True
                continue
            try:
                streams = self.aio.streams(save["kind"], vid, acct.variant)
                tv = self.cfg.torrent_variant
                if tv and tv != acct.variant:
                    streams = streams + self.aio.streams(save["kind"], vid, tv)
            except (OSError, ValueError, KeyError, ServiceError) as e:
                self.log(f"AIOStreams failed for {vid}: {e!r}")
                continue
            pick = choose(candidates(streams, title, vid, strict=bool(save["follow"])), acct.prefer)
            if pick is None:
                continue
            key = release_key(pick)
            existing = self.one("SELECT * FROM copies WHERE video_id=? AND release_key=? AND status!='deleted'", (vid, key))
            if existing:
                self.attach(existing["id"], account)
            else:
                self.place(account, vid, pick, acct, now)
            got = True
        return got

    def place(self, account: str, vid: str, pick: dict, acct: Account, now: float) -> None:
        infohash = (pick.get("infoHash") or "").lower() or None
        copy_id = self.x(
            "INSERT INTO copies (video_id, place, status, pref, release, release_key, infohash, magnet, link, size, created_at, progress_at, ready_at) "
            "VALUES (?, 'rd', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (vid, "adding" if infohash else "ready", acct.prefer, filename_of(pick), release_key(pick), infohash,
             magnet_of(pick) if infohash else None, None if infohash else pick.get("url"), size_of(pick), now, now,
             None if infohash else now),
        )
        self.attach(copy_id, account)
        self.log(f"{account} saves {vid}: {filename_of(pick)}" + (" (Real-Debrid cached)" if not infohash else ""))
        if infohash:
            copy = self.one("SELECT * FROM copies WHERE id=?", (copy_id,))
            if copy:
                self.add_to_rd(copy, now)

    def add_to_rd(self, copy: dict, now: float) -> None:
        try:
            rd_id = self.rd.add_magnet(copy["magnet"])
        except Refused:
            self.log(f"Real-Debrid refuses {copy['release']}; qBittorrent gets it")
            self.to_server(copy, now)
            return
        self.x("UPDATE copies SET rd_id=?, progress_at=? WHERE id=?", (rd_id, now, copy["id"]))

    def to_server(self, copy: dict, now: float) -> None:
        if copy["rd_id"]:
            try:
                self.rd.delete(copy["rd_id"])
            except (Refused, ServiceError, OSError) as e:
                self.log(f"Real-Debrid delete of {copy['rd_id']} failed: {e}")
        if not copy["infohash"]:
            # A cached row has no info hash to give qBittorrent: look again.
            self.x("UPDATE copies SET status='deleted' WHERE id=?", (copy["id"],))
            for account in self.savers_of(copy["id"]):
                self.x("UPDATE saves SET last_try=NULL WHERE account=? AND video_id=? AND state='wanted'", (account, copy["video_id"]))
            return
        self.x(
            "UPDATE copies SET place='server', status='downloading', rd_id=NULL, path=NULL, progress=0, progress_at=?, ready_at=NULL WHERE id=?",
            (now, copy["id"]),
        )
        self.qb.add(copy["magnet"], copy["video_id"].split(":")[0])

    def advance_copies(self, now: float) -> None:
        for copy in self.q("SELECT * FROM copies WHERE status IN ('adding', 'downloading') ORDER BY id"):
            if not self.savers_of(copy["id"]):
                continue
            try:
                if copy["status"] == "adding":
                    self.advance_rd(copy, now)
                else:
                    self.advance_qb(copy, now)
            except (OSError, ValueError, KeyError, ServiceError) as e:
                self.log(f"could not advance {copy['release']}: {e!r}")

    def advance_rd(self, copy: dict, now: float) -> None:
        if not copy["rd_id"]:
            if now - copy["progress_at"] >= RD_STALL:
                self.to_server(copy, now)
            else:
                self.add_to_rd(copy, now)
            return
        try:
            info = self.rd.info(copy["rd_id"])
            status = info.get("status")
            files = info.get("files") or []
            if status == "waiting_files_selection":
                target = target_file(files, copy["release"], copy["video_id"], "path", "bytes")
                ids = [int(target["id"])] if target else [int(f["id"]) for f in files if str(f.get("path", "")).lower().endswith(VIDEO_EXT)]
                self.rd.select(copy["rd_id"], ids)
                return
        except Refused:
            self.log(f"Real-Debrid refuses {copy['release']}; qBittorrent gets it")
            self.to_server(copy, now)
            return
        if status == "downloaded":
            selected = [f for f in files if f.get("selected")]
            links = info.get("links") or []
            target = target_file(selected, copy["release"], copy["video_id"], "path", "bytes")
            if target is None or len(links) != len(selected):
                link = links[0] if len(links) == 1 else None
            else:
                link = links[selected.index(target)]
            if link is None:
                self.log(f"Real-Debrid finished {copy['release']} but its file link is unclear; qBittorrent gets it")
                self.to_server(copy, now)
                return
            size = int(target["bytes"]) if target else copy["size"]
            self.x("UPDATE copies SET status='ready', path=?, size=?, progress=100, ready_at=? WHERE id=?", (link, size, now, copy["id"]))
            self.log(f"ready on Real-Debrid: {copy['release']}")
            return
        if status in ("magnet_error", "error", "virus", "dead"):
            self.log(f"Real-Debrid says {status} for {copy['release']}; qBittorrent gets it")
            self.to_server(copy, now)
            return
        progress = float(info.get("progress") or 0)
        if progress > copy["progress"]:
            self.x("UPDATE copies SET progress=?, progress_at=? WHERE id=?", (progress, now, copy["id"]))
        elif now - copy["progress_at"] >= RD_STALL:
            self.log(f"no progress on Real-Debrid for 2 hours ({info.get('seeders', 0)} seeders): {copy['release']}; qBittorrent gets it")
            self.to_server(copy, now)

    def advance_qb(self, copy: dict, now: float) -> None:
        imdb = copy["video_id"].split(":")[0]
        torrent = self.qb.find(copy["infohash"])
        if torrent is None:
            if now - copy["progress_at"] >= 600:
                self.qb.add(copy["magnet"], imdb)
                self.x("UPDATE copies SET progress_at=? WHERE id=?", (now, copy["id"]))
            return
        qid = str(torrent["hash"])
        if "share" not in copy["flags"]:
            self.qb.share_limits(qid)
            self.x("UPDATE copies SET flags=flags || ' share' WHERE id=?", (copy["id"],))
        files = self.qb.files(qid)
        target = target_file(files, copy["release"], copy["video_id"], "name", "size")
        if target is None:
            return
        path = str(target["name"])
        twin = self.one(
            "SELECT * FROM copies WHERE id!=? AND video_id=? AND path=? AND place='server' AND status!='deleted'",
            (copy["id"], copy["video_id"], path),
        )
        if twin:  # the same file under another copy (adopted before its hash was known)
            for account in self.savers_of(copy["id"]):
                self.attach(twin["id"], account)
            self.x("DELETE FROM savers WHERE copy_id=?", (copy["id"],))
            self.x("UPDATE copies SET status='deleted' WHERE id=?", (copy["id"],))
            return
        if len(files) > 1:
            # A season pack: fetch only the files our copies of it hold.
            keep = {path} | {r["path"] for r in self.q("SELECT path FROM copies WHERE infohash=? AND status!='deleted' AND path IS NOT NULL", (copy["infohash"],))}
            off = [int(f["index"]) for f in files if f["name"] not in keep and f.get("priority") != 0]
            on = [int(f["index"]) for f in files if f["name"] in keep and f.get("priority") == 0]
            if off:
                self.qb.priority(qid, off, 0)
            if on:
                self.qb.priority(qid, on, 1)
        progress = float(target.get("progress") or 0) * 100
        self.x(
            "UPDATE copies SET path=?, size=?, progress=?, progress_at=CASE WHEN ? > progress THEN ? ELSE progress_at END WHERE id=?",
            (path, int(target.get("size") or 0), progress, progress, now, copy["id"]),
        )
        if progress >= 100 and os.path.isfile(os.path.join(self.root, imdb, path)):
            self.x("UPDATE copies SET status='ready', ready_at=? WHERE id=?", (now, copy["id"]))
            self.log(f"ready on our server: {imdb}/{path}")

    # -- cleanup ----------------------------------------------------------------

    def fully_watched(self, copy_id: int) -> float | None:
        """When the last of its savers watched it; None while one has not."""
        savers = self.savers_of(copy_id)
        if not savers:
            return None
        times = [r["at"] for r in self.q("SELECT account, at FROM watched WHERE copy_id=?", (copy_id,)) if r["account"] in savers]
        return max(times) if len(times) == len(savers) else None

    def cleanup(self, now: float) -> None:
        """Server copies only: 7 days after every saver watched one, and the cap."""
        for copy in self.q("SELECT * FROM copies WHERE place='server' AND status='ready' ORDER BY id"):
            last = self.fully_watched(copy["id"])
            if last is not None and now >= last + KEEP_AFTER_WATCHED:
                self.try_delete(copy, "every saver watched it 7 days ago")
        live = self.q("SELECT * FROM copies WHERE place='server' AND status IN ('ready', 'downloading')")
        total = sum(c["size"] for c in live)
        if total <= self.cfg.cap_bytes:
            return
        ready = [c for c in live if c["status"] == "ready"]
        ready.sort(key=lambda c: (self.fully_watched(c["id"]) is None, c["created_at"], c["id"]))
        for copy in ready:
            if total <= self.cfg.cap_bytes:
                break
            if self.try_delete(copy, f"server copies over {self.cfg.cap_bytes / 1e9:.0f} GB"):
                total -= copy["size"]

    def try_delete(self, copy: dict, why: str) -> bool:
        try:
            return self.delete_server(copy, why)
        except (OSError, ValueError, ServiceError) as e:
            self.log(f"could not delete {copy['release']}: {e}")
            return False

    def delete_server(self, copy: dict, why: str) -> bool:
        imdb = copy["video_id"].split(":")[0]
        siblings = []
        if copy["infohash"]:
            siblings = self.q("SELECT id FROM copies WHERE infohash=? AND id!=? AND status!='deleted'", (copy["infohash"], copy["id"]))
        torrent = self.qb.find(copy["infohash"]) if copy["infohash"] else None
        if torrent is None and copy["path"]:
            full = f"{QB_ROOT}/{imdb}/{copy['path']}"
            torrent = next(
                (t for t in self.qb.listing() if full == t.get("content_path") or full.startswith(str(t.get("content_path")) + "/")),
                None,
            )
        if torrent is None:
            self.log(f"{imdb}/{copy['path']} is not in qBittorrent; its file stays on the share")
        elif torrent.get("category") != QB_CATEGORY:
            # Never touch another app's torrent (MAM farming, the arr apps).
            self.log(f"{imdb}/{copy['path']} belongs to qBittorrent category {torrent.get('category')!r}; kept")
            return False
        elif siblings:
            # Other copies use this torrent (a season pack): only stop fetching this file.
            files = self.qb.files(str(torrent["hash"]))
            ids = [int(f["index"]) for f in files if f["name"] == copy["path"]]
            if ids:
                self.qb.priority(str(torrent["hash"]), ids, 0)
        else:
            self.qb.delete(str(torrent["hash"]))
        for account in self.savers_of(copy["id"]):
            self.x("UPDATE saves SET state='removed' WHERE account=? AND video_id=?", (account, copy["video_id"]))
        self.x("DELETE FROM savers WHERE copy_id=?", (copy["id"],))
        self.x("UPDATE copies SET status='deleted' WHERE id=?", (copy["id"],))
        self.log(f"deleted {imdb}/{copy['path'] or copy['release']}: {why}")
        return True


def accounts_from_env(env: dict[str, str]) -> dict[str, Account]:
    viktor_url = env["PUBLIC_URL"].rstrip("/")
    return {
        "viktor": Account("viktor", "en", "original", env.get("AIOSTREAMS_VARIANT_VIKTOR") or None, viktor_url),
        "emo": Account("emo", "bg", "Bulgarian", env.get("AIOSTREAMS_VARIANT_EMO", "sofia") or None,
                       (env.get("PUBLIC_URL_EMO") or viktor_url).rstrip("/")),
    }


def config_from_env(env: dict[str, str], root: str, token: str) -> Config:
    data_dir = env.get("DATA_DIR", "/data")
    return Config(
        db_path=os.path.join(data_dir, "saves.db"),
        root=root,
        clips_dir=env.get("CLIPS_DIR", "/clips"),
        accounts=accounts_from_env(env),
        aio_base=env.get("AIOSTREAMS_BASE", "http://aiostreams.aiostreams.svc.cluster.local"),
        aio_uuid=env.get("AIOSTREAMS_UUID", ""),
        aio_password=env.get("AIOSTREAMS_PASSWORD", ""),
        rd_key=env.get("RD_API_KEY", ""),
        qb_base=env.get("QBITTORRENT_URL", "http://qbittorrent.servarr.svc.cluster.local/api/v2"),
        cinemeta_base=env.get("CINEMETA_BASE", "http://cinemeta-proxy.stremio.svc.cluster.local"),
        token=token,
        seed_follows=tuple(s.strip() for s in env.get("SEED_FOLLOWS", "").split(",") if s.strip()),
        torrent_variant=env.get("AIOSTREAMS_VARIANT_TORRENTS") or None,
    )
