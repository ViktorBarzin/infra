#!/usr/bin/env python3
"""A hub's snapshot and tombstone files, and the push that writes into it.

Shared by the hourly snapshot-harvester and the snapshot-server sidecar, so
both record sign-outs the same way: whoever writes the snapshot compares the
previous one with what the browser holds now, and turns any cookie that left
before its expiry into a tombstone (see cookie_merge.update_tombstones).

Files, in the hub's snapshot directory on its PVC:
  storage-state.json  Playwright storageState, what devvm clients download
  tombstones.json     [[key, expiry], ...]
"""

from __future__ import annotations

import json
import os
import pathlib
import threading

import cdp_cookies
import cookie_merge


class HubStore:
    def __init__(self, cdp_base: str, snapshot_dir: str | os.PathLike,
                 protected: tuple[str, ...] = cookie_merge.DEFAULT_PROTECTED,
                 hub_limit: int = cookie_merge.DEFAULT_HUB_LIMIT) -> None:
        self.cdp_base = cdp_base
        self.dir = pathlib.Path(snapshot_dir)
        self.snapshot_path = self.dir / "storage-state.json"
        self.tombstones_path = self.dir / "tombstones.json"
        self.protected = protected
        self.hub_limit = hub_limit
        self._lock = threading.Lock()

    def _write(self, path: pathlib.Path, text: str) -> None:
        # Unique per writer: the harvester runs as root and the sidecar as 1000,
        # so a temp file one of them left behind must never block the other.
        tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
        tmp.write_text(text)
        os.replace(tmp, path)

    def _previous(self) -> list[dict]:
        try:
            return json.loads(self.snapshot_path.read_text()).get("cookies", [])
        except (FileNotFoundError, ValueError):
            return []

    def load_tombstones(self) -> dict:
        try:
            return cookie_merge.tombstones_from_json(self.tombstones_path.read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def _refresh_locked(self, now: float) -> list[dict]:
        self.dir.mkdir(parents=True, exist_ok=True)
        current = cdp_cookies.storage_state(self.cdp_base)["cookies"]
        tombstones = cookie_merge.update_tombstones(self._previous(), current,
                                                    self.load_tombstones(), now)
        self._write(self.tombstones_path, cookie_merge.tombstones_to_json(tombstones))
        if current:
            # An empty jar is far more likely a browser that just restarted
            # than a person who signed out of everything; keep the last good
            # snapshot for clients and let the tombstones carry the change.
            self._write(self.snapshot_path, json.dumps({"cookies": current, "origins": []}))
        return current

    def refresh(self, now: float) -> list[dict]:
        """Re-read the browser, update tombstones, rewrite the snapshot."""
        with self._lock:
            return self._refresh_locked(now)

    def push(self, incoming: list[dict], now: float) -> dict:
        """Merge pushed cookies into the hub browser; returns counts only."""
        with self._lock:
            current = self._refresh_locked(now)
            result = cookie_merge.merge(incoming, current, self.load_tombstones(), now,
                                        protected=self.protected, hub_limit=self.hub_limit)
            ok = rejected = 0
            if result.accepted:
                params = [cookie_merge.to_cdp_param(c) for c in result.accepted]
                ok, rejected = cdp_cookies.set_cookies(self.cdp_base, params)
                current = self._refresh_locked(now)
            return {
                "accepted": ok,
                "rejected": rejected,
                "skipped": result.skipped,
                "snapshot_cookies": len(current),
                "accepted_domains": sorted({cookie_merge._bare(c["domain"]) for c in result.accepted}),
            }
