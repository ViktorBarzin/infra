#!/usr/bin/env python3
"""
Stop hook: enforce the unslop style on the reply Claude just produced.

Installed for every devvm user by t3-provision-users.sh, which also wires it
into ~/.claude/settings.json through wire-memory-hooks.py. The rules it enforces
are ~/.claude/rules/40-style.md.

~/.claude/rules/40-style.md carries the full rule set, but text in context does not
stop a generation reflex. Measured 2026-09-02 over 7,302 replies from the
preceding week: 6,068 em dashes, while the em-dash ban was already loaded in
every session. The vocabulary rules held (14 hits), the punctuation one did
not.

So this checks the mechanical tells only, the ones a regex can judge without
reading for meaning, and blocks the turn so Claude rewrites. Judgement calls
(opinion, rhythm, naming the mechanism) stay in CLAUDE.md where they belong.

The reply comes from the payload's `last_assistant_message`, not the
transcript. Measured while building this: at Stop time the assistant record is
not yet flushed to the .jsonl, so a transcript read returns the empty string
and every check silently passes. The transcript stays as a fallback for a
Claude Code version that stops sending the field.

Fires at most once per turn: Claude Code sets stop_hook_active on the retry,
and that is the loop guard.

False-positive control: fenced code, inline code, blockquotes, URLs and
markdown link targets are stripped before matching, because a quoted log line
or a pasted diff is not Claude's own prose. Measured on the same corpus, 1% of
em dashes sat inside a fence or a quote.

Set UNSLOP_CHECK_DEBUG=1 to append what the hook saw to
~/.claude/tmp/unslop-debug.log.
"""

import json
import os
import re
import sys

TAIL_BYTES = 2_000_000        # fallback transcript read, last few records only
PROSE_WORD_MAX = 300          # prose only; tables and code blocks do not count

BANNED = (
    "additionally|crucial|delve|enduring|enhance|fostering|garner|interplay|"
    "intricate|pivotal|showcase|testament|underscore|vibrant|utilize|leverage|"
    "facilitate|numerous|myriad|realm"
)
METAPHOR = (
    "substrate|wedge|locus|nexus|bedrock|paradigm|gold-plating|north star|flywheel"
)

CHECKS = [
    ("em dash", re.compile(r"—")),
    ("curly quote", re.compile(r"[‘’“”]")),
    ("en dash used as a dash", re.compile(r"\s–\s")),
    ("banned word", re.compile(rf"\b({BANNED})\b", re.I)),
    ("abstract metaphor noun", re.compile(rf"\b({METAPHOR})\b", re.I)),
    ("'not just X but Y'", re.compile(r"not (just|only) [^.\n]{1,40}?,? (but|it'?s)", re.I)),
    ("bold-label-then-colon bullet",
     re.compile(r"^\s*[-*]\s+\*\*[^*\n]{2,40}(:\*\*|\*\*:)", re.M)),
    ("fancy way to say 'is'", re.compile(r"\b(serves as|stands as|boasts)\b", re.I)),
    ("chatbot phrase", re.compile(
        r"(I hope this helps|Let me know if|Great question|"
        r"you'?re absolutely right|smoking gun|Certainly!|Of course!)", re.I)),
    ("filler phrase", re.compile(
        r"(in order to|due to the fact that|it is important to note that|"
        r"it'?s worth noting that)", re.I)),
]


def transcript_fallback(path):
    """Newest assistant text in the transcript, for when the payload lacks it."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()          # discard the partial line
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""

    for line in reversed(lines):
        if '"assistant"' not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("isSidechain"):
            continue
        msg = rec.get("message") or {}
        if msg.get("role") != "assistant":
            continue
        blocks = [b.get("text", "") for b in (msg.get("content") or [])
                  if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(b for b in blocks if b.strip())
        if text:
            return text
    return ""


def strip_quoted(text):
    """Remove everything that is not Claude's own prose."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"~~~.*?~~~", " ", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", " ", text)
    text = re.sub(r"^\s*>.*$", " ", text, flags=re.M)
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"\]\([^)]*\)", "] ", text)
    return text


def prose_words(text):
    """Word count outside code fences and markdown tables."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"^\s*\|.*$", " ", text, flags=re.M)
    return len(text.split())


CYRILLIC = re.compile(r"[\u0400-\u04FF]")
LATIN = re.compile(r"[A-Za-z]")

# In Bulgarian and Russian the dash is standard punctuation, including for the
# omitted copula ("\u0418\u0432\u0430\u043d \u2014 \u0443\u0447\u0438\u0442\u0435\u043b"), so the em-dash rules would fight correct
# grammar rather than an AI tell. The Latin-alphabet checks below stay on: they
# cannot match Cyrillic text anyway.
DASH_CHECKS = {"em dash", "en dash used as a dash"}


def is_cyrillic(text):
    cyr, lat = len(CYRILLIC.findall(text)), len(LATIN.findall(text))
    return cyr > 20 and cyr > lat


def tells(reply):
    prose = strip_quoted(reply)
    skip = DASH_CHECKS if is_cyrillic(prose) else frozenset()
    found = []
    for name, pattern in CHECKS:
        if name in skip:
            continue
        hits = list(pattern.finditer(prose))
        if hits:
            sample = " ".join(hits[0].group(0).split())[:48]
            found.append(f"{name} x{len(hits)}" + (f' ("{sample}")' if sample else ""))
    words = prose_words(reply)
    if words > PROSE_WORD_MAX:
        found.append(f"too long: {words} prose words, ceiling {PROSE_WORD_MAX}")
    return found


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        sys.exit(0)

    reply = payload.get("last_assistant_message") or ""
    if not reply.strip():
        reply = transcript_fallback(payload.get("transcript_path", ""))

    found = [] if payload.get("stop_hook_active") else tells(reply)

    if os.environ.get("UNSLOP_CHECK_DEBUG"):
        try:
            os.makedirs(os.path.expanduser("~/.claude/tmp"), exist_ok=True)
            with open(os.path.expanduser("~/.claude/tmp/unslop-debug.log"), "a") as fh:
                fh.write(json.dumps({
                    "active": payload.get("stop_hook_active"),
                    "words": prose_words(reply),
                    "found": found,
                    "saw": " ".join(reply.split())[:120],
                }) + "\n")
        except OSError:
            pass

    if not found:
        sys.exit(0)

    print(json.dumps({
        "decision": "block",
        "reason": (
            "Your reply breaks the style rules in ~/.claude/rules/40-style.md: "
            + "; ".join(found)
            + ". Rewrite it and send the corrected version. Keep every fact and "
              "number. Do not mention this check or apologise, just say the thing "
              "properly. If a flagged phrase is quoted from someone else or from "
              "output, put it in backticks or a fenced block and it will pass."
        ),
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
