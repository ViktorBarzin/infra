#!/usr/bin/env python3
"""Checks for tablet-downloads-sync.

Run it by hand, from anywhere, with no dependencies:

    python3 playbooks/files/devvm/tablet-downloads-sync-test.py
"""
import importlib.util
import os
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tablet-downloads-sync")


def load():
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("tablet_downloads_sync", None))
    with open(SCRIPT) as fh:
        exec(compile(fh.read(), SCRIPT, "exec"), mod.__dict__)
    return mod


def main():
    m = load()
    # Output of the find/stat command, copied from the tablet on 2026-11-22.
    listing = (
        "1606244676|1795386357|/sdcard/Download/Paddington 2 2017 1080p BluRay HEVC x265 5.1 BONE.mkv\n"
        "1039639206|1795390762|/sdcard/Download/Inception (2010) 720p.mkv\n"
        "garbage line\n"
        "12|x|/sdcard/Download/bad mtime.mkv\n"
        "\n"
    )
    got = m.parse(listing)
    assert got == [
        {"name": "Paddington 2 2017 1080p BluRay HEVC x265 5.1 BONE.mkv", "size": 1606244676, "mtime": 1795386357},
        {"name": "Inception (2010) 720p.mkv", "size": 1039639206, "mtime": 1795390762},
    ], got
    assert m.parse("") == []
    # A name with "|" in it keeps everything after the second separator.
    assert m.parse("5|6|/sdcard/Download/a|b.mkv")[0]["name"] == "a|b.mkv"
    payload = m.payload(got)
    assert payload["dir"] == "/sdcard/Download" and len(payload["files"]) == 2, payload
    print("ok")


if __name__ == "__main__":
    sys.exit(main())
