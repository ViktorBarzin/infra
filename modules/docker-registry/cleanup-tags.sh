#!/usr/bin/env python3
"""Keeps only the N most recent tags per image in a Docker registry.
Uses filesystem modification times on the tag directories for speed.
Run garbage-collect after this to reclaim disk space."""

import json
import os
import sys
import urllib.request

sys.stdout.reconfigure(line_buffering=True)

REGISTRY = "http://127.0.0.1:5000"
KEEP = int(sys.argv[1]) if len(sys.argv) > 1 else 10

# Registry storage path (docker volume)
STORAGE = "/var/lib/docker/volumes/57b3f1c5fcc7f39c040e17072e10b4536245357d09340206683c04096d30b942/_data/docker/registry/v2/repositories"

def api(path, method="GET", headers=None):
    req = urllib.request.Request(f"{REGISTRY}{path}", method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            if method == "HEAD":
                return dict(r.headers)
            return json.loads(r.read())
    except Exception:
        return None

# Get all repos
catalog = api("/v2/_catalog")
if not catalog:
    print("Failed to fetch catalog")
    sys.exit(1)

total_deleted = 0

for repo in catalog.get("repositories", []):
    tags_dir = os.path.join(STORAGE, repo, "_manifests", "tags")
    if not os.path.isdir(tags_dir):
        continue

    # Get tags with their modification times from filesystem
    tag_times = []
    for tag in os.listdir(tags_dir):
        tag_path = os.path.join(tags_dir, tag)
        if os.path.isdir(tag_path):
            mtime = os.path.getmtime(tag_path)
            tag_times.append((mtime, tag))

    if len(tag_times) <= KEEP:
        continue

    # Sort by mtime descending (newest first), delete everything past KEEP
    tag_times.sort(reverse=True)
    to_delete = tag_times[KEEP:]

    print(f"[{repo}] has {len(tag_times)} tags, deleting {len(to_delete)}, keeping {KEEP}")

    for _, tag in to_delete:
        headers_resp = api(f"/v2/{repo}/manifests/{tag}", method="HEAD", headers={
            "Accept": "application/vnd.docker.distribution.manifest.v2+json"
        })
        if not headers_resp:
            continue
        digest = headers_resp.get("Docker-Content-Digest") or headers_resp.get("docker-content-digest")
        if digest:
            result = api(f"/v2/{repo}/manifests/{digest}", method="DELETE")
            total_deleted += 1

    print(f"  deleted {len(to_delete)} tags")

print(f"\nDone. Deleted {total_deleted} total tags. Run garbage-collect to reclaim disk space.")
