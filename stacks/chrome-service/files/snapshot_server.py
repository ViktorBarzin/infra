#!/usr/bin/env python3
"""A hub's HTTP API: GET /api/snapshot and POST /api/cookies.

Runs as a sidecar beside the hub's Chrome (same pod, CDP on localhost).

- GET /api/snapshot, bearer = read token (PW_TOKEN): the storageState that
  devvm clients seed their browsers from. Written by the hourly harvester and
  by every push.
- POST /api/cookies, bearer = write token (PW_WRITE_TOKEN): cookies a user's
  other browsers picked up. hub_store.HubStore.push applies cookie_merge's
  rules (later expiry only, tombstones, protected domains), sets the accepted
  cookies in Chrome over CDP and rewrites the snapshot before answering.
  Body: {"source": "...", "cookies": [<Playwright cookies>]}.

Routing: GET is reachable on the public host and the LAN-only hub host; POST
only on the LAN-only host (Traefik IP allowlist). The bearer checks here are
the gate on both. Logs carry counts and domains, never cookie values.
"""

import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cookie_merge  # noqa: E402  (mounted beside this script)
import hub_store  # noqa: E402

READ_TOKEN = os.environ.get("PW_TOKEN") or None
WRITE_TOKEN = os.environ.get("PW_WRITE_TOKEN") or None
SNAPSHOT_PATH = os.environ.get("SNAPSHOT_PATH", "/profile/snapshots/storage-state.json")
CDP_URL = os.environ.get("CDP_URL", "http://127.0.0.1:9222")
PORT = int(os.environ.get("PORT", "8088"))
MAX_BODY = 2 * 1024 * 1024
MAX_COOKIES = 3000
PROTECTED = tuple(d.strip() for d in os.environ.get(
    "PROTECTED_DOMAINS", ",".join(cookie_merge.DEFAULT_PROTECTED)).split(",") if d.strip())
HUB_LIMIT = int(os.environ.get("HUB_LIMIT", str(cookie_merge.DEFAULT_HUB_LIMIT)))

STORE = hub_store.HubStore(CDP_URL, os.path.dirname(SNAPSHOT_PATH),
                           protected=PROTECTED, hub_limit=HUB_LIMIT)


def bearer_ok(header: str, token: str | None) -> bool:
    if not token:
        return False
    return hmac.compare_digest(header.encode(), f"Bearer {token}".encode())


class Handler(BaseHTTPRequestHandler):
    server_version = "chrome-hub/2"
    store = STORE
    read_token = READ_TOKEN
    write_token = WRITE_TOKEN

    def _json(self, status: int, body: dict) -> None:
        data = (json.dumps(body) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"ok": True})
            return
        if self.path != "/api/snapshot":
            self._json(404, {"error": "not found"})
            return
        if not self.read_token:
            self._json(503, {"error": "token not configured"})
            return
        if not bearer_ok(self.headers.get("Authorization", ""), self.read_token):
            self._json(401, {"error": "invalid bearer"})
            return
        try:
            data = self.store.snapshot_path.read_bytes()
        except FileNotFoundError:
            self._json(404, {"error": "snapshot not yet available"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/api/cookies":
            self._json(404, {"error": "not found"})
            return
        if not self.write_token:
            self._json(503, {"error": "write token not configured"})
            return
        if not bearer_ok(self.headers.get("Authorization", ""), self.write_token):
            self._json(401, {"error": "invalid bearer"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            self._json(413 if length > MAX_BODY else 400, {"error": "body must be 1 byte to 2 MB"})
            return
        try:
            body = json.loads(self.rfile.read(length))
            cookies = body["cookies"]
            source = str(body.get("source", "unknown"))[:32]
            if not isinstance(cookies, list):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            self._json(400, {"error": "expected {\"source\": str, \"cookies\": [...]}"})
            return
        if len(cookies) > MAX_COOKIES:
            self._json(413, {"error": f"at most {MAX_COOKIES} cookies per push"})
            return
        try:
            result = self.store.push(cookies, time.time())
        except Exception as e:  # browser unreachable, CDP error
            self._json(502, {"error": f"hub browser unavailable: {type(e).__name__}"})
            return
        sys.stderr.write("[chrome-hub] push source=%s received=%d accepted=%d rejected=%d "
                         "skipped=%s domains=%s\n" % (
                             source, len(cookies), result["accepted"], result["rejected"],
                             json.dumps(result["skipped"]), ",".join(result["accepted_domains"])))
        self._json(200, result)

    def log_message(self, fmt, *args):
        sys.stderr.write("[chrome-hub] %s - %s\n" % (self.address_string(), fmt % args))


def refresh_loop(store, every: float) -> None:
    """Rewrite the snapshot every `every` seconds.

    For a hub without the harvester CronJob (emo's headless hub): the CronJob
    needs the RWO volume on the same node, the sidecar already has it.
    """
    while True:
        try:
            n = len(store.refresh(time.time()))
            sys.stderr.write("[chrome-hub] refreshed snapshot: %d cookies\n" % n)
        except Exception as e:
            sys.stderr.write("[chrome-hub] snapshot refresh failed: %s: %s\n" % (type(e).__name__, e))
        time.sleep(every)


if __name__ == "__main__":
    import threading

    every = float(os.environ.get("REFRESH_SECONDS", "0"))
    if every > 0:
        threading.Thread(target=refresh_loop, args=(STORE, every), daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
