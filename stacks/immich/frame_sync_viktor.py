#!/usr/bin/env python3
"""Keep Viktor's photo frame to photos of Viktor, Anca, or nobody.

The frame (frame.tf) shows his whole library minus one exclusion album. This job
keeps that album equal to "photos with faces, none of them Viktor's or Anca's":
a photo with either of them stays, a photo with no faces (a landscape) stays,
a photo of only other people goes.

Two sources of faces, because neither is complete on its own:

  - POST /api/search/metadata with withPeople lists the faces assigned to a
    person, for the whole library in ~70 requests. It omits unassigned faces:
    a face Immich has seen fewer than three times is not clustered into anyone,
    and on 2026-11-25 that left 2,038 photos with a stranger looking like
    landscapes.
  - GET /api/faces?id= lists every face, one request per photo. It is asked
    only for photos added in the last WINDOW_DAYS that have no assigned person.

Older photos with no assigned person keep the membership they have. The album
was seeded from the database on 2026-11-25 with the exact classification, so
that membership is right, and Immich only adds faces to a photo when it first
processes it.

The job both adds and removes. It removes when recognition later clusters a
face into Viktor or Anca, so a photo hidden as a stranger comes back. The album
is the job's own: a photo added to it by hand is removed on the next run if it
shows Viktor or Anca.

Pure stdlib on a stock python image; never pip/apk install in a CronJob.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def plan(assets, in_album, us, has_faces, now, window_days):
    """Return (ids to add to the exclusion album, ids to remove from it)."""
    since = now - timedelta(days=window_days)
    add, remove = set(), set()
    for a in assets:
        people = {p["id"] for p in a.get("people") or []}
        if people & us:
            hide = False
        elif people:
            hide = True
        elif _parse(a["createdAt"]) >= since:
            hide = has_faces(a["id"])
        else:
            continue
        if hide and a["id"] not in in_album:
            add.add(a["id"])
        elif not hide and a["id"] in in_album:
            remove.add(a["id"])
    return add, remove


def _parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def main():
    immich = os.environ["IMMICH_URL"].rstrip("/")
    key = os.environ["IMMICH_API_KEY"]
    album = os.environ["DROP_ALBUM"]
    us = set(os.environ["KEEP_PEOPLE"].split(","))
    window_days = int(os.environ.get("WINDOW_DAYS", "14"))
    dry_run = os.environ.get("DRY_RUN", "false").lower() in ("1", "true", "yes")

    def api(path, method="GET", body=None):
        req = urllib.request.Request(
            immich + path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"x-api-key": key, "Content-Type": "application/json"},
            method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as e:
            detail = e.read()[:200].decode("utf8", "replace")
            raise SystemExit("%s %s -> HTTP %s %s" % (method, path, e.code, detail))

    def search(body):
        out, page = [], 1
        while page:
            res = api("/api/search/metadata", "POST", dict(body, size=1000, page=page))
            out += res["assets"]["items"]
            page = int(res["assets"]["nextPage"] or 0)
        return out

    # Same pool as the frame: images on the timeline, not archived or trashed.
    assets = search({"type": "IMAGE", "visibility": "timeline", "withPeople": True})
    in_album = {a["id"] for a in search({"albumIds": [album]})}
    lookups = []

    def has_faces(aid):
        lookups.append(aid)
        return bool(api("/api/faces?id=" + aid))

    add, remove = plan(assets, in_album, us, has_faces,
                       datetime.now(timezone.utc), window_days)
    print("library=%d hidden=%d faces-lookups=%d add=%d remove=%d"
          % (len(assets), len(in_album), len(lookups), len(add), len(remove)))
    if dry_run:
        print("DRY_RUN: album untouched")
        return
    for method, ids in (("PUT", sorted(add)), ("DELETE", sorted(remove))):
        for i in range(0, len(ids), 500):
            api("/api/albums/%s/assets" % album, method, {"ids": ids[i:i + 500]})


if __name__ == "__main__":
    sys.exit(main())
