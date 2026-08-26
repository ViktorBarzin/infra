#!/usr/bin/env python3
"""Wire the standard homelab hooks into a user's ~/.claude/settings.json.

(Named for its original memory-only scope; it now wires the whole hook set,
including the PreToolUse zsh-guard.)

Part of the claude-memory MCP -> homelab CLI migration (all-users rollout).
Two passes, idempotent, never touching `env` (the per-user MEMORY_API_KEY) or any
other setting:
  (0) PRUNE any hook command still pointing at the retired claude-memory plugin
      (`plugins/claude-memory/hooks/`). install_memory() rm -rf's that dir, so
      those entries are dangling — and a missing UserPromptSubmit hook exits 2,
      a BLOCKING error that erases the prompt and freezes the session (devvm emo
      incident 2026-06-22). Must run BEFORE the additive pass: the plugin shares
      basenames with the homelab hooks, so without pruning, the "already present"
      check below matches the dead plugin path and skips the real install.
  (1) ADD each homelab hook group when no existing command references its script.

Usage: wire-memory-hooks.py <home_dir>
Exit 0 on success (changed or already-present); 1 only on an unreadable settings file.
"""
import json
import os
import sys

home = sys.argv[1]
settings = os.path.join(home, ".claude", "settings.json")
hooks_dir = os.path.join(home, ".claude", "hooks")

# (event, script-basename used for the if-absent check, full command, extra fields, group matcher)
# `matcher` scopes a group to a tool (PreToolUse only); None means "every event".
WANT = [
    ("PreCompact", "pre-compact-backup.sh", f"{hooks_dir}/pre-compact-backup.sh", {"timeout": 30}, None),
    ("UserPromptSubmit", "post-compact-recovery.sh", f"{hooks_dir}/post-compact-recovery.sh", {"timeout": 10}, None),
    ("UserPromptSubmit", "homelab-memory-recall.py", f"python3 {hooks_dir}/homelab-memory-recall.py", {"timeout": 8}, None),
    ("Stop", "auto-learn.py", f"python3 {hooks_dir}/auto-learn.py", {"async": True}, None),
    # zsh-vs-bash guard: blocks unquoted $VAR flag-lists (zsh does not word-split)
    # and unquoted `word(...)` (zsh globs it away). Both fail silently otherwise.
    ("PreToolUse", "zsh-guard.py", f"python3 {hooks_dir}/zsh-guard.py", {"timeout": 5}, "Bash"),
    # Access-wall reminder: when a command output carries a real denial (kubectl
    # RBAC, Vault policy, sudo), name the route past it — file a `broken` issue
    # and the fixer repairs it. In a hook rather than prose because it has to
    # land at the moment the wall is hit, not whenever the model recalls it.
    ("PostToolUse", "fixer-suggest.py", f"python3 {hooks_dir}/fixer-suggest.py", {"timeout": 5}, "Bash"),
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

# (0) Prune dead claude-memory plugin hooks (see module docstring). Must precede
# the additive pass so shared basenames don't mask a needed install.
DEAD_REF = "plugins/claude-memory/hooks/"
for event in list(hooks.keys()):
    new_groups = []
    removed_any = False
    for g in (hooks.get(event) or []):
        original = g.get("hooks") or []
        kept = [h for h in original if DEAD_REF not in (h.get("command", "") or "")]
        if len(kept) != len(original):
            removed_any = True
        if kept:
            new_groups.append({**g, "hooks": kept})
    if removed_any:
        changed = True
        if new_groups:
            hooks[event] = new_groups
        else:
            del hooks[event]

# (1) Additively wire each homelab hook, if no command already references it.
for event, basename, command, extra, matcher in WANT:
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
    group = {"hooks": [entry]}
    if matcher:
        group["matcher"] = matcher
    groups.append(group)
    changed = True

if changed:
    tmp = settings + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, settings)
    print(f"wired memory hooks -> {settings}")
else:
    print(f"memory hooks already present -> {settings} (no change)")
