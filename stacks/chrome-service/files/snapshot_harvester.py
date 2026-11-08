#!/usr/bin/env python3
"""Read chrome-service's cookies over CDP, write the snapshot atomically.

Runs hourly as a Kubernetes CronJob. Mounts the chrome-service encrypted
PVC at /profile (same node via pod-affinity) and writes the snapshot to
/profile/snapshots/storage-state.json. The snapshot-server sidecar reads
from the same path and serves it bearer-gated.

CDP endpoint is plain HTTP — protection is the chrome-service
NetworkPolicy (allow only labelled client namespaces). Same security model
as the previous WS endpoint, just unauthenticated within the trust zone.

This used to go through playwright's connect_over_cdp, which enumerates every
target on the master and asserts each carries a browserContextId. On
2026-09-18 one orphaned service_worker target had none, and all ten runs
between 13:23 and 23:23 failed on that assert. cdp_cookies.storage_state()
asks the browser endpoint for its cookies and never touches a target.
"""

import logging
import os
import pathlib
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hub_store  # noqa: E402  (mounted beside this script in the same ConfigMap)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("snapshot-harvester")

CDP_URL = os.environ.get(
    "CDP_URL", "http://chrome-service.chrome-service.svc.cluster.local:9222"
)
SNAPSHOT_DIR = pathlib.Path(os.environ.get("SNAPSHOT_DIR", "/profile/snapshots"))


def main() -> int:
    store = hub_store.HubStore(CDP_URL, SNAPSHOT_DIR)
    try:
        # Same path the hub's push uses: records sign-outs as tombstones and
        # keeps the last good snapshot if the browser returns an empty jar.
        cookies = store.refresh(time.time())
    except Exception:
        log.exception("could not read cookies from %s", CDP_URL)
        return 3
    if not cookies:
        log.error("master returned no cookies — kept the previous snapshot")
        return 4
    log.info("wrote snapshot (%d bytes, %d cookies) to %s",
             store.snapshot_path.stat().st_size, len(cookies), store.snapshot_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
