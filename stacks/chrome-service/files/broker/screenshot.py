#!/usr/bin/env python3
"""Capture a PNG screenshot of a worker's active page → stdout (bytes).

Run by the broker as a SUBPROCESS for FleetView thumbnails (broker caches per session).
Best-effort + read-only: a second CDP client alongside the caller's is fine (CDP
multiplexes); failures just mean "no thumbnail", never a broken session. arg1 = worker
CDP base URL (http://<podIP>:9222).
"""
import sys


def main() -> int:
    if len(sys.argv) < 2:
        return 2
    cdp = sys.argv[1]
    # patchright, NOT playwright: this attaches to the CALLER's live page (a
    # possibly anti-bot site) — stock playwright would enable Runtime on that CDP
    # session, the exact fingerprint the pool exists to avoid (review #3).
    from patchright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp(cdp, timeout=10000)
        try:
            # the caller's context is the last-created one; grab its first page
            ctx = b.contexts[-1] if b.contexts else None
            page = (ctx.pages[0] if ctx and ctx.pages else None)
            if page is None:
                return 3
            png = page.screenshot(type="png", timeout=8000)
        finally:
            b.close()
    sys.stdout.buffer.write(png)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # best-effort: no thumbnail on any error
        print(str(e), file=sys.stderr)
        sys.exit(1)
