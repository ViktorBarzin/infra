#!/usr/bin/env python3
"""Registry integrity scanner — two classes of brokenness.

1. Orphaned layer links: the cleanup-tags.sh + garbage-collect cycle can delete
   blob data while leaving _layers/ link files intact. The registry then returns
   HTTP 200 with 0 bytes for those layers (it finds the link, trusts the blob
   exists, but the data is gone). Containerd sees "unexpected EOF".
   Action: delete the orphan link so the next pull re-fetches cleanly.

2. Orphaned OCI-index children: an image index (multi-platform manifest list)
   references child manifests by digest. If a child's blob has been deleted —
   by a cleanup-tags.sh tag rmtree followed by garbage-collect walking the
   children wrong (distribution/distribution#3324 class), or by an incomplete
   `buildx --push` whose partial blob was later purged by `uploadpurging` —
   the index survives but pulls fail with `manifest unknown`.
   Action: log loudly. Deleting an index is a conscious decision (the image
   was published; removing it breaks downstream consumers), so we surface
   the problem and leave repair to a human or to the rebuild runbook.

Run after garbage-collect (Sunday 03:30) and daily (Mon-Sat 02:30).
"""

import argparse
import json
import os
import sys

sys.stdout.reconfigure(line_buffering=True)

parser = argparse.ArgumentParser(description="Scan registry for orphaned blobs and indexes")
parser.add_argument("base", nargs="?", default="/opt/registry/data", help="Registry data directory")
parser.add_argument("--dry-run", action="store_true", help="Report but don't delete")
args = parser.parse_args()

BASE = args.base
DRY_RUN = args.dry_run

INDEX_MEDIA_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)

# Only the private R/W registry is authoritative for every child of every
# index it stores — we pushed those indexes ourselves, so a missing child is
# always a bug (the 2026-04-13 + 2026-04-19 failure mode).
#
# Pull-through caches (dockerhub, ghcr, quay, k8s, kyverno) are ALLOWED to
# have missing children: they only fetch what someone actually pulls.
# Uncached arm64 / arm / attestation variants of a multi-platform index are
# normal partial state, not orphans. Scanning them generates hundreds of
# false-positive warnings — noise that would mask the real signal from the
# private registry. Scan 2 is therefore private-only.
INDEX_SCAN_REGISTRIES = ("private",)

total_layer_removed = 0
total_layer_checked = 0
total_index_scanned = 0
total_index_orphans = 0


def load_manifest_blob(blobs_root, digest_hex):
    blob_path = os.path.join(blobs_root, digest_hex[:2], digest_hex, "data")
    if not os.path.isfile(blob_path):
        return None
    try:
        with open(blob_path, "rb") as f:
            raw = f.read(1024 * 1024)
    except OSError:
        return None
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None


for registry_name in sorted(os.listdir(BASE)):
    repos_dir = os.path.join(BASE, registry_name, "docker/registry/v2/repositories")
    blobs_root = os.path.join(BASE, registry_name, "docker/registry/v2/blobs/sha256")

    if not os.path.isdir(repos_dir):
        continue

    for root, _, _ in os.walk(repos_dir):
        # --- Scan 1: orphan layer links ----------------------------------------
        if root.endswith("/_layers/sha256"):
            repo = root.replace(repos_dir + "/", "").replace("/_layers/sha256", "")

            for digest_dir in os.listdir(root):
                link_file = os.path.join(root, digest_dir, "link")
                if not os.path.isfile(link_file):
                    continue

                total_layer_checked += 1
                blob_data = os.path.join(blobs_root, digest_dir[:2], digest_dir, "data")
                if os.path.isfile(blob_data):
                    continue

                prefix = "[DRY RUN] " if DRY_RUN else ""
                print(f"{prefix}[{registry_name}/{repo}] removing orphaned layer link: {digest_dir[:12]}...")
                if not DRY_RUN:
                    import shutil
                    shutil.rmtree(os.path.join(root, digest_dir))
                total_layer_removed += 1

        # --- Scan 2: orphan OCI-index children (private registry only) --------
        elif root.endswith("/_manifests/revisions/sha256") and registry_name in INDEX_SCAN_REGISTRIES:
            repo = root.replace(repos_dir + "/", "").replace("/_manifests/revisions/sha256", "")

            for digest_dir in os.listdir(root):
                # Manifest revision entry. Load the blob it points to.
                manifest = load_manifest_blob(blobs_root, digest_dir)
                if manifest is None:
                    continue

                media_type = manifest.get("mediaType", "")
                if media_type not in INDEX_MEDIA_TYPES:
                    continue

                total_index_scanned += 1

                # Per-repo revision links — serving a child manifest via the API
                # requires <repo>/_manifests/revisions/sha256/<child-digest>/link
                # to exist. The blob data alone is not enough: cleanup-tags.sh
                # rmtrees tag dirs (which on 2.8.x also orphans the per-repo
                # revision links for index children), while the upstream blob
                # data survives in /blobs/. That's exactly the 2026-04-19
                # failure mode — the probe sees 404 even though the blob file
                # is still on disk.
                revisions_root = os.path.dirname(root)  # …/_manifests/revisions
                for child in manifest.get("manifests", []):
                    child_digest = child.get("digest", "")
                    if not child_digest.startswith("sha256:"):
                        continue
                    child_hex = child_digest[len("sha256:"):]
                    child_link = os.path.join(revisions_root, "sha256", child_hex, "link")
                    if os.path.isfile(child_link):
                        continue

                    platform = child.get("platform", {})
                    arch = platform.get("architecture", "?")
                    os_ = platform.get("os", "?")
                    child_blob = os.path.join(blobs_root, child_hex[:2], child_hex, "data")
                    blob_state = "blob-data-present" if os.path.isfile(child_blob) else "blob-data-gone"
                    print(
                        f"WARNING [{registry_name}/{repo}] ORPHAN INDEX: "
                        f"{digest_dir[:12]} references missing child {child_hex[:12]} "
                        f"({arch}/{os_}, {blob_state}) — registry returns 404, rebuild required"
                    )
                    total_index_orphans += 1


mode = "DRY RUN — " if DRY_RUN else ""
print(f"\n{mode}Layer scan: checked {total_layer_checked} links, removed {total_layer_removed} orphaned.")
print(f"{mode}Index scan: inspected {total_index_scanned} image indexes, found {total_index_orphans} orphaned children.")
if total_index_orphans > 0:
    print(f"\nACTION REQUIRED: {total_index_orphans} orphan index child(ren) detected. "
          "See docs/runbooks/registry-rebuild-image.md — the affected image must be rebuilt "
          "(a registry DELETE on an index is a conscious decision, not an automated repair).")
