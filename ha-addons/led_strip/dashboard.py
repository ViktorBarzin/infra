#!/usr/bin/env python3
"""Rebuild the pattern sections of the Livia dashboard from patterns.py.

    HA_TOKEN=... python3 dashboard.py --version 1.3.0 [--dry-run]

Each group of patterns becomes one section: a heading, then a picture card
per pattern with its preview (/local/livia/<name>.webp, from preview.py); a
tap starts it. The view is up to four sections wide with dense placement, so
on a wide screen the groups sit side by side, and on a phone they stack. The
sections holding pattern cards are replaced; the rest of the dashboard (the
light, colours and the plug) is left as it is. deploy.sh runs this.
"""

import argparse
import asyncio
import json
import os
from typing import Any

import patterns

URL = "wss://ha-london.viktorbarzin.me/api/websocket"
DASHBOARD = "livia-strip"
LIGHT = "light.livia"
MAX_COLUMNS = 4
Card = dict[str, Any]


def pattern_card(p: patterns.Pattern, version: str) -> Card:
    return {
        "type": "picture",
        "image": f"/local/livia/{p.name}.webp?v={version}",
        "alt_text": f"{p.title}: {p.about}",
        "tap_action": {
            "action": "perform-action",
            "perform_action": "light.turn_on",
            "target": {"entity_id": LIGHT},
            "data": {"effect": p.name},
        },
        "grid_options": {"columns": 12},
    }


def sections(version: str) -> list[Card]:
    """One section per group, in the order of PATTERNS."""
    groups: dict[str, list[Card]] = {}
    for p in patterns.PATTERNS.values():
        groups.setdefault(p.group, [{"type": "heading", "heading": p.group}]).append(pattern_card(p, version))
    return [{"type": "grid", "cards": cards} for cards in groups.values()]


def is_pattern_section(s: Card) -> bool:
    return any("effect" in (c.get("tap_action", {}).get("data") or {}) for c in s.get("cards", []))


def updated(config: Card, version: str) -> Card:
    """The dashboard with its pattern sections replaced, where the first one was."""
    view = config["views"][0]
    old = view.get("sections", [])
    at = next((i for i, s in enumerate(old) if is_pattern_section(s)), len(old))
    kept = [s for s in old if not is_pattern_section(s)]
    view["sections"] = kept[:at] + sections(version) + kept[at:]
    view["max_columns"] = MAX_COLUMNS
    view["dense_section_placement"] = True
    return config


async def call(ws: Any, msg_id: int, msg: Card) -> Any:
    await ws.send(json.dumps({**msg, "id": msg_id}))
    reply = json.loads(await ws.recv())
    if not reply.get("success"):
        raise SystemExit(f"{msg['type']} failed: {reply.get('error')}")
    return reply.get("result")


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", required=True, help="add-on version, busts the image cache")
    parser.add_argument("--dry-run", action="store_true", help="print the new config, save nothing")
    args = parser.parse_args()

    import websockets  # on the devvm only

    async with websockets.connect(URL, max_size=None) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": os.environ["HA_TOKEN"]}))
        if json.loads(await ws.recv())["type"] != "auth_ok":
            raise SystemExit("Home Assistant refused the token")
        config = await call(ws, 1, {"type": "lovelace/config", "url_path": DASHBOARD})
        config = updated(config, args.version)
        if args.dry_run:
            print(json.dumps(config, indent=1))
            return
        await call(ws, 2, {"type": "lovelace/config/save", "url_path": DASHBOARD, "config": config})
        print(f"dashboard {DASHBOARD}: {len(patterns.PATTERNS)} patterns")


if __name__ == "__main__":
    asyncio.run(main())
