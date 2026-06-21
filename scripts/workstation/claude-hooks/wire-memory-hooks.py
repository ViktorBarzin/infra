#!/usr/bin/env python3
"""Wire the homelab-memory hooks into a user's ~/.claude/settings.json, if-absent.

Part of the claude-memory MCP -> homelab CLI migration (all-users rollout).
Idempotent + ADDITIVE: only ADDS a hook group when no existing command references
that hook script. Never removes/reorders existing hooks, and never touches `env`
(the per-user MEMORY_API_KEY) or any other setting. Safe to run on every reconcile
and on a user's already-populated config.

Usage: wire-memory-hooks.py <home_dir>
Exit 0 on success (changed or already-present); 1 only on an unreadable settings file.
"""
import json
import os
import sys

home = sys.argv[1]
settings = os.path.join(home, ".claude", "settings.json")
hooks_dir = os.path.join(home, ".claude", "hooks")

# (event, script-basename used for the if-absent check, full command, extra fields)
WANT = [
    ("PreCompact", "pre-compact-backup.sh", f"{hooks_dir}/pre-compact-backup.sh", {"timeout": 30}),
    ("UserPromptSubmit", "post-compact-recovery.sh", f"{hooks_dir}/post-compact-recovery.sh", {"timeout": 10}),
    ("UserPromptSubmit", "homelab-memory-recall.py", f"python3 {hooks_dir}/homelab-memory-recall.py", {"timeout": 8}),
    ("Stop", "auto-learn.py", f"python3 {hooks_dir}/auto-learn.py", {"async": True}),
]

try:
    if os.path.exists(settings) and os.path.getsize(settings) > 0:
        with open(settings) as fh:
            data = json.load(fh)
    else:
        data = {}
except (json.JSONDecodeError, OSError) as e:
    print(f"ERROR: cannot read {settings}: {e}", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})
changed = False
for event, basename, command, extra in WANT:
    groups = hooks.setdefault(event, [])
    already = any(
        basename in (h.get("command", "") or "")
        for g in groups
        for h in (g.get("hooks", []) or [])
    )
    if already:
        continue
    entry = {"type": "command", "command": command}
    entry.update(extra)
    groups.append({"hooks": [entry]})
    changed = True

if changed:
    tmp = settings + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, settings)
    print(f"wired memory hooks -> {settings}")
else:
    print(f"memory hooks already present -> {settings} (no change)")
