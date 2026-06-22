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

logger = logging.getLogger(__name__)

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
{{"events": [{{"type": "correction|preference|decision|fact", "content": "concise fact to remember (one sentence)", "importance": 0.7, "expanded_keywords": "space-separated semantically related search terms for recall (minimum 5 words)", "supersedes": null}}]}}

If NO learning event occurred, return:
{{"events": []}}

Rules:
- Only extract DURABLE facts, not transient task details
- Corrections are highest value (0.8-0.9)
- Be conservative — false negatives are better than false positives
- "expanded_keywords" should include synonyms, related concepts, and adjacent topics that would help find this memory later
- "supersedes" should be a search query to find the old outdated memory, or null
- Return ONLY valid JSON, no other text"""


def _store_via_homelab_cli(content, category, tags, importance, expanded_keywords):
    """Store one memory via the homelab CLI — the only sanctioned memory path on
    the devvm (no direct HTTP, no local SQLite). The CLI defaults the API URL and
    reads CLAUDE_MEMORY_API_KEY / MEMORY_API_KEY from the environment; if neither
    is set (e.g. a user without a minted key) it no-ops silently."""
    homelab = shutil.which("homelab") or "/usr/local/bin/homelab"
    if not os.path.exists(homelab):
        return
    if not (os.environ.get("CLAUDE_MEMORY_API_KEY") or os.environ.get("MEMORY_API_KEY")):
        return
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
    subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=os.environ)


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
        content = event.get("content", "")
        if not content:
            continue
        event_type = event.get("type", "fact")
        importance = max(0.0, min(1.0, float(event.get("importance", 0.7))))
        category = category_map.get(event_type, "facts")
        tags = f"auto-learned,{event_type}"
        expanded_keywords = event.get("expanded_keywords", "")

        try:
            _store_via_homelab_cli(content, category, tags, importance, expanded_keywords)
        except Exception:
            pass  # Never crash the async hook


if __name__ == "__main__":
    main()
