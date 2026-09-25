#!/usr/bin/env python3
"""Capture a PNG screenshot of a worker's active page → stdout (bytes).

Run by the broker as a SUBPROCESS for FleetView thumbnails (broker caches per session).
Best-effort + read-only: a second CDP client alongside the caller's is fine (CDP
multiplexes); failures just mean "no thumbnail", never a broken session. arg1 = worker
CDP base URL (http://<podIP>:9222). Exit 2 = no URL, 3 = no page to capture, 1 = error.

Why raw CDP, not patchright
---------------------------
``connect_over_cdp`` attaches browser-wide and asserts that every target
carries a ``browserContextId``. An orphaned service worker has none (the
embed.st worker of infra #98), so one orphan on a pool worker killed every
thumbnail for that session. This script lists targets, skips anything without
a context, and attaches to one page only. Page.captureScreenshot needs no
domain enabled, so the caller's page never sees Runtime.enable, the
fingerprint patchright was here to avoid. No pip install either: the
websocket client is the stdlib one in cdp_cookies.py.

Which page
----------
browser_runner.js opens its page in a context it creates, while the worker's
launch tab (about:blank) sits in the default context. So: a page in a created
context first, a loaded URL before a blank one, then Chrome's own order.
patchright's version effectively took the first page Chrome attached, which
was often that launch tab.
"""
import base64
import json
import sys
import urllib.request

# The stdlib RFC 6455 client the seed path already runs; one client, two callers.
from cdp_cookies import _OP_TEXT, _handshake

TIMEOUT = 10  # seconds per socket operation; the broker kills us at 15
INTERNAL_SCHEMES = ("chrome://", "chrome-extension://", "devtools://")
BLANK_URLS = ("", "about:blank")


def pick_page(targets, created_contexts):
    """targetId of the page to capture, or None when nothing qualifies."""
    pages = [t for t in targets
             if t.get("type") == "page"
             and t.get("browserContextId")
             and not t.get("url", "").startswith(INTERNAL_SCHEMES)]
    if not pages:
        return None
    # sorted() is stable, so equal keys keep Chrome's order
    best = sorted(pages, key=lambda t: (t["browserContextId"] not in created_contexts,
                                        t.get("url", "") in BLANK_URLS))[0]
    return best["targetId"]


class Client:
    """Sequential CDP commands over one browser websocket, flat sessions."""

    def __init__(self, framer):
        self._framer = framer
        self._last_id = 0

    def call(self, method, params=None, session_id=None):
        self._last_id += 1
        message = {"id": self._last_id, "method": method, "params": params or {}}
        if session_id:
            message["sessionId"] = session_id
        self._framer.send(_OP_TEXT, json.dumps(message).encode())
        while True:
            reply = json.loads(self._framer.message())
            if reply.get("id") != self._last_id:
                continue  # events, and anything that is not our reply
            if "error" in reply:
                raise RuntimeError(f"{method} failed: {reply['error']}")
            return reply.get("result", {})

    def close(self):
        self._framer.close()


def connect(cdp_base):
    with urllib.request.urlopen(cdp_base.rstrip("/") + "/json/version", timeout=TIMEOUT) as resp:
        ws_url = json.loads(resp.read())["webSocketDebuggerUrl"]
    return Client(_handshake(ws_url, TIMEOUT))


def capture(client):
    """PNG bytes of the chosen page, or None when there is no page to capture."""
    targets = client.call("Target.getTargets")["targetInfos"]
    created = set(client.call("Target.getBrowserContexts").get("browserContextIds", []))
    target_id = pick_page(targets, created)
    if target_id is None:
        return None
    session = client.call("Target.attachToTarget",
                          {"targetId": target_id, "flatten": True})["sessionId"]
    # Closing the websocket afterwards detaches this session; no explicit detach.
    shot = client.call("Page.captureScreenshot", {"format": "png"}, session_id=session)
    return base64.b64decode(shot["data"])


def main() -> int:
    if len(sys.argv) < 2:
        return 2
    client = connect(sys.argv[1])
    try:
        png = capture(client)
    finally:
        client.close()
    if png is None:
        return 3
    sys.stdout.buffer.write(png)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # best-effort: no thumbnail on any error
        print(str(e), file=sys.stderr)
        sys.exit(1)
