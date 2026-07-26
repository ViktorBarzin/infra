#!/usr/bin/env python3
"""Proxy visit collector — logs page visits from a neko Chromium via CDP.

Runs as a sidecar in each per-user browser pod (proxy-br-<user>). Chromium is
started with --remote-debugging-port=9222 (injected via /etc/chromium.d), which
binds the DevTools endpoint on loopback; the sidecar shares the pod's network
namespace, so it polls http://127.0.0.1:9222/json and emits one JSON line per
page visit to stdout. Alloy tails stdout into Loki, where the pod name
(proxy-br-<user>) attributes each visit to a specific Authentik user.

VISITS ONLY: the page URL + title, never page content, form data, or keystrokes.

Pure-stdlib (urllib + json) on purpose — the sidecar runs a stock python image
with no pip/apk at runtime, matching the alert-digest CronJob doctrine.

The transform `visit_record` is the tested seam; the poll loop is thin I/O.
"""
import datetime
import json
import os
import sys
import time
import urllib.request

CDP_URL = os.environ.get("CDP_URL", "http://127.0.0.1:9222").rstrip("/")
POLL_SECONDS = float(os.environ.get("VISIT_POLL_SECONDS", "2"))
USER = os.environ.get("PROXY_USER", "")

# URL schemes that are not real user visits (browser-internal pages, blobs, etc.).
_SKIP_PREFIXES = (
    "about:",
    "chrome://",
    "chrome-extension://",
    "chrome-untrusted://",
    "devtools://",
    "edge://",
    "view-source:",
    "data:",
    "blob:",
)


def visit_record(target, user, ts):
    """Turn a CDP target dict into a visit record, or None if it isn't a visit.

    `target` is one entry from the DevTools /json list (or a CDP TargetInfo):
    a dict with at least `type`, `url`, `title`. Only top-level page targets
    pointing at a real http(s)/ftp/etc. URL are logged.
    """
    if not isinstance(target, dict):
        return None
    if target.get("type") != "page":
        return None
    url = (target.get("url") or "").strip()
    if not url or url.startswith(_SKIP_PREFIXES):
        return None
    return {
        "ts": ts,
        "user": user,
        "url": url,
        "title": (target.get("title") or "").strip(),
        "kind": "nav",
    }


def _iso_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _fetch_targets():
    req = urllib.request.Request(CDP_URL + "/json", headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def _emit(rec):
    sys.stdout.write(json.dumps(rec, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    sys.stderr.write(
        "visit-collector: polling %s every %ss (user=%r)\n" % (CDP_URL, POLL_SECONDS, USER)
    )
    seen = {}  # target id -> last URL emitted, so we log a target only on change
    while True:
        try:
            targets = _fetch_targets()
        except Exception as e:  # CDP not up yet / chromium restarting — keep trying
            sys.stderr.write("visit-collector: fetch failed: %s\n" % e)
            time.sleep(POLL_SECONDS)
            continue
        alive = set()
        for t in targets if isinstance(targets, list) else []:
            tid = t.get("id")
            if tid is None:
                continue
            alive.add(tid)
            rec = visit_record(t, USER, _iso_now())
            if rec is None:
                continue
            if seen.get(tid) == rec["url"]:
                continue  # unchanged since last poll — already logged
            seen[tid] = rec["url"]
            _emit(rec)
        for tid in list(seen):  # forget closed tabs so a reopened URL re-logs
            if tid not in alive:
                del seen[tid]
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
