#!/usr/bin/env python3
"""Keeps only the N most recent tags per image in a pull-through cache registry.
Deletes old tag links directly from the filesystem since the API doesn't support
DELETE on proxy registries. Run garbage-collect after to reclaim blob storage."""

import os
import shutil
import sys

sys.stdout.reconfigure(line_buffering=True)

KEEP = int(sys.argv[1]) if len(sys.argv) > 1 else 10

STORAGE = "/var/lib/docker/volumes/57b3f1c5fcc7f39c040e17072e10b4536245357d09340206683c04096d30b942/_data/docker/registry/v2/repositories"

total_deleted = 0

for root, dirs, _ in os.walk(STORAGE):
    # Look for _manifests/tags directories
    if not root.endswith("_manifests/tags"):
        continue

    repo = root.replace(STORAGE + "/", "").replace("/_manifests/tags", "")

    # Get tags with modification times
    tag_times = []
    for tag in os.listdir(root):
        tag_path = os.path.join(root, tag)
        if os.path.isdir(tag_path):
            mtime = os.path.getmtime(tag_path)
            tag_times.append((mtime, tag, tag_path))

    if len(tag_times) <= KEEP:
        continue

    # Sort by mtime descending (newest first)
    tag_times.sort(reverse=True)
    to_delete = tag_times[KEEP:]

    print(f"[{repo}] {len(tag_times)} tags -> keeping {KEEP}, deleting {len(to_delete)}")

    for _, tag, tag_path in to_delete:
        shutil.rmtree(tag_path)
        total_deleted += 1

    print(f"  done")

print(f"\nDeleted {total_deleted} tags. Restart registry and run garbage-collect to reclaim space.")
