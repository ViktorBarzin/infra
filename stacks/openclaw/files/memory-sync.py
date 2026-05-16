"""claude-memory → OpenClaw memory-core sync.

Pulls memories from the central claude-memory REST API, writes per-category
Markdown files into /workspace/memory/projects/claude-memory-sync/
which memory-core picks up via its QMD backend.

Runs inside the openclaw pod (piped via `kubectl exec -i -- python3 -`).
Uses MEMORY_API_URL + MEMORY_API_KEY env vars already set on the pod.

Filters out is_sensitive=true memories. Also one-shot deletes the stale
metaclaw-export.json from a prior export attempt.
"""

import json
import os
import pathlib
import sys
import time
import urllib.request


def main() -> int:
    api_url = os.environ["MEMORY_API_URL"].rstrip("/")
    api_key = os.environ["MEMORY_API_KEY"]

    req = urllib.request.Request(
        f"{api_url}/api/memories?limit=10000",
        headers={"Authorization": f"Bearer {api_key}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)

    raw = data.get("memories", [])
    mems = [m for m in raw if not m.get("is_sensitive", False)]
    sensitive_count = len(raw) - len(mems)

    by_cat: dict[str, list[dict]] = {}
    for m in mems:
        by_cat.setdefault(m.get("category") or "uncategorized", []).append(m)

    # Write under /workspace/memory/ — memory-core's QMD backend auto-indexes
    # this path on every reindex. /home/node/.openclaw/memory/ is the
    # SQLite index location, not a content source.
    out_dir = pathlib.Path("/workspace/memory/projects/claude-memory-sync")
    out_dir.mkdir(parents=True, exist_ok=True)

    stamp = time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime())
    for cat, items in sorted(by_cat.items()):
        items.sort(key=lambda x: x.get("id", 0))
        lines = [
            f"# {cat.title()} memories",
            "",
            f"_Synced from claude-memory at {stamp}. {len(items)} memories._",
            "",
        ]
        for m in items:
            content = m.get("content") or ""
            first_line = content.splitlines()[0] if content else ""
            title = first_line.lstrip("# ").strip()[:120] or f"#{m['id']}"
            lines.extend([
                f"## #{m['id']} — {title}",
                "",
                f"- Tags: `{m.get('tags', '')}`",
                f"- Importance: {float(m.get('importance', 0.5)):.2f}",
                f"- Created: {m.get('created_at', '?')}",
                f"- Updated: {m.get('updated_at', '?')}",
                "",
                content,
                "",
                "---",
                "",
            ])
        (out_dir / f"{cat}.md").write_text("\n".join(lines))

    # One-shot: nuke the stale 2026-02-28 export sitting next to memory-core.
    stale = pathlib.Path("/home/node/.openclaw/memory/metaclaw-export.json")
    if stale.exists():
        stale.unlink()
        print("[sync] deleted stale metaclaw-export.json")

    total = sum(len(v) for v in by_cat.values())
    print(
        f"[sync] wrote {total} memories across {len(by_cat)} categories to "
        f"{out_dir} (skipped {sensitive_count} sensitive)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
