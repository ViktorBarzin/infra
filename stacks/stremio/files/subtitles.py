"""English subtitles timed to the sound of the file that plays.

When Stremio opens a film or an episode it asks every subtitles addon for a
list, and sends the file's size and name. This addon answers with one track,
"English (synced)", whose link is /<token>/a/<account>/sub/<key>.srt:

1. The top English subtitle comes from OpenSubtitles v3 (strem.io), which puts
   subtitles made for this exact file first.
2. The addon finds the playing file by its size: a file on our server, or a
   file in the Real-Debrid downloads list. AIOStreams unrestricts a Real-Debrid
   link under our account when the player opens it, so the list holds it a
   moment later; the read leaves from Sofia, the address the video uses.
3. ffmpeg reads the first 10 minutes of sound, and ffsubsync moves every line
   to the speech it finds there (offset and frame rate).

The sync starts with the list and takes about 10 s; the link waits for it, up
to 30 s. A file the addon cannot find, or a sync that fails, gives the
original subtitle on the same link, so the track always plays. Each result is
kept on the data volume, so the next play needs no wait.

Streams from "P2P via Sofia" are out of scope: the addon cannot read them.
"""
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field

from saves import Fetch, RealDebrid, ServiceError, Stop, videos

OPENSUBTITLES = "https://opensubtitles-v3.strem.io"
SAMPLE_SECONDS = 600
WAIT_FOR_SYNC = 30.0
LIST_EVERY = 6 * 3600.0
RD_TRIES = 6       # Real-Debrid downloads list: polls for the playing file
RD_GAP = 3.0       # seconds between the polls
KEY = re.compile(r"^[0-9a-f]{16}$")
OFFSET = re.compile(r"offset seconds: (-?[\d.]+)")
SCALE = re.compile(r"framerate scale factor: ([\d.]+)")

Run = Callable[[list[str], float], tuple[int, str]]


def run_process(argv: list[str], timeout: float) -> tuple[int, str]:
    """Run a tool: its exit code and what it wrote (ffsubsync logs to stderr)."""
    try:
        done = subprocess.run(argv, timeout=timeout, stdin=subprocess.DEVNULL, capture_output=True, check=False)
    except (subprocess.TimeoutExpired, OSError) as e:
        return -1, repr(e)
    return done.returncode, (done.stdout + done.stderr).decode(errors="replace")


def parse_extra(text: str) -> dict[str, str]:
    """Stremio's extra path segment, "filename=a.mkv&videoSize=123"."""
    return {k: v for k, v in urllib.parse.parse_qsl(text, keep_blank_values=True)}


@dataclass
class Job:
    key: str
    vid: str
    size: int
    sub_url: str
    done: threading.Event = field(default_factory=threading.Event)
    original: bytes | None = None


class Subtitles:
    def __init__(self, cache_dir: str, root: str, rd: RealDebrid, fetch: Fetch, accounts: frozenset[str],
                 run: Run = run_process, sleep: Callable[[float], None] = time.sleep,
                 clock: Callable[[], float] = time.time, log: Callable[[str], None] | None = None,
                 ffmpeg: str = "ffmpeg", ffsubsync: str = "ffsubsync"):
        self.cache_dir, self.root, self.rd, self.fetch = cache_dir, root, rd, fetch
        self.accounts = accounts
        self.run, self.sleep, self.clock = run, sleep, clock
        self.log = log or (lambda m: print(f"subtitles: {m}", flush=True))
        self.ffmpeg, self.ffsubsync = ffmpeg, ffsubsync
        os.makedirs(cache_dir, exist_ok=True)
        self.lock = threading.Lock()
        self.cpu = threading.Semaphore(1)  # one sync at a time
        self.jobs: dict[str, Job] = {}
        self.lists: dict[str, tuple[float, list[dict]]] = {}
        self.rd_stopped = False

    # -- the two requests ---------------------------------------------------

    def listing(self, kind: str, vid: str, extra: dict[str, str], base: str) -> list[dict]:
        try:
            size = int(extra.get("videoSize") or 0)
        except ValueError:
            size = 0
        if size <= 0:
            return []  # without the size the addon cannot find the file
        source = self.source(kind, vid, extra)
        if source is None:
            return []
        key = hashlib.sha1(f"{vid}|{size}|{source['id']}".encode()).hexdigest()[:16]
        with self.lock:
            if key not in self.jobs:
                job = Job(key, vid, size, source["url"])
                self.jobs[key] = job
                if os.path.exists(self.synced_path(key)):
                    job.done.set()
                else:
                    threading.Thread(target=self.work, args=(job,), daemon=True).start()
        return [{"id": f"synced-{key}", "url": f"{base}/sub/{key}.srt", "lang": "eng", "label": "English (synced)"}]

    def file(self, key: str, wait: float = WAIT_FOR_SYNC) -> bytes | None:
        """The synced subtitle, or the original when there is no sync in time."""
        if not KEY.match(key):
            return None
        path = self.synced_path(key)
        job = self.jobs.get(key)
        if job is not None and not os.path.exists(path):
            job.done.wait(wait)
        if os.path.exists(path):
            with open(path, "rb") as f:
                return f.read()
        if job is None:
            return None
        return job.original if job.original is not None else self.download(job)

    # -- the sync -----------------------------------------------------------

    def synced_path(self, key: str) -> str:
        return os.path.join(self.cache_dir, f"{key}.srt")

    def source(self, kind: str, vid: str, extra: dict[str, str]) -> dict | None:
        """The first English subtitle OpenSubtitles lists for this file."""
        query = urllib.parse.urlencode({k: extra[k] for k in ("filename", "videoHash", "videoSize") if extra.get(k)})
        url = f"{OPENSUBTITLES}/subtitles/{kind}/{urllib.parse.quote(vid, safe=':')}" + (f"/{query}" if query else "") + ".json"
        now = self.clock()
        cached = self.lists.get(url)
        if cached and cached[0] > now:
            subs = cached[1]
        else:
            status, body = self.fetch("GET", url, timeout=20)
            if status != 200:
                self.log(f"OpenSubtitles answered {status} for {vid}")
                return None
            try:
                subs = [s for s in json.loads(body).get("subtitles") or [] if isinstance(s, dict)]
            except ValueError:
                return None
            self.lists[url] = (now + LIST_EVERY, subs)
        for s in subs:
            if s.get("lang") in ("eng", "en") and s.get("url"):
                return {"id": str(s.get("id") or s["url"]), "url": str(s["url"])}
        return None

    def download(self, job: Job) -> bytes | None:
        status, body = self.fetch("GET", job.sub_url, timeout=30)
        if status != 200 or not body:
            self.log(f"the subtitle for {job.vid} answered {status}")
            return None
        job.original = body
        return body

    def locate(self, vid: str, size: int) -> str | None:
        """A path on our server, or a Real-Debrid download link, for the file of this size."""
        imdb = vid.split(":")[0]
        for rel in videos(self.root, imdb):
            full = os.path.join(self.root, imdb, rel)
            if os.path.getsize(full) == size:
                return full
        for attempt in range(RD_TRIES):
            if self.rd_stopped:
                return None
            if attempt:
                self.sleep(RD_GAP)
            try:
                for d in self.rd.downloads():
                    if d.get("filesize") == size and d.get("download"):
                        return str(d["download"])
            except Stop as e:  # 401, 403 or 429: no more Real-Debrid calls until a restart
                self.rd_stopped = True
                self.log(f"stopped asking Real-Debrid: {e}")
                return None
            except (ServiceError, OSError) as e:
                self.log(f"Real-Debrid downloads list failed: {e}")
                return None
        return None

    def work(self, job: Job) -> None:
        try:
            self.sync(job)
        except Exception as e:  # a failed sync leaves the original on the link
            self.log(f"sync of {job.vid} failed: {e!r}")
        finally:
            job.done.set()

    def sync(self, job: Job) -> None:
        original = self.download(job)
        if original is None:
            return
        where = self.locate(job.vid, job.size)
        if where is None:
            self.log(f"no file of {job.size} bytes for {job.vid}; the original subtitle stays")
            return
        started = self.clock()
        with self.cpu, tempfile.TemporaryDirectory(dir=self.cache_dir) as tmp:
            wav, src, out = (os.path.join(tmp, n) for n in ("sound.wav", "in.srt", "out.srt"))
            with open(src, "wb") as f:
                f.write(original)
            code, text = self.run([self.ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-t", str(SAMPLE_SECONDS),
                                   "-i", where, "-vn", "-ac", "1", "-ar", "16000", wav], 90)
            if code != 0 or not os.path.exists(wav):
                self.log(f"ffmpeg could not read {job.vid} (exit {code}): {text[-300:]}")
                return
            code, text = self.run([self.ffsubsync, wav, "-i", src, "-o", out, "--output-encoding", "utf-8"], 90)
            if code != 0 or not os.path.exists(out):
                self.log(f"ffsubsync failed for {job.vid} (exit {code}): {text[-300:]}")
                return
            o, s = OFFSET.search(text), SCALE.search(text)
            note = f", offset {o.group(1)} s, speed {s.group(1)}" if o and s else ""
            os.replace(out, self.synced_path(job.key))
        self.log(f"synced {job.vid} in {self.clock() - started:.0f} s{note}")
