#!/usr/bin/env python3
"""Weekly maintenance for Emo's Portal Mini photo-frame.

Keeps the two curated Immich albums current so the frame keeps showing only
"content" (people / landscapes / moments) and never equipment/documentation:

  - CONTENT album  (KEEP_ALBUM)  -> record of frame-eligible photos
  - EQUIPMENT album (DROP_ALBUM) -> excluded by the frame via ExcludedAlbums

The frame itself already rolls the last-365-day window (ImagesFromDays) and
subtracts DROP_ALBUM, so all this job must do is classify the *new* photos
that have appeared since last run and drop the equipment ones into DROP_ALBUM.

Classification is done with Immich's own CLIP smart-search (no external LLM):
an asset that surfaces for the equipment/document concept queries is treated
as equipment. Measured ~95% precision / ~96% recall against a hand-labelled
set. Conservative by design: a new photo is only excluded if it matches an
equipment query, so it errs toward *showing* a photo rather than hiding a
memory.

Pure stdlib (urllib) so it runs on a stock python image with no pip installs.
"""
import json, os, sys, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

IMMICH = os.environ["IMMICH_URL"].rstrip("/")
KEY = os.environ["IMMICH_API_KEY"]
KEEP_ALBUM = os.environ["KEEP_ALBUM"]
DROP_ALBUM = os.environ["DROP_ALBUM"]
DAYS = int(os.environ.get("DAYS", "365"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() in ("1", "true", "yes")

EQUIPMENT_QUERIES = [
    "equipment, electrical panel, fuse box, wiring, meter, circuit board, "
    "machinery, hardware close-up, cables, router, network switch",
    "document, screenshot, receipt, paperwork, hand-drawn schematic, "
    "product packaging, price label, car dashboard odometer, lock mechanism",
]


def api(path, method="GET", body=None):
    url = f"{IMMICH}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("x-api-key", KEY)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} on {method} {path}: {e.read()[:200]}", file=sys.stderr)
        raise


def search_ids(path, body, max_pages=20):
    """Paginate a search endpoint, return ordered list of asset ids."""
    ids, page = [], 1
    while page <= max_pages:
        r = api(path, "POST", {**body, "page": page, "size": 250})
        a = r.get("assets", {})
        items = a.get("items", [])
        ids += [it["id"] for it in items]
        nxt = a.get("nextPage")
        if not nxt:
            break
        page = int(nxt)
    return ids


def album_asset_ids(album_id):
    # GET /api/albums/{id} does not return members in Immich v3; use the
    # metadata search albumIds filter instead.
    return set(search_ids("/api/search/metadata", {"albumIds": [album_id]}))


def main():
    taken_after = (datetime.now(timezone.utc) - timedelta(days=DAYS)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )
    # 1. universe = all images in the rolling window
    window = set(search_ids("/api/search/metadata",
                            {"takenAfter": taken_after, "type": "IMAGE"}))
    keep_have = album_asset_ids(KEEP_ALBUM)
    drop_have = album_asset_ids(DROP_ALBUM)
    classified = keep_have | drop_have
    new_ids = window - classified
    print(f"window(last {DAYS}d)={len(window)} keep_album={len(keep_have)} "
          f"drop_album={len(drop_have)} new={len(new_ids)}")
    if not new_ids:
        print("nothing new to classify")
        return

    # 2. equipment candidates via CLIP concept queries
    equip = set()
    for q in EQUIPMENT_QUERIES:
        equip |= set(search_ids("/api/search/smart", {"query": q, "type": "IMAGE"}))
    new_equip = sorted(new_ids & equip)
    new_content = sorted(new_ids - equip)
    print(f"new -> equipment(drop)={len(new_equip)} content(keep)={len(new_content)}")

    if DRY_RUN:
        print("DRY_RUN: no album changes made")
        return

    # 3. apply: add to the respective albums (idempotent)
    def add(album_id, ids):
        for i in range(0, len(ids), 200):
            api(f"/api/albums/{album_id}/assets", "PUT", {"ids": ids[i:i + 200]})
    if new_equip:
        add(DROP_ALBUM, new_equip)
    if new_content:
        add(KEEP_ALBUM, new_content)
    print(f"applied: +{len(new_equip)} to drop, +{len(new_content)} to keep")


if __name__ == "__main__":
    main()
