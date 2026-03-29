#!/usr/bin/env python3
"""Finds and removes layer links that point to non-existent blobs.

When the cleanup-tags.sh + garbage-collect cycle runs, it can delete blob data
while leaving _layers/ link files intact. The registry then returns HTTP 200
with 0 bytes for those layers (it finds the link, trusts the blob exists, but
the data is gone). This causes containerd to fail with "unexpected EOF".

This script walks all repositories, checks each layer link against the actual
blobs directory, and removes any orphaned links. On next pull, the registry
will re-fetch the missing blobs from the upstream registry.

Run after garbage-collect (e.g., 3:15 AM Sunday) or daily.
"""

import argparse
import os
import sys

sys.stdout.reconfigure(line_buffering=True)

parser = argparse.ArgumentParser(description="Remove orphaned registry layer links")
parser.add_argument("base", nargs="?", default="/opt/registry/data", help="Registry data directory")
parser.add_argument("--dry-run", action="store_true", help="Report but don't delete")
args = parser.parse_args()

BASE = args.base
DRY_RUN = args.dry_run

total_removed = 0
total_checked = 0

for registry_name in sorted(os.listdir(BASE)):
    repos_dir = os.path.join(BASE, registry_name, "docker/registry/v2/repositories")
    blobs_dir = os.path.join(BASE, registry_name, "docker/registry/v2/blobs")

    if not os.path.isdir(repos_dir):
        continue

    for root, dirs, files in os.walk(repos_dir):
        if not root.endswith("/_layers/sha256"):
            continue

        repo = root.replace(repos_dir + "/", "").replace("/_layers/sha256", "")

        for digest_dir in os.listdir(root):
            link_file = os.path.join(root, digest_dir, "link")
            if not os.path.isfile(link_file):
                continue

            total_checked += 1

            # Check if the actual blob data exists
            blob_data = os.path.join(blobs_dir, "sha256", digest_dir[:2], digest_dir, "data")
            if not os.path.isfile(blob_data):
                prefix = "[DRY RUN] " if DRY_RUN else ""
                print(f"{prefix}[{registry_name}/{repo}] removing orphaned layer link: {digest_dir[:12]}...")
                if not DRY_RUN:
                    # Remove the entire digest directory (contains the link file)
                    import shutil
                    shutil.rmtree(os.path.join(root, digest_dir))
                total_removed += 1

mode = "DRY RUN — " if DRY_RUN else ""
print(f"\n{mode}Checked {total_checked} layer links, removed {total_removed} orphaned.")
