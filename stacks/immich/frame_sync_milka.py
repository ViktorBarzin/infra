#!/usr/bin/env python3
"""Keep Milka's photo frame free of chat clutter as new photos arrive.

Her library reaches Immich mostly through Viber, so alongside the photographs it
collects forwarded greeting cards, joke text-images, courier-app screenshots and
captures of conversations. The frame excludes one album (see frame-milka.tf); all
this job does is file the *new* arrivals of that kind into it.

Deliberately NOT the shared frame_sync.py, which serves Emo's frame:

  - His frame keeps two albums (content + equipment); hers excludes one and shows
    everything else, so there is no keep-album to maintain.
  - His job looks for equipment and documents. Hers must NOT: measured on her
    library on 2026-08-22, CLIP queries for equipment and construction materials
    also returned a granddaughter on a playground truck, a child in a playpen, a
    kid's drawing and a woman with a child — "industrial equipment" matches
    playground frames, cribs and trains. Text-heavy queries were worse still,
    pulling in graduation photos of someone holding a diploma. Only the
    screen-content class survived inspection, so only that class is used here.
  - Hers adds a filename rule, which needs no model at all.

Conservative by construction: it only ever ADDS to the exclusion album, and its
key cannot remove from an album or delete an asset. A mistake hides a photo until
someone takes it out of the album; it never loses one.

Pure stdlib on a stock python image — never pip/apk install in a CronJob.
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

IMMICH = os.environ["IMMICH_URL"].rstrip("/")
KEY = os.environ["IMMICH_API_KEY"]
DROP_ALBUM = os.environ["DROP_ALBUM"]
DAYS = int(os.environ.get("DAYS", "14"))
PER_QUERY = int(os.environ.get("PER_QUERY", "60"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() in ("1", "true", "yes")

# Verified by eye on four contact sheets, including the tail of each ranking —
# that is where the errors appear first, and checking only the top of the list
# is what makes a bad query look perfect. Do not add queries about documents,
# receipts or "mostly text": they match a person holding a diploma.
CHAT_QUERIES = [
    "screenshot of a chat conversation",
    "screenshot of a phone messaging app",
    "screenshot of text messages on a phone",
    "screenshot of a phone home screen with app icons",
    "screenshot of a mobile app interface",
    "image of text with a joke caption",
    "greeting card image with text overlay",
]

# Two queries were dropped on 2026-08-23 after measuring them against the
# 14-day window, where the same size reaches far deeper into a much smaller pool
# than it did across the whole library:
#   "screenshot of a delivery tracking app" — returned 13 hits of which most were
#       her own camera photos of people receiving and unpacking parcels.
#   "screenshot of a facebook post" — returned a camera photo and a video.
# Neither is a phrasing problem to be fixed; both describe something a real photo
# can legitimately look like.

# A photo the device's camera produced is hers, and never chat clutter. This is a
# floor under the content rule: whatever a query claims, these are never excluded.
# Samsung writes 20260504_095315.jpg; other Androids IMG_20240428_114647.jpg.
CAMERA_NAME = re.compile(r"^(\d{8}_\d{6}|IMG_\d{8}|PXL_\d{8}|DSC[NF]?\d)", re.I)

CTX = ssl.create_default_context()
if IMMICH.startswith("http://"):
    CTX = None


def api(path, method="GET", body=None):
    req = urllib.request.Request(
        IMMICH + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"x-api-key": KEY, "Content-Type": "application/json"},
        method=method)
    try:
        with urllib.request.urlopen(req, timeout=60, context=CTX) as resp:
            return json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        detail = e.read()[:200].decode("utf8", "replace")
        raise SystemExit("%s %s -> HTTP %s %s" % (method, path, e.code, detail))


def search_ids(body, max_pages=20):
    """Every asset id matching a metadata search, following pagination."""
    out, page = [], 1
    while page and page <= max_pages:
        assets = api("/api/search/metadata", "POST", dict(body, page=page))["assets"]
        out += [a["id"] for a in assets["items"]]
        nxt = assets.get("nextPage")
        page = int(nxt) if nxt else None
    return out


def main():
    since = (datetime.now(timezone.utc) - timedelta(days=DAYS)).date().isoformat()

    # Assets added to the library recently. createdAfter (not takenAfter): a
    # forward received today can carry an old capture date, and it is the arrival
    # that makes it new to us.
    recent = set(search_ids({"size": 1000, "createdAfter": since + "T00:00:00.000Z",
                             "withExif": False}))
    already = set(search_ids({"size": 1000, "albumIds": [DROP_ALBUM]}))
    candidates = recent - already
    print("added in last %dd=%d already excluded=%d to classify=%d"
          % (DAYS, len(recent), len(already), len(candidates)))
    if not candidates:
        print("nothing new")
        return

    drop = set()

    # 1. Filename rule — unambiguous, no model involved. The window search above
    # ran with withExif=False to stay cheap and so carries no filenames; ask once
    # more for the same window, this time with them.
    named = api("/api/search/metadata", "POST",
                {"size": 1000, "createdAfter": since + "T00:00:00.000Z"})["assets"]["items"]
    for a in named:
        name = (a.get("originalFileName") or "").lower()
        if a["id"] in candidates and name.startswith("screenshot"):
            drop.add(a["id"])
    by_name = len(drop)

    # 2. Content rule — only the screen-content class.
    #
    # createdAfter is load-bearing, not an optimisation. Smart search ranks the
    # WHOLE library, and the top of that ranking is exactly what a previous run
    # already filed away — so an unwindowed query returns the same already-excluded
    # assets every week and new arrivals never surface at all. Measured on
    # 2026-08-23: unwindowed found 0 of 800 candidates; windowed, 9 of the first 10
    # hits were assets the unwindowed query never returned.
    #
    # It filters on arrival time (the row's createdAt), not the capture date in the
    # file — which is what we want, since a forward received today can carry a date
    # from years ago.
    for q in CHAT_QUERIES:
        hits = api("/api/search/smart", "POST",
                   {"query": q, "size": PER_QUERY, "type": "IMAGE",
                    "createdAfter": since + "T00:00:00.000Z"})
        for a in hits["assets"]["items"]:
            if a["id"] not in candidates:
                continue
            if CAMERA_NAME.match(a.get("originalFileName") or ""):
                continue
            drop.add(a["id"])
    print("to exclude: %d (%d by filename, %d more by content)"
          % (len(drop), by_name, len(drop) - by_name))

    if not drop:
        return
    if DRY_RUN:
        print("DRY_RUN: album untouched")
        return

    ids = sorted(drop)
    for i in range(0, len(ids), 200):
        api("/api/albums/%s/assets" % DROP_ALBUM, "PUT", {"ids": ids[i:i + 200]})
    print("filed %d into the exclusion album" % len(ids))


if __name__ == "__main__":
    sys.exit(main())
