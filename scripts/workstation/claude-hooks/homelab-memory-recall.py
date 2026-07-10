#!/usr/bin/env python3
"""UserPromptSubmit hook: inject relevant memories via `homelab memory recall`.

Runs the homelab CLI (a direct client to the claude-memory HTTP API) with
`--json` and injects a compact, bounded rendering as additionalContext — recall
is automatic, needs no model tool-call, and works with the MCP uninstalled.

Delivery contract (ADR-0007 "Bounded self-contained Memories with typed Links"):
- recall 10, inject the top 5 UNSEEN results — ids already injected this
  session (seen-file ~/.claude/tmp/memory-recall-seen-<session_id>.ids) are
  dropped so the same memories don't repeat every turn;
- resolved-by attachments riding along in the response (marked `attached_via`)
  render indented under their source and don't count toward the 5;
- part-of / see-also links render as one-line pointers; `redirected_from`
  (supersedes redirect) renders as a note;
- legacy >1,400-char entries are clipped at 1,200 CHARACTERS (character
  boundary — never byte-slice: a mid-rune cut on Cyrillic once crashed this
  hook) with a read-more pointer;
- the whole injection is hard-capped at 8,000 BYTES by dropping WHOLE entries
  from the tail (a ranked Memory always arrives complete), keeping us under
  the harness's ~10KB persist threshold;
- zero new results -> no output at all (no empty-context injection).

Silent skips (steady states, parity with the pre-rewrite production hook — NOT
errors, so they never touch the errors log): prompts under MIN_PROMPT_CHARS;
prompts opening with a backtick/{/< (pasted code/JSON/XML blobs, not recall
queries); no homelab binary on the box; a wired-but-keyless user (documented
steady state until an admin mints a MEMORY_API_KEY — multi-tenancy.md).

Best-effort: every real failure (timeout, CLI error, bad JSON, IO) appends one
line to ~/.claude/tmp/memory-recall-errors.log (rotated once past
ERRORS_LOG_MAX_BYTES) and exits 0 silently — recall just doesn't happen that
turn; the user's prompt is never broken. Per-session seen-files idle past
SEEN_TTL_S are pruned when a new session starts, so ~/.claude/tmp never
accumulates them unboundedly.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

TMP_DIR = os.path.expanduser("~/.claude/tmp")
MIN_PROMPT_CHARS = 15
RECALL_LIMIT = 10
INJECT_LIMIT = 5
RECALL_TIMEOUT_S = 6
CONTEXT_BYTE_CAP = 8000
CLIP_THRESHOLD = 1400  # the ADR-0007 Memory bound; only legacy entries exceed it
CLIP_AT = 1200
SEEN_TTL_S = 7 * 24 * 3600     # a seen-file's mtime refreshes on every injection
ERRORS_LOG_MAX_BYTES = 262_144  # ~256KB, then one rotation generation (.1)

# Link types rendered as one-line pointers. supersedes redirects (the API
# serves the successor, flagging `redirected_from`) and resolved-by
# auto-attaches its target (flagged `attached_via`), so neither is a pointer.
POINTER_LINK_TYPES = ("part-of", "see-also")

PREAMBLE = (
    "Relevant stored memories (via `homelab memory recall`) — incorporate "
    "naturally if useful; do NOT mention this lookup to the user:\n\n"
)


def errors_log_path():
    return os.path.join(TMP_DIR, "memory-recall-errors.log")


def seen_file_path(session_id):
    return os.path.join(TMP_DIR, f"memory-recall-seen-{session_id}.ids")


def log_error(reason):
    """Append one timestamped line to the errors log; never raise.

    Bounded: past ERRORS_LOG_MAX_BYTES the log rotates once to `.1` (worst
    case ~2x the cap on disk) — diagnostics, not an unbounded audit trail.
    """
    try:
        os.makedirs(TMP_DIR, exist_ok=True)
        path = errors_log_path()
        try:
            if os.path.getsize(path) > ERRORS_LOG_MAX_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            pass  # no log yet, or a concurrent rotation won the race
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        line = " ".join(str(reason).split()) or "unknown error"
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {line}\n")
    except Exception:
        pass


def _homelab_path():
    """Absolute path of the homelab CLI, or None when absent from this box."""
    path = shutil.which("homelab") or "/usr/local/bin/homelab"
    return path if os.path.exists(path) else None


def prune_stale_seen_files(now=None):
    """Delete per-session seen-files idle past SEEN_TTL_S; never raise.

    A seen-file's mtime refreshes on every injection, so idle == the session is
    long gone (worst case a revived ancient session re-injects once). Called
    only when a NEW session's seen-file is about to appear — one directory scan
    per session, and the files can no longer accumulate unboundedly. The errors
    log has a different name and is never touched.
    """
    now = time.time() if now is None else now
    try:
        for entry in os.scandir(TMP_DIR):
            if (entry.name.startswith("memory-recall-seen-")
                    and entry.name.endswith(".ids")
                    and entry.is_file()
                    and now - entry.stat().st_mtime > SEEN_TTL_S):
                try:
                    os.unlink(entry.path)
                except OSError:
                    pass
    except OSError:
        pass  # TMP_DIR missing on a fresh box — nothing to prune


def _as_int(value):
    """Positive int from an id-ish value (int/float/digit-string), else 0."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value if value > 0 else 0
    if isinstance(value, float) and value > 0 and value.is_integer():
        return int(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return 0


def _score(m):
    """Display score: the fused relevance rank when present, else importance."""
    rank = m.get("rank")
    if isinstance(rank, (int, float)) and not isinstance(rank, bool) and rank > 0:
        return float(rank)
    imp = m.get("importance")
    if isinstance(imp, (int, float)) and not isinstance(imp, bool):
        return float(imp)
    return 0.0


def render_memory_line(m, indent="", prefix=""):
    """One compact line: '#<id> [<category>] (<score>) <content>'.

    Legacy oversize content is clipped at CLIP_AT unicode CHARACTERS (python
    str slicing is character-based, so multibyte runes are never split) with a
    pointer to the full entry.
    """
    mid = _as_int(m.get("id"))
    category = str(m.get("category") or "?")
    content = " ".join(str(m.get("content") or "").splitlines())
    if len(content) > CLIP_THRESHOLD:
        content = content[:CLIP_AT] + f"… [full: homelab memory get {mid}]"
    return f"{indent}{prefix}#{mid} [{category}] ({_score(m):.2f}) {content}"


def link_pointer_lines(m):
    """Pointer-only link types (part-of, see-also) as one-line pointers.

    Tolerates the field names the API may use (`links`, `links_out`,
    `links_in`) and either end key (`target_id` / `source_id` / `id`).
    """
    lines, emitted = [], set()
    for key in ("links", "links_out", "links_in"):
        for link in m.get(key) or []:
            if not isinstance(link, dict):
                continue
            ltype = link.get("type")
            if ltype not in POINTER_LINK_TYPES:
                continue
            other = (_as_int(link.get("target_id"))
                     or _as_int(link.get("source_id"))
                     or _as_int(link.get("id")))
            if other and (ltype, other) not in emitted:
                emitted.add((ltype, other))
                lines.append(f"  ↳ see #{other} ({ltype})")
    return lines


def redirect_lines(m):
    """Notes for supersedes redirects: this entry was served in place of the
    superseded id(s) in `redirected_from` (int, digit-string, dict, or list)."""
    raw = m.get("redirected_from")
    values = raw if isinstance(raw, list) else [raw] if raw is not None else []
    lines = []
    for v in values:
        if isinstance(v, dict):
            old = (_as_int(v.get("id")) or _as_int(v.get("source_id"))
                   or _as_int(v.get("memory_id")))
        else:
            old = _as_int(v)
        if old:
            lines.append(f"  ↳ redirected from #{old} (supersedes)")
    return lines


def attachment_source_id(m):
    """Source memory id an `attached_via` attachment rides with, else 0.

    Tolerates a dict ({'type': 'resolved-by', 'source_id': N} and friends),
    a bare id, or a '<type>:<id>' string.
    """
    av = m.get("attached_via")
    if isinstance(av, dict):
        for key in ("source_id", "source", "memory_id", "from_id", "id"):
            got = _as_int(av.get(key))
            if got:
                return got
        return 0
    got = _as_int(av)
    if got:
        return got
    if isinstance(av, str) and ":" in av:
        return _as_int(av.rsplit(":", 1)[-1])
    return 0


def select_blocks(memories, seen):
    """Pick the top INJECT_LIMIT unseen ranked results, in response (=rank)
    order, each with its unseen resolved-by attachments.

    Attachments (entries carrying a truthy `attached_via`) never count toward
    the limit; one whose source id is unparseable rides with the ranked entry
    it arrived immediately after. Attachments whose source was dropped (or
    which were themselves already seen) are dropped.
    """
    blocks, order, used = {}, [], set()
    last_ranked_id = 0
    for m in memories:
        if not isinstance(m, dict):
            continue
        mid = _as_int(m.get("id"))
        if m.get("attached_via"):
            src = attachment_source_id(m) or last_ranked_id
            if src in blocks and mid and mid not in seen and mid not in used:
                blocks[src]["attachments"].append(m)
                used.add(mid)
            continue
        last_ranked_id = mid or last_ranked_id
        if not mid or mid in seen or mid in used or len(order) >= INJECT_LIMIT:
            continue
        blocks[mid] = {"main": m, "attachments": []}
        order.append(mid)
        used.add(mid)
    return [blocks[i] for i in order]


def render_block(block):
    """Render one ranked memory with its pointers, redirect notes and
    attachments. Returns (text, ids injected by this block)."""
    main = block["main"]
    lines = [render_memory_line(main)]
    lines += link_pointer_lines(main)
    lines += redirect_lines(main)
    ids = [_as_int(main.get("id"))]
    for att in block["attachments"]:
        lines.append(render_memory_line(att, indent="  ", prefix="↳ resolved-by "))
        ids.append(_as_int(att.get("id")))
    return "\n".join(lines), [i for i in ids if i]


def build_context(payload, seen):
    """(additionalContext, injected ids) from a recall --json payload, or
    (None, []) when nothing new survives.

    Hard-caps the context at CONTEXT_BYTE_CAP utf-8 bytes by dropping WHOLE
    blocks from the tail — a partial entry is never emitted (ADR-0007:
    a ranked Memory always arrives complete).
    """
    memories = payload.get("memories") if isinstance(payload, dict) else None
    rendered = [render_block(b) for b in select_blocks(memories or [], seen)]
    while rendered:
        context = PREAMBLE + "\n".join(text for text, _ in rendered)
        if len(context.encode("utf-8")) <= CONTEXT_BYTE_CAP:
            return context, [i for _, ids in rendered for i in ids]
        rendered.pop()
    return None, []


def load_seen(path):
    if not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as fh:
        return {i for i in (_as_int(line.strip()) for line in fh) if i}


def append_seen(path, ids):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.writelines(f"{i}\n" for i in ids)


def _run():
    try:
        hook_input = json.load(sys.stdin)
    except Exception as exc:
        log_error(f"bad hook input: {type(exc).__name__}: {exc}")
        return
    if not isinstance(hook_input, dict):
        log_error("bad hook input: not a JSON object")
        return

    prompt = str(hook_input.get("prompt") or "").strip()
    if len(prompt) < MIN_PROMPT_CHARS:
        return  # by design: too short to recall against — silent, not an error
    if prompt[0] in "`{<":
        return  # pasted code/JSON/XML blob, not a recall query — silent by design

    # Steady-state preflights (parity with the pre-rewrite hook): no CLI on the
    # box, or a wired-but-keyless user (documented until an admin mints a key —
    # multi-tenancy.md), must NOT append an error line on every prompt forever.
    homelab = _homelab_path()
    if homelab is None:
        return
    if not (os.environ.get("CLAUDE_MEMORY_API_KEY") or os.environ.get("MEMORY_API_KEY")):
        return

    session_id = re.sub(
        r"[^A-Za-z0-9._-]", "_", str(hook_input.get("session_id") or "unknown")
    )[:120] or "unknown"
    seen_path = seen_file_path(session_id)
    if not os.path.exists(seen_path):
        prune_stale_seen_files()  # session start: sweep long-idle sessions' files

    cmd = [homelab, "memory", "recall", prompt, "--limit", str(RECALL_LIMIT), "--json"]
    try:
        res = subprocess.run(
            cmd, capture_output=True, text=True, errors="replace",
            timeout=RECALL_TIMEOUT_S, env=os.environ,
        )
    except Exception as exc:
        log_error(f"recall failed: {type(exc).__name__}: {exc}")
        return
    if res.returncode != 0:
        detail = (res.stderr or res.stdout or "").strip()[:300]
        log_error(f"recall exited {res.returncode}: {detail}")
        return

    try:
        payload = json.loads(res.stdout or "")
    except Exception as exc:
        log_error(f"recall output not JSON: {type(exc).__name__}: {exc}")
        return

    context, injected = build_context(payload, load_seen(seen_path))
    if not context:
        return  # nothing new to inject — silent by design

    append_seen(seen_path, injected)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    }))


def main():
    try:
        _run()
    except Exception as exc:  # never break the user's prompt
        log_error(f"unhandled: {type(exc).__name__}: {exc}")


if __name__ == "__main__":
    main()
