#!/usr/bin/env python3
"""UserPromptSubmit hook: inject relevant memories via `homelab memory recall`.

Replaces the claude-memory MCP recall path. Instead of instructing the model to
call the memory_recall MCP tool, this hook runs the homelab CLI (a direct client
to the same claude-memory HTTP API) and injects the ACTUAL results as context —
so recall is automatic, needs no model tool-call, and works with the MCP
uninstalled. Best-effort: any failure exits 0 silently (recall just doesn't
happen that turn, exactly like the MCP being unavailable).

Wizard-only trial of the MCP deprecation (2026-06-20). Reversible: restore the
plugin command in ~/.claude/settings.json (backup: settings.json.bak-pre-homelab-memory).
"""

import json
import os
import shutil
import subprocess
import sys


def main() -> None:
    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        return

    prompt = ""
    if isinstance(hook_input, dict):
        prompt = hook_input.get("prompt") or hook_input.get("user_prompt") or ""
        if not prompt and isinstance(hook_input.get("content"), str):
            prompt = hook_input["content"]
    prompt = (prompt or "").strip()

    # Same gates as the original recall hook: skip short prompts, code/JSON/XML blobs.
    if len(prompt) < 10 or prompt[0] in "`{<":
        return

    homelab = shutil.which("homelab") or "/usr/local/bin/homelab"
    if not os.path.exists(homelab):
        return
    if not (os.environ.get("CLAUDE_MEMORY_API_KEY") or os.environ.get("MEMORY_API_KEY")):
        return

    try:
        res = subprocess.run(
            [homelab, "memory", "recall", prompt, "--limit", "5"],
            capture_output=True, text=True, errors="replace", timeout=4,
            env=os.environ,
        )
    except Exception:
        # Best-effort: ANY failure — timeout, OSError, or a UnicodeDecodeError on
        # truncated multibyte (Cyrillic) output — must silently skip recall this
        # turn, exactly like the MCP being unavailable. errors="replace" above
        # also keeps a mid-rune-truncated payload from raising here at all. Never
        # let this hook surface a "UserPromptSubmit hook error".
        return

    out = (res.stdout or "").strip()
    if res.returncode != 0 or not out:
        return

    context = (
        "Relevant stored memories (via `homelab memory recall`) — incorporate "
        "naturally if useful; do NOT mention this lookup to the user:\n\n" + out
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    }))


if __name__ == "__main__":
    main()
