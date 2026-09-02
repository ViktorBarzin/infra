#!/usr/bin/env python3
"""Keeps only the N most recent tags per image in pull-through cache registries.
Deletes old tag links directly from the filesystem since the API doesn't support
DELETE on proxy registries. Run garbage-collect after to reclaim blob storage."""

import os
import shutil
import sys

sys.stdout.reconfigure(line_buffering=True)

KEEP = int(sys.argv[1]) if len(sys.argv) > 1 else 10
BASE = sys.argv[2] if len(sys.argv) > 2 else "/opt/registry/data"

total_deleted = 0

for registry_name in sorted(os.listdir(BASE)):
    storage = os.path.join(BASE, registry_name, "docker/registry/v2/repositories")
    if not os.path.isdir(storage):
        continue

    for root, dirs, _ in os.walk(storage):
        if not root.endswith("_manifests/tags"):
            continue

        repo = root.replace(storage + "/", "").replace("/_manifests/tags", "")

        tag_times = []
        for tag in os.listdir(root):
            tag_path = os.path.join(root, tag)
            if os.path.isdir(tag_path):
                mtime = os.path.getmtime(tag_path)
                tag_times.append((mtime, tag, tag_path))

        if len(tag_times) <= KEEP:
            continue

        tag_times.sort(reverse=True)
        to_delete = tag_times[KEEP:]

        print(f"[{registry_name}/{repo}] {len(tag_times)} tags -> keeping {KEEP}, deleting {len(to_delete)}")

        for _, tag, tag_path in to_delete:
            shutil.rmtree(tag_path)
            total_deleted += 1

        print(f"  done")

print(f"\nDeleted {total_deleted} tags. Run garbage-collect to reclaim space.")
