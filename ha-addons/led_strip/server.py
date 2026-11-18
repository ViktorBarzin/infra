"""HTTP control for strandtest.py, so Home Assistant can drive the LED strip.

GET  /state  -> current state as JSON, plus "running"
POST /state  -> JSON with any of on, pattern, brightness, rgb; returns the new state

Each change stops strandtest.py with SIGINT (it clears the strip on -c) and starts
it again with the new flags, the same way rpi-london's Flask page did. The state
is saved in /data/state.json, so the strip comes back as it was after a restart.
"""

import json
import os
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TypedDict

COLOUR_PATTERNS = ("color_wipe", "theater_chase", "comet", "scanner", "breathe", "twinkle")
PATTERNS = (
    "rainbow",
    "rainbow_cycle",
    "theater_chase_rainbow",
    "jik_tak",
    "flag_bg",
    "flag_ro",
    "flag_uk",
    "fire",
    "ocean",
    "police",
    "candy_cane",
    "ruler",
) + COLOUR_PATTERNS
DEFAULT_COUNT = 150
STATE_FILE = Path("/data/state.json")
OPTIONS_FILE = Path("/data/options.json")
SCRIPT = Path(__file__).with_name("strandtest.py")
PORT = 8099


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


def command(state: State, count: int = DEFAULT_COUNT) -> list[str]:
    colours = ""
    if state["pattern"] in COLOUR_PATTERNS:
        r, g, b = state["rgb"]
        colours = f"r={r},g={g},b={b}"
    return [
        sys.executable, str(SCRIPT), "-c",
        "-s", state["pattern"],
        "--colors", colours,
        "--brightness", str(state["brightness"]),
        "--count", str(count),
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
    def __init__(self, state_file: Path, count: int = DEFAULT_COUNT) -> None:
        self.state_file = state_file
        self.count = count
        self.state = load(state_file)
        self.proc: subprocess.Popen[bytes] | None = None
        self.lock = threading.Lock()

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
            argv = command(self.state, self.count)
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
            return self.state

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
            self._reply(200, {**strip.state, "running": strip.running()})

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
    strip = Strip(STATE_FILE, led_count(OPTIONS_FILE))
    strip.start()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), handler(strip))

    def stop(signum: int, frame: object) -> None:
        threading.Thread(target=httpd.shutdown).start()

    signal.signal(signal.SIGTERM, stop)
    print(f"listening on :{PORT}, {strip.count} LEDs, state {strip.state}", flush=True)
    try:
        httpd.serve_forever()
    finally:
        strip.shutdown()


if __name__ == "__main__":
    main()
