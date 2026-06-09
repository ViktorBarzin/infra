#!/usr/bin/env python3
"""Connect to chrome-service via CDP, dump storage state, write atomically.

Runs hourly as a Kubernetes CronJob. Mounts the chrome-service encrypted
PVC at /profile (same node via pod-affinity) and writes the snapshot to
/profile/snapshots/storage-state.json. The snapshot-server sidecar reads
from the same path and serves it bearer-gated.

CDP endpoint is plain HTTP — protection is the chrome-service
NetworkPolicy (allow only labelled client namespaces). Same security model
as the previous WS endpoint, just unauthenticated within the trust zone.
"""

import asyncio
import logging
import os
import pathlib
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("snapshot-harvester")

CDP_URL = os.environ.get(
    "CDP_URL", "http://chrome-service.chrome-service.svc.cluster.local:9222"
)
SNAPSHOT_DIR = pathlib.Path(os.environ.get("SNAPSHOT_DIR", "/profile/snapshots"))
SNAPSHOT_FILE = SNAPSHOT_DIR / "storage-state.json"
TMP_FILE = SNAPSHOT_DIR / "storage-state.json.tmp"


async def main() -> int:
    try:
        from playwright.async_api import async_playwright
    except ImportError:
        log.error("playwright not installed in image")
        return 2

    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)

    async with async_playwright() as p:
        try:
            browser = await p.chromium.connect_over_cdp(CDP_URL, timeout=20_000)
        except Exception:
            log.exception("connect_over_cdp failed (%s)", CDP_URL)
            return 3

        try:
            contexts = browser.contexts
            if not contexts:
                log.error("no browser contexts found — chrome-service may not have launched a persistent context yet")
                return 4
            ctx = contexts[0]
            # storage_state writes cookies + localStorage to a JSON file.
            # IndexedDB and sessionStorage are NOT included (known Playwright limitation).
            await ctx.storage_state(path=str(TMP_FILE))
            os.replace(TMP_FILE, SNAPSHOT_FILE)
            size = SNAPSHOT_FILE.stat().st_size
            log.info("wrote snapshot (%d bytes) to %s", size, SNAPSHOT_FILE)
        finally:
            try:
                await browser.close()
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
