"""Serve Real-Debrid's blocked release names to AIOStreams as a synced regex list.

Since May 2026 Real-Debrid refuses (HTTP 451, infringing_file) files whose
names contain certain release tags, and it changes that list every few weeks.
Debrid Media Manager re-measures the list and keeps it as regex constants in
src/utils/deInfringe.ts. This sidecar fetches that file every REFRESH_SECONDS,
copies out the `const RD_BLOCKED_* = /.../flags;` literals, checks they cannot
hide ordinary release names, and serves them on :PORT/rd-blocked-names.json in
the shape AIOStreams' syncedExcludedRegexUrls reads: [{"name", "pattern"}].

A fetch or check that fails keeps the last good list, also saved to STATE_FILE
so a restart serves it at once. /metrics carries the last success time, read
by the RdBlockedNamesStale alert.

Python standard library only: no pip install at start (see the suspended
aiostreams-stream-probe CronJob for why).
"""
import json
import os
import re
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE_URL = os.environ.get(
    "SOURCE_URL",
    "https://raw.githubusercontent.com/debridmediamanager/debrid-media-manager/main/src/utils/deInfringe.ts",
)
STATE_FILE = os.environ.get("STATE_FILE", "/app/data/rd-blocked-names.json")
PORT = int(os.environ.get("PORT", "8081"))
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", str(6 * 3600)))

MAX_PATTERNS = 6
MAX_PATTERN_LENGTH = 300
MAX_SOURCE_BYTES = 1024 * 1024

# Names no blocked-name rule may match. A pattern that hides any of these would
# empty most of the stream list, so the whole update is refused.
CONTROL_NAMES = (
    "Movie.2024.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-GRP.mkv",
    "Movie.2024.2160p.UHD.BluRay.x265.10bit.HDR.DV-GRP.mkv",
    "Show.S01E01.1080p.WEB.H265-GRP.mkv",
    "Movie (2024) 720p x265 10bit.mp4",
)

# `const RD_BLOCKED_X =` then a JS regex literal, possibly on the next line.
_CONST_RE = re.compile(
    r"const\s+(RD_BLOCKED_\w+)\s*=\s*/((?:\\.|[^/\\\n])+)/([a-z]*)\s*;"
)


def extract_patterns(source: str) -> list[tuple[str, str]]:
    """Every RD_BLOCKED_* regex literal, as (constant name, "/source/flags")."""
    return [
        (name, f"/{body}/{flags}") for name, body, flags in _CONST_RE.findall(source)
    ]


def validate(patterns: list[tuple[str, str]]) -> list[re.Pattern[str]]:
    """Compiled patterns, or ValueError when the list is unsafe to apply."""
    if not patterns:
        raise ValueError("no RD_BLOCKED_* regex found in the source")
    if len(patterns) > MAX_PATTERNS:
        raise ValueError(f"{len(patterns)} patterns, more than {MAX_PATTERNS}")
    compiled = []
    for name, literal in patterns:
        if len(literal) > MAX_PATTERN_LENGTH:
            raise ValueError(f"{name} is {len(literal)} characters long")
        body, _, flags = literal[1:].rpartition("/")
        if set(flags) - {"i"}:
            raise ValueError(f"{name} has flags {flags!r}, only 'i' is expected")
        try:
            regex = re.compile(body, re.IGNORECASE if "i" in flags else 0)
        except re.error as e:
            raise ValueError(f"{name} does not compile: {e}") from e
        for control in CONTROL_NAMES:
            if regex.search(control):
                raise ValueError(f"{name} would hide the ordinary name {control!r}")
        compiled.append(regex)
    return compiled


def render(patterns: list[tuple[str, str]]) -> bytes:
    return json.dumps(
        [
            {"name": f"Real-Debrid blocked names ({name})", "pattern": literal}
            for name, literal in patterns
        ],
        indent=2,
    ).encode()


def fetch_source() -> str:
    req = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "rd-blocked-names"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read(MAX_SOURCE_BYTES).decode("utf-8")


class State:
    def __init__(self, state_file: str):
        self.state_file = state_file
        self.lock = threading.Lock()
        self.body: bytes | None = None
        self.patterns = 0
        self.last_success: float | None = None
        self.last_change: float | None = None
        self.failures = 0
        try:
            with open(state_file, "rb") as f:
                saved = f.read()
            self.patterns = len(json.loads(saved))
            self.body = saved
        except (OSError, ValueError):
            pass

    def refresh(self, fetch, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        try:
            patterns = extract_patterns(fetch())
            validate(patterns)
        except Exception as e:  # any failure keeps the last good list
            with self.lock:
                self.failures += 1
            log(f"refresh failed, keeping the last good list: {e}")
            return False
        body = render(patterns)
        with self.lock:
            if body != self.body or self.last_change is None:
                if body != self.body:
                    log(f"list changed: {[p for _, p in patterns]}")
                self.last_change = now
            self.body = body
            self.patterns = len(patterns)
            self.last_success = now
        try:
            tmp = self.state_file + ".tmp"
            with open(tmp, "wb") as f:
                f.write(body)
            os.replace(tmp, self.state_file)
        except OSError as e:
            log(f"could not save {self.state_file}: {e}")
        return True

    def metrics(self) -> str:
        with self.lock:
            lines = [
                "# TYPE rd_blocked_names_patterns gauge",
                f"rd_blocked_names_patterns {self.patterns}",
                "# TYPE rd_blocked_names_refresh_failures_total counter",
                f"rd_blocked_names_refresh_failures_total {self.failures}",
            ]
            if self.last_success is not None:
                lines += [
                    "# TYPE rd_blocked_names_last_success_timestamp_seconds gauge",
                    f"rd_blocked_names_last_success_timestamp_seconds {self.last_success}",
                ]
            if self.last_change is not None:
                lines += [
                    "# TYPE rd_blocked_names_last_change_timestamp_seconds gauge",
                    f"rd_blocked_names_last_change_timestamp_seconds {self.last_change}",
                ]
        return "\n".join(lines) + "\n"


def log(message: str) -> None:
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message, flush=True)


def make_handler(state: State):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/rd-blocked-names.json":
                body = state.body
                if body is None:
                    self._send(503, b"no list fetched yet\n", "text/plain")
                else:
                    self._send(200, body, "application/json")
            elif self.path == "/metrics":
                self._send(200, state.metrics().encode(), "text/plain; version=0.0.4")
            elif self.path == "/healthz":
                self._send(200, b"ok\n", "text/plain")
            else:
                self._send(404, b"not found\n", "text/plain")

        def _send(self, code: int, body: bytes, content_type: str):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return Handler


def main() -> None:
    state = State(STATE_FILE)

    def loop():
        while True:
            state.refresh(fetch_source)
            time.sleep(REFRESH_SECONDS)

    threading.Thread(target=loop, daemon=True).start()
    log(f"serving on :{PORT}, refreshing every {REFRESH_SECONDS}s from {SOURCE_URL}")
    ThreadingHTTPServer(("", PORT), make_handler(state)).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
