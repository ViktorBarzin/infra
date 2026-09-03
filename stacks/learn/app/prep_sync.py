#!/usr/bin/env python3
"""Last-write-wins sync for the public prep page at pages.viktorbarzin.me/prep/.

The page keeps every piece of state (confidence ratings, free-text notes, plan
ticks) in one flat map of key -> {"v": value, "t": epoch_ms}. That shape is the
whole design: merging is per key, the higher `t` wins, and it works the same
direction on both sides. So a reader can edit on a plane with no network, and
whatever they changed lands on the next successful PUT without a conflict
dialogue or an op log.

The endpoint is deliberately unauthenticated, because the page it serves is
public and the alternative was asking a non-technical reader to sign in. Three
things make that survivable rather than reckless:

  * every write snapshots the previous document, and VERSIONS_KEPT of them stay
    on disk, so a wipe is one file copy away from undone;
  * bodies, key counts and value sizes are capped, so the disk cannot be filled;
  * writes are rate limited per client address.

None of that stops a determined vandal from blanking the page's state. That was
an accepted trade (Viktor, 2026-09-03) in exchange for a link that needs no
login. If it is ever abused, restore a version and put the path behind auth.

Stdlib only: this runs on a stock python:3.12-slim with the code mounted from a
ConfigMap, so there is no image to build and no pip install to keep current.
"""
import json
import os
import re
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = os.environ.get("DATA_DIR", "/data")
STATE_PATH = os.path.join(DATA_DIR, "state.json")
VERSIONS_DIR = os.path.join(DATA_DIR, "versions")
PORT = int(os.environ.get("PORT", "8080"))

MAX_BODY = 256 * 1024          # bytes on the wire
MAX_KEYS = 5000                # keys in the merged document
MAX_KEY_LEN = 120
MAX_VALUE_LEN = 8000           # characters, for a string value
VERSIONS_KEPT = 50
WRITE_LIMIT = 120              # writes per client per window
WRITE_WINDOW = 600             # seconds

_KEY_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,%d}$" % MAX_KEY_LEN)
_lock = threading.Lock()
_writes = {}                   # client -> deque of timestamps


def _now_ms():
    return int(time.time() * 1000)


def _empty():
    return {"rev": 0, "updatedAt": 0, "keys": {}}


def _load():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return _empty()
    if not isinstance(doc, dict) or not isinstance(doc.get("keys"), dict):
        return _empty()
    doc.setdefault("rev", 0)
    doc.setdefault("updatedAt", 0)
    return doc


def _save(doc):
    os.makedirs(VERSIONS_DIR, exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    os.replace(tmp, STATE_PATH)      # a reader sees old or new, never half


def _snapshot(doc):
    """Keep the document as it was BEFORE this write, so a wipe is recoverable."""
    if doc.get("rev", 0) <= 0:
        return
    os.makedirs(VERSIONS_DIR, exist_ok=True)
    path = os.path.join(VERSIONS_DIR, "%06d.json" % doc["rev"])
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"))
    os.replace(tmp, path)
    kept = sorted(f for f in os.listdir(VERSIONS_DIR) if f.endswith(".json"))
    for stale in kept[:-VERSIONS_KEPT]:
        try:
            os.remove(os.path.join(VERSIONS_DIR, stale))
        except OSError:
            pass


def _clean_incoming(raw):
    """Keep only well-formed {key: {v, t}} entries. Bad entries are dropped, not
    rejected: one malformed key should not lose a reader a whole revision
    session's worth of edits."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for key, rec in list(raw.items())[: MAX_KEYS * 2]:
        if not isinstance(key, str) or not _KEY_RE.match(key):
            continue
        if not isinstance(rec, dict):
            continue
        t = rec.get("t")
        if not isinstance(t, (int, float)) or t < 0:
            continue
        v = rec.get("v")
        if isinstance(v, str):
            if len(v) > MAX_VALUE_LEN:
                v = v[:MAX_VALUE_LEN]
        elif not isinstance(v, (bool, int, float, type(None))):
            continue
        out[key] = {"v": v, "t": int(t)}
    return out


def _merge(current, incoming):
    """Per key, the higher timestamp wins. Returns (merged, changed)."""
    merged = dict(current)
    changed = False
    for key, rec in incoming.items():
        held = merged.get(key)
        if held is None or rec["t"] > held.get("t", 0):
            merged[key] = rec
            changed = True
    if len(merged) > MAX_KEYS:
        # Oldest stamps go first, so a flood cannot evict a reader's live work.
        for key, _ in sorted(merged.items(), key=lambda kv: kv[1].get("t", 0))[
            : len(merged) - MAX_KEYS
        ]:
            merged.pop(key, None)
        changed = True
    return merged, changed


def _rate_ok(client):
    now = time.time()
    seen = _writes.setdefault(client, deque())
    while seen and now - seen[0] > WRITE_WINDOW:
        seen.popleft()
    if len(seen) >= WRITE_LIMIT:
        return False
    seen.append(now)
    if len(_writes) > 4096:                      # bound the bookkeeping itself
        for stale in [c for c, d in _writes.items() if not d]:
            _writes.pop(stale, None)
    return True


class Handler(BaseHTTPRequestHandler):
    server_version = "prep-sync"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    # The offline copy of the page runs from file://, which sends Origin: null,
    # so it can only sync back if the endpoint allows any origin. The data is
    # public either way, so this widens nothing that the path itself did not.
    def _send(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _route(self):
        return self.path.split("?", 1)[0].rstrip("/") or "/"

    def do_OPTIONS(self):
        # 204 means NO body, and on a keep-alive connection a body here desyncs
        # the framing: the first preflight looks fine and every later request on
        # that connection fails. curl tolerates it, a browser does not, which is
        # exactly how this presented (measured 2026-09-03: first sync succeeded,
        # the reconnect push failed with a bare "Failed to fetch").
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_GET(self):
        route = self._route()
        if route.endswith("/healthz"):
            self._send(200, {"ok": True})
            return
        if route.endswith("/state"):
            with _lock:
                self._send(200, _load())
            return
        if route.endswith("/versions"):
            try:
                names = sorted(
                    f for f in os.listdir(VERSIONS_DIR) if f.endswith(".json")
                )
            except OSError:
                names = []
            self._send(200, {"versions": [n[:-5] for n in names]})
            return
        m = re.search(r"/versions/(\d{1,6})$", route)
        if m:
            path = os.path.join(VERSIONS_DIR, "%06d.json" % int(m.group(1)))
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    self._send(200, json.load(fh))
            except (OSError, ValueError):
                self._send(404, {"error": "no such version"})
            return
        self._send(404, {"error": "not found"})

    def do_PUT(self):
        if not self._route().endswith("/state"):
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"error": "bad length"})
            return
        if length <= 0 or length > MAX_BODY:
            self._send(413, {"error": "body must be 1..%d bytes" % MAX_BODY})
            return
        if not _rate_ok(self.address_string()):
            self._send(429, {"error": "too many writes, try again shortly"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except ValueError:
            self._send(400, {"error": "body must be JSON"})
            return
        incoming = _clean_incoming((payload or {}).get("keys"))
        with _lock:
            doc = _load()
            merged, changed = _merge(doc.get("keys", {}), incoming)
            if changed:
                _snapshot(doc)
                doc = {"rev": doc.get("rev", 0) + 1, "updatedAt": _now_ms(), "keys": merged}
                _save(doc)
            self._send(200, doc)


def main():
    os.makedirs(VERSIONS_DIR, exist_ok=True)
    if not os.path.exists(STATE_PATH):
        _save(_empty())
    print("prep-sync listening on %d, data in %s" % (PORT, DATA_DIR), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
