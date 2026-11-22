"""HTTP control for play.py, so Home Assistant can drive the LED strip.

GET  /state  -> current state as JSON, plus "running" and the pattern names
POST /state  -> JSON with any of on, pattern, brightness, rgb; returns the new state

Each change stops play.py with SIGINT (it clears the strip) and starts it again
with the new flags. The state is saved in /data/state.json, so the strip comes
back as it was after a restart.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TypedDict

import patterns

PATTERNS = tuple(patterns.PATTERNS)
COLOUR_PATTERNS = tuple(p.name for p in patterns.PATTERNS.values() if p.colour)
DEFAULT_COUNT = 150
DEFAULT_MUSIC_DELAY_MS = 0  # tuned by ear on 2026-11-22: 0 is in sync
STATE_FILE = Path("/data/state.json")
OPTIONS_FILE = Path("/data/options.json")
SCRIPT = Path(__file__).with_name("play.py")
PORT = 8099
MIN_BACKOFF = 5.0  # seconds before restarting a pattern that died
MAX_BACKOFF = 60.0
CHECK_EVERY = 5.0


class State(TypedDict):
    on: bool
    pattern: str
    brightness: int
    rgb: list[int]


DEFAULT_STATE: State = {
    "on": False,
    "pattern": "rainbow",
    "brightness": 102,
    "rgb": [176, 143, 18],
}


def merge(state: State, change: object) -> State:
    """Apply a change to a state. Any change without "on" turns the light on."""
    if not isinstance(change, dict):
        raise ValueError("body must be a JSON object")
    unknown = set(change) - {"on", "pattern", "brightness", "rgb"}
    if unknown:
        raise ValueError(f"unknown keys: {sorted(unknown)}")
    new: State = {**state, "rgb": list(state["rgb"])}
    if "on" in change:
        if not isinstance(change["on"], bool):
            raise ValueError("on must be true or false")
        new["on"] = change["on"]
    else:
        new["on"] = True
    if "pattern" in change:
        if change["pattern"] not in PATTERNS:
            raise ValueError(f"pattern must be one of {list(PATTERNS)}")
        new["pattern"] = change["pattern"]
    if "brightness" in change:
        b = change["brightness"]
        if not isinstance(b, int) or isinstance(b, bool) or not 1 <= b <= 255:
            raise ValueError("brightness must be an integer from 1 to 255")
        new["brightness"] = b
    if "rgb" in change:
        rgb = change["rgb"]
        if (not isinstance(rgb, list) or len(rgb) != 3
                or not all(isinstance(c, int) and not isinstance(c, bool) and 0 <= c <= 255 for c in rgb)):
            raise ValueError("rgb must be three integers from 0 to 255")
        new["rgb"] = list(rgb)
        if "pattern" not in change and new["pattern"] not in COLOUR_PATTERNS:
            new["pattern"] = "color_wipe"
    return new


def led_count(path: Path) -> int:
    """The strip length from the add-on options, or the old default."""
    try:
        n = json.loads(path.read_text()).get("led_count")
    except (OSError, ValueError, AttributeError):
        return DEFAULT_COUNT
    return n if isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= 1000 else DEFAULT_COUNT


def music_delay_ms(path: Path) -> int:
    """How long the music patterns wait for the speaker, from the add-on options."""
    try:
        ms = json.loads(path.read_text()).get("music_delay_ms")
    except (OSError, ValueError, AttributeError):
        return DEFAULT_MUSIC_DELAY_MS
    ok = isinstance(ms, int) and not isinstance(ms, bool) and 0 <= ms <= 2000
    return ms if ok else DEFAULT_MUSIC_DELAY_MS


def command(state: State, count: int = DEFAULT_COUNT,
            music_delay_ms: int = DEFAULT_MUSIC_DELAY_MS) -> list[str]:
    return [
        sys.executable, str(SCRIPT),
        "--pattern", state["pattern"],
        "--rgb", ",".join(str(c) for c in state["rgb"]),
        "--brightness", str(state["brightness"]),
        "--count", str(count),
        "--music-delay-ms", str(music_delay_ms),
    ]


def load(path: Path) -> State:
    try:
        return merge(DEFAULT_STATE, json.loads(path.read_text()))
    except (OSError, ValueError):
        return DEFAULT_STATE


def save(path: Path, state: State) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    os.replace(tmp, path)


class Strip:
    def __init__(self, state_file: Path, count: int = DEFAULT_COUNT,
                 music_delay_ms: int = DEFAULT_MUSIC_DELAY_MS) -> None:
        self.state_file = state_file
        self.count = count
        self.music_delay_ms = music_delay_ms
        self.state = load(state_file)
        self.proc: subprocess.Popen[bytes] | None = None
        self.lock = threading.Lock()
        self.backoff = MIN_BACKOFF
        self.next_try = 0.0
        self.last_restart = 0.0

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _stop(self) -> None:
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None

    def _apply(self) -> None:
        self._stop()
        if self.state["on"]:
            argv = command(self.state, self.count, self.music_delay_ms)
            print("starting", " ".join(argv[1:]), flush=True)
            self.proc = subprocess.Popen(argv)

    def start(self) -> None:
        with self.lock:
            self._apply()

    def change(self, change: object) -> State:
        with self.lock:
            new = merge(self.state, change)
            if new != self.state or self.running() != new["on"]:
                self.state = new
                save(self.state_file, new)
                self._apply()
                self.backoff = MIN_BACKOFF
                self.next_try = 0.0
            return self.state

    def keep_alive(self, now: float) -> bool:
        """Restart the pattern if it died while the light is on.

        The OOM killer can kill play.py alone; the add-on then stays up
        and reports "on" over a dark strip. A pattern that keeps dying is
        retried with a backoff of up to MAX_BACKOFF seconds.
        """
        with self.lock:
            if not self.state["on"]:
                return False
            if self.running():
                if now - self.last_restart > MAX_BACKOFF:
                    self.backoff = MIN_BACKOFF
                return False
            if now < self.next_try:
                return False
            code = self.proc.returncode if self.proc is not None else None
            print(f"pattern exited (code {code}), restarting", flush=True)
            self._apply()
            self.last_restart = now
            self.next_try = now + self.backoff
            self.backoff = min(self.backoff * 2, MAX_BACKOFF)
            return True

    def shutdown(self) -> None:
        with self.lock:
            self._stop()


def handler(strip: Strip) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code: int, body: object) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            if self.path != "/state":
                return self._reply(404, {"error": "not found"})
            self._reply(200, {**strip.state, "running": strip.running(), "patterns": list(PATTERNS)})

        def do_POST(self) -> None:
            if self.path != "/state":
                return self._reply(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length") or 0)
            try:
                state = strip.change(json.loads(self.rfile.read(length) or b"{}"))
            except ValueError as e:
                return self._reply(400, {"error": str(e)})
            self._reply(200, {**state, "running": strip.running()})

        def log_message(self, format: str, *args: object) -> None:
            pass

    return Handler


def main() -> None:
    strip = Strip(STATE_FILE, led_count(OPTIONS_FILE), music_delay_ms(OPTIONS_FILE))
    strip.start()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), handler(strip))

    def stop(signum: int, frame: object) -> None:
        threading.Thread(target=httpd.shutdown).start()

    signal.signal(signal.SIGTERM, stop)

    def watch() -> None:
        while True:
            time.sleep(CHECK_EVERY)
            strip.keep_alive(time.monotonic())

    threading.Thread(target=watch, daemon=True).start()
    print(f"listening on :{PORT}, {strip.count} LEDs, state {strip.state}", flush=True)
    try:
        httpd.serve_forever()
    finally:
        strip.shutdown()


if __name__ == "__main__":
    main()
