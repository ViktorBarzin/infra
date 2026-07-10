#!/usr/bin/env python3
"""
Stop hook (async): automatic learning extraction via haiku-as-judge.

After each Claude response, sends the user message + assistant response to
haiku to detect corrections, preferences, decisions, or facts worth storing.
If learning events are detected, stores them via the `homelab memory` CLI — the
only sanctioned memory path on the devvm (no direct HTTP, no local SQLite).

Runs with async: true — does NOT block the user.
"""

import io
import json
import logging
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

# ADR-0007: hard Memory content bound, in unicode CHARACTERS (not bytes) —
# derived from the recall hook's 8KB/5-results delivery budget so a ranked
# Memory always arrives whole. The server rejects oversize writes with a 422.
MEMORY_BOUND = 1400

# Shared with the recall hook — one place to look when memory hooks misbehave.
ERRORS_LOG = os.path.expanduser("~/.claude/tmp/memory-recall-errors.log")

JUDGE_PROMPT = """You are a memory extraction judge. Analyze this exchange between a user and an AI assistant.

USER MESSAGE:
{user_message}

ASSISTANT RESPONSE:
{assistant_response}

Your job: determine if any of these learning events occurred:
1. USER CORRECTION — user corrected the assistant's mistake or misunderstanding
2. PREFERENCE — user stated a preference, habit, or "I like/prefer/want" statement
3. DECISION — a decision was reached about how to do something
4. FACT — user shared a durable fact about themselves, their team, tools, or environment

If ANY learning event occurred, return JSON:
{{"events": [{{"type": "correction|preference|decision|fact", "content": "concise fact to remember (one sentence)", "importance": 0.7, "expanded_keywords": "space-separated semantically related search terms for recall (minimum 5 words)", "supersedes": null, "parts": []}}]}}

If NO learning event occurred, return:
{{"events": []}}

Rules:
- Only extract DURABLE facts, not transient task details
- Corrections are highest value (0.8-0.9)
- Be conservative — false negatives are better than false positives
- Every "content" (and every string in "parts") MUST be at most 1,400 characters and SELF-CONTAINED: understandable entirely on its own, with no reliance on other entries or unstated session context. Never "part N of M" fragments; never text that begins mid-sentence. Oversize candidates are rejected, not truncated.
- Knowledge too large for one 1,400-character memory: split it as a WRITING act — put a short self-contained hub summary in "content" and each self-contained detail as its own string in "parts" (each at most 1,400 characters). Parts are stored linked part-of the hub. Otherwise leave "parts" empty.
- "expanded_keywords" should include synonyms, related concepts, and adjacent topics that would help find this memory later
- "supersedes" should be a search query to find the old outdated memory, or null
- Return ONLY valid JSON, no other text"""


def _log_error(reason):
    """Append one timestamped line to the shared errors log; never raise."""
    try:
        os.makedirs(os.path.dirname(ERRORS_LOG), exist_ok=True)
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with open(ERRORS_LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {' '.join(str(reason).split())}\n")
    except Exception:
        pass


def _store_via_homelab_cli(content, category, tags, importance, expanded_keywords, link=None):
    """Store one memory via the homelab CLI — the only sanctioned memory path on
    the devvm (no direct HTTP, no local SQLite). The CLI defaults the API URL and
    reads CLAUDE_MEMORY_API_KEY / MEMORY_API_KEY from the environment; if neither
    is set (e.g. a user without a minted key) it no-ops silently.

    Returns the new memory id when parseable from the CLI's response JSON
    (needed to link part-of details to their hub), else None."""
    homelab = shutil.which("homelab") or "/usr/local/bin/homelab"
    if not os.path.exists(homelab):
        return None
    if not (os.environ.get("CLAUDE_MEMORY_API_KEY") or os.environ.get("MEMORY_API_KEY")):
        return None
    cmd = [
        homelab, "memory", "store", content,
        "--category", category,
        "--tags", tags,
        "--importance", str(importance),
    ]
    if expanded_keywords:
        # CLI wants comma-separated keywords; the judge emits space-separated terms.
        keywords = ",".join(expanded_keywords.replace(",", " ").split())
        if keywords:
            cmd += ["--keywords", keywords]
    if link:
        cmd += ["--link", link]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=os.environ)
    if res.returncode != 0:
        _log_error(f"auto-learn: store failed: {(res.stderr or res.stdout or '').strip()[:300]}")
        return None
    try:
        # `store` prints the API response JSON first; with --link, "linked ->"
        # lines follow on their own lines.
        return json.loads((res.stdout or "").strip().splitlines()[0]).get("id")
    except Exception:
        return None


def _store_event(event, category_map):
    """Store one judge event: guard the ADR-0007 bound, store the content (the
    hub when "parts" are present), then store each part linked part-of the hub."""
    content = (event.get("content") or "").strip()
    if not content:
        return
    event_type = event.get("type", "fact")
    importance = max(0.0, min(1.0, float(event.get("importance", 0.7))))
    category = category_map.get(event_type, "facts")
    tags = f"auto-learned,{event_type}"
    expanded_keywords = event.get("expanded_keywords", "")

    # ADR-0007 guard: reject oversize candidates — NEVER mechanically truncate
    # (mechanical chopping is exactly the fragment pollution the ADR bans).
    if len(content) > MEMORY_BOUND:
        _log_error(
            f"auto-learn: candidate rejected — {len(content)} chars exceeds the "
            f"{MEMORY_BOUND}-char Memory bound; skipped, judge must split into hub + part-of details"
        )
        return

    parts = [p.strip() for p in (event.get("parts") or []) if isinstance(p, str) and p.strip()]
    hub_id = _store_via_homelab_cli(content, category, tags, importance, expanded_keywords)
    for part in parts:
        if len(part) > MEMORY_BOUND:
            _log_error(
                f"auto-learn: part rejected — {len(part)} chars exceeds the "
                f"{MEMORY_BOUND}-char Memory bound; skipped, never truncated"
            )
            continue
        link = f"part-of:{hub_id}" if hub_id else None
        if link is None:
            _log_error("auto-learn: hub id unparseable; storing part unlinked")
        _store_via_homelab_cli(part, category, tags, importance, expanded_keywords, link=link)


def main() -> None:
    # Graceful exit if claude CLI is not available
    if not shutil.which("claude"):
        return

    try:
        hook_input = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        return

    if isinstance(hook_input, dict) and hook_input.get("stop_hook_active", False):
        return

    transcript_path = ""
    if isinstance(hook_input, dict):
        transcript_path = hook_input.get("transcript_path", "")

    if not transcript_path or not os.path.exists(transcript_path):
        return

    user_message = ""
    assistant_response = ""
    try:
        MAX_TAIL_BYTES = 50_000
        with open(transcript_path, "rb") as f:
            f.seek(0, io.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - MAX_TAIL_BYTES))
            tail = f.read().decode("utf-8", errors="replace")
        lines = tail.split("\n")

        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            role = entry.get("role", "")
            content = entry.get("content", "")
            if isinstance(content, list):
                content = " ".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                )
            content = str(content)[:2000]
            if role == "assistant" and not assistant_response:
                assistant_response = content
            elif role == "user" and not user_message:
                user_message = content
            if user_message and assistant_response:
                break
    except Exception:
        return

    if not user_message or len(user_message.strip()) < 10:
        return

    prompt = JUDGE_PROMPT.format(
        user_message=user_message,
        assistant_response=assistant_response[:1000],
    )

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--model", "haiku"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "CLAUDECODE": ""},
        )
        if result.returncode != 0:
            return
        response_text = result.stdout.strip()
        if response_text.startswith("```"):
            lines = response_text.split("\n")
            lines = [l for l in lines if not l.strip().startswith("```")]
            response_text = "\n".join(lines).strip()
        judge_result = json.loads(response_text)
        events = judge_result.get("events", [])
        if not events:
            return
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return

    category_map = {
        "correction": "preferences",
        "preference": "preferences",
        "decision": "decisions",
        "fact": "facts",
    }

    for event in events:
        try:
            _store_event(event, category_map)
        except Exception:
            pass  # Never crash the async hook


if __name__ == "__main__":
    main()
