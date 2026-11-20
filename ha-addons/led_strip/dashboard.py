#!/usr/bin/env python3
"""Rebuild the pattern section of the Livia dashboard from patterns.py.

    HA_TOKEN=... python3 dashboard.py --version 1.3.0 [--dry-run]

Each pattern becomes a picture card with its preview (/local/livia/<name>.webp,
from preview.py), grouped under a heading per group; a tap starts it. The
section holding the pattern cards is replaced; the rest of the dashboard
(the light, colours and the plug) is left as it is. deploy.sh runs this.
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


def section(version: str) -> Card:
    cards: list[Card] = [{"type": "heading", "heading": "Patterns", "icon": "mdi:animation-play"}]
    group = None
    for p in patterns.PATTERNS.values():
        if p.group != group:
            group = p.group
            cards.append({"type": "heading", "heading": group, "heading_style": "subtitle"})
        cards.append(pattern_card(p, version))
    return {"type": "grid", "cards": cards}


def is_pattern_section(s: Card) -> bool:
    return any("effect" in (c.get("tap_action", {}).get("data") or {}) for c in s.get("cards", []))


def updated(config: Card, version: str) -> Card:
    """The dashboard with its pattern section replaced, or added at the end."""
    view = config["views"][0]
    sections = view.get("sections", [])
    new = section(version)
    for i, s in enumerate(sections):
        if is_pattern_section(s):
            sections[i] = new
            break
    else:
        sections.append(new)
    view["sections"] = sections
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
