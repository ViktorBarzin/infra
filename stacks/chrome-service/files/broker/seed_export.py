#!/usr/bin/env python3
"""Export the MASTER browser's storage_state (cookies + localStorage) as JSON to stdout.

Run by the broker as a SUBPROCESS per seed (the broker caches the result ~10s). A
subprocess keeps Playwright's sync API off the broker's ThreadingHTTPServer worker
threads (sync_playwright has thread-affinity constraints). connect_over_cdp().close()
only disconnects the CDP client — it never kills the master (same semantics as the
hourly snapshot-harvester and browser_runner.js). Read-only; never written back.
"""
import json
import os
import sys

CDP = os.environ.get("MASTER_CDP_URL", "http://chrome-service.chrome-service.svc:9222")


def main() -> int:
    # patchright (playwright drop-in) avoids the Runtime.enable CDP leak, so even
    # the read-only export against the master's context doesn't tip anti-bot.
    from patchright.sync_api import sync_playwright
    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp(CDP, timeout=20000)
        try:
            ctxs = b.contexts
            if not ctxs:
                print("no browser context on master", file=sys.stderr)
                return 3
            st = ctxs[0].storage_state()
        finally:
            b.close()
    json.dump(st, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
