#!/usr/bin/env python3
"""Tiny HTTP server that exposes /api/snapshot, gated by a bearer token.

Runs as a sidecar in the chrome-service pod. Reads the persisted storage
state written hourly by the snapshot-harvester CronJob and returns it to
authenticated callers (the dev-box `playwright-snapshot-refresh` timer).

Token is read from the PW_TOKEN env var, same secret the legacy WS path
used. The endpoint is mounted behind Traefik on `chrome.viktorbarzin.me`
at the `/api/snapshot` path (auth=none at the ingress; the bearer check
is here).
"""

import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

TOKEN = os.environ.get("PW_TOKEN")
SNAPSHOT_PATH = os.environ.get(
    "SNAPSHOT_PATH", "/profile/snapshots/storage-state.json"
)
PORT = int(os.environ.get("PORT", "8088"))


class Handler(BaseHTTPRequestHandler):
    server_version = "chrome-snapshot/1"

    def _short(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._short(200, b"ok\n")
            return
        if self.path != "/api/snapshot":
            self._short(404)
            return
        if TOKEN is None:
            self._short(503, b"{\"error\":\"token not configured\"}\n")
            return
        if self.headers.get("Authorization", "") != f"Bearer {TOKEN}":
            self._short(401, b"{\"error\":\"invalid bearer\"}\n")
            return
        try:
            with open(SNAPSHOT_PATH, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            self._short(404, b"{\"error\":\"snapshot not yet available\"}\n")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write(
            "[snapshot-server] %s - %s\n" % (self.address_string(), fmt % args)
        )


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
