#!/usr/bin/env python3
"""
Stop hook (async): automatic learning extraction via haiku-as-judge.

After each Claude response, sends the user message + assistant response to
haiku to detect corrections, preferences, decisions, or facts worth storing.
If learning events are detected, stores them via the `homelab memory` CLI — the
only sanctioned memory path on the devvm (no direct HTTP, no local SQLite).

ADR-0007: every stored Memory is bounded (1,400 chars) and self-contained;
oversize knowledge is split by the judge into a hub + part-of details. The
part-of link rides `homelab memory store --link`, which only v0.13.0+ CLIs
understand — and hooks deploy hourly while the binary is rebuilt by the same
reconcile only on a cli/VERSION change — so --link is capability-gated
(usage-line probe): an older deployed CLI stores parts UNLINKED (they are
self-contained by contract) instead of silently polluting content with a
stray "part-of:<id>" suffix.

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
ERRORS_LOG_MAX_BYTES = 262_144  # ~256KB, then one rotation generation (.1)

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
    """Append one timestamped line to the shared errors log; never raise.

    Bounded like the recall hook's: past ERRORS_LOG_MAX_BYTES the log rotates
    once to `.1` (worst case ~2x the cap on disk).
    """
    try:
        os.makedirs(os.path.dirname(ERRORS_LOG), exist_ok=True)
        try:
            if os.path.getsize(ERRORS_LOG) > ERRORS_LOG_MAX_BYTES:
                os.replace(ERRORS_LOG, ERRORS_LOG + ".1")
        except OSError:
            pass  # no log yet, or a concurrent rotation won the race
        stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with open(ERRORS_LOG, "a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {' '.join(str(reason).split())}\n")
    except Exception:
        pass


def _homelab_path():
    """Absolute path of the homelab CLI, or None when absent from this box."""
    path = shutil.which("homelab") or "/usr/local/bin/homelab"
    return path if os.path.exists(path) else None


# Memoized result of the --link capability probe (None = not probed yet).
_LINK_SUPPORT = None


def _cli_supports_link():
    """True iff the DEPLOYED homelab CLI advertises `--link` on memory store.

    Hooks and the CLI deploy on different clocks: the hourly reconcile
    (t3-provision-users) refreshes the hook scripts every run but rebuilds
    /usr/local/bin/homelab only on a cli/VERSION change — and not at all when
    go is absent or the build fails. A pre-v0.13.0 `memory store` treats
    `--link` as an unknown flag and swallows its VALUE into the stored CONTENT
    ("<part text> part-of:77", exit 0 — silent durable pollution), so --link
    must never be passed on faith.

    Probe: `homelab memory store --help` prints the usage line without any
    network call or API key (the empty-content check precedes the HTTP client);
    v0.13.0+ usage advertises "[--link type:id ...]". Memoized per process;
    any probe failure counts as no support (degrade to unlinked, never risk
    polluting the durable store).
    """
    global _LINK_SUPPORT
    if _LINK_SUPPORT is None:
        homelab = _homelab_path()
        if homelab is None:
            _LINK_SUPPORT = False
            return _LINK_SUPPORT
        try:
            res = subprocess.run(
                [homelab, "memory", "store", "--help"],
                capture_output=True, text=True, timeout=10, env=os.environ,
            )
            _LINK_SUPPORT = "--link" in ((res.stdout or "") + (res.stderr or ""))
        except Exception:
            _LINK_SUPPORT = False
    return _LINK_SUPPORT


def _store_via_homelab_cli(content, category, tags, importance, expanded_keywords, link=None):
    """Store one memory via the homelab CLI — the only sanctioned memory path on
    the devvm (no direct HTTP, no local SQLite). The CLI defaults the API URL and
    reads CLAUDE_MEMORY_API_KEY / MEMORY_API_KEY from the environment; if neither
    is set (e.g. a user without a minted key) it no-ops silently.

    Returns the new memory id when parseable from the CLI's response JSON
    (needed to link part-of details to their hub), else None."""
    homelab = _homelab_path()
    if homelab is None:
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


def _memory_wired():
    """True iff this box can store at all: CLI present + an API key minted.
    Both absences are documented steady states (multi-tenancy.md), so callers
    skip SILENTLY — never one error-log line per event, forever."""
    return _homelab_path() is not None and bool(
        os.environ.get("CLAUDE_MEMORY_API_KEY") or os.environ.get("MEMORY_API_KEY")
    )


def _store_event(event, category_map):
    """Store one judge event: guard the ADR-0007 bound, store the content (the
    hub when "parts" are present), then store each part linked part-of the hub."""
    if not _memory_wired():
        return
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

    # Parts are stored linked part-of the hub ONLY when both halves exist: a
    # parseable hub id AND a deployed CLI that understands --link (capability
    # probe — a pre-v0.13.0 CLI would silently store "part-of:<id>" AS content).
    # Parts are self-contained by the judge contract, so unlinked storage
    # degrades gracefully: only the graph edge is lost, never the knowledge.
    link_ok = False
    if parts:
        if not hub_id:
            _log_error("auto-learn: hub id unparseable; storing parts unlinked")
        elif not _cli_supports_link():
            _log_error(
                "auto-learn: deployed homelab CLI lacks --link (pre-v0.13.0) — "
                "storing parts unlinked until the reconcile rebuilds the CLI"
            )
        else:
            link_ok = True
    for part in parts:
        if len(part) > MEMORY_BOUND:
            _log_error(
                f"auto-learn: part rejected — {len(part)} chars exceeds the "
                f"{MEMORY_BOUND}-char Memory bound; skipped, never truncated"
            )
            continue
        link = f"part-of:{hub_id}" if link_ok else None
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
