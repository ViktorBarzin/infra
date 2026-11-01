#!/usr/bin/env python3
"""Add albums shared with Milka to her photo frame's settings.

Runs as an init container in the immich-frame-milka pod (see frame-milka.tf).
It reads the Settings.yml template from the ConfigMap, asks Immich which albums
other people have shared with her, and writes the final Settings.yml into the
frame's config directory.

Why a second account rather than an Albums: entry on the first one: ImmichFrame
v1.0.39.0 turns Albums into an OR-branch of the search filter, so setting it
narrows the frame to those albums and drops her own library. A second account
with the same key and only Albums set gives "her library plus shared albums".
ImmichFrame picks between accounts weighted by each one's photo count, so every
photo has an equal chance of being shown.

Her own library search never returns shared-album photos: /api/search/random
only returns assets she owns (200 of 200 on 2026-11-01). With an album filter
the same key does return the album owner's assets, which is what makes this work.

If Immich cannot be reached, the frame still starts with the template as-is
(her own photos only) rather than staying down.

Pure stdlib on a stock python image.
"""
import json
import os
import sys
import urllib.error
import urllib.request

MARKER = "# shared-albums-account"


def shared_album_ids(albums, me, excluded):
    """Ids of albums someone other than `me` owns, minus `excluded`, sorted."""
    out = set()
    for a in albums:
        owners = [u["user"]["id"] for u in a.get("albumUsers") or []
                  if u.get("role") == "owner"]
        if owners and me not in owners and a["id"] not in excluded:
            out.add(a["id"])
    return sorted(out)


def render(template, album_ids, server_url, api_key, excluded):
    """Replace the marker line with a second account showing `album_ids`.

    The marker's indentation is the list-item indentation of Accounts, so the
    block is emitted at that indent and stays valid YAML.
    """
    lines = template.splitlines(keepends=True)
    idx = next((i for i, l in enumerate(lines) if l.strip() == MARKER), None)
    if idx is None:
        raise ValueError("Settings.yml template has no %r line" % MARKER)
    if not album_ids:
        return "".join(lines[:idx] + lines[idx + 1:])
    ind = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
    block = [ind + "- ImmichServerUrl: %s\n" % server_url,
             ind + "  ApiKey: %s\n" % api_key]
    if excluded:
        block.append(ind + "  ExcludedAlbums:\n")
        block += [ind + "    - %s\n" % e for e in excluded]
    block.append(ind + "  Albums:\n")
    block += [ind + "    - %s\n" % a for a in album_ids]
    return "".join(lines[:idx] + block + lines[idx + 1:])


def api(base, key, path):
    req = urllib.request.Request(base + path, headers={"x-api-key": key})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def main():
    base = os.environ["IMMICH_URL"].rstrip("/")
    key = os.environ["IMMICH_API_KEY"]
    server_url = os.environ["FRAME_SERVER_URL"]
    excluded = [e for e in os.environ.get("EXCLUDED_ALBUMS", "").split(",") if e]
    src, dst = os.environ["TEMPLATE"], os.environ["OUTPUT"]

    with open(src) as f:
        template = f.read()
    try:
        me = api(base, key, "/api/users/me")["id"]
        albums = api(base, key, "/api/albums?shared=true")
        ids = shared_album_ids(albums, me, excluded)
        names = {a["id"]: a.get("albumName") for a in albums}
        for i in ids:
            print("shared album %s %s" % (i, names.get(i)))
        print("%d shared album(s) added to the frame" % len(ids))
    except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
        print("could not list shared albums, starting with her library only: %s" % e,
              file=sys.stderr)
        ids = []
    with open(dst, "w") as f:
        f.write(render(template, ids, server_url, key, excluded))


if __name__ == "__main__":
    main()
