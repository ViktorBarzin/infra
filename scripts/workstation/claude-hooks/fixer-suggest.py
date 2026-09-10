#!/usr/bin/env python3
"""PostToolUse(Bash) — notice an access wall and name the way past it.

A non-admin session on this box hits walls its account cannot pass: a kubectl
403, a Secret it may not read, a namespace it does not own. The way past is to
file a `broken` issue on Forgejo `viktor/infra`, which dispatches the fixer — an
agent that repairs it with full cluster access and reports back on the issue.

That route is written in the user's CLAUDE.md, but prose only helps if the model
recalls it at the moment it matters. This hook is the harness noticing instead:
it reads the actual command output, and when it carries a denial signature it
injects one short reminder as context.

Design, matching the other hooks here:

  * **Precise, not eager.** Only signatures that genuinely mean "your account is
    not allowed" are matched — a kubectl RBAC refusal, a Vault 403, a sudo
    refusal. A bare "Permission denied" is deliberately NOT enough on its own:
    it is usually a file mode, and a hook that cries wolf gets ignored, which
    costs more than the one it would have caught.
  * **Quiet after the first couple.** At most ``MAX_FIRES_PER_SESSION``
    reminders per session, because a session that hit one wall will usually hit
    several in a row while diagnosing, and repeating the same advice is noise.
  * **Never breaks the session.** Any unexpected error exits 0 with no output.
    A hook that can wedge a session is worse than no hook.

Exit 0 always. Output is a PostToolUse ``additionalContext`` payload, or nothing.
"""
import hashlib
import json
import os
import re
import sys
import tempfile

MAX_FIRES_PER_SESSION = 2

# The command must plausibly have ATTEMPTED privileged access. Output alone is
# not enough: text that merely quotes a denial trips every pattern below. This
# hook fired on `homelab memory list` because a stored memory quoted
# "Error from server (Forbidden)" — the exact cry-wolf failure it is meant to
# avoid, so the command is now part of the evidence.
_ACCESS_ATTEMPT = re.compile(
    r"\b(kubectl|helm|vault|sudo|terragrunt|terraform|gh|az|aws|docker|"
    r"systemctl|forgejo|git\s+push)\b", re.IGNORECASE)

# Reading or searching stored text is never an access attempt, whatever the text
# happens to contain. Checked before the pattern above, since these commands can
# legitimately mention kubectl in their output.
_READS_STORED_TEXT = re.compile(
    r"\bhomelab\s+(memory|logs|claude-usage|usage)\b|\b(grep|rg|ugrep|cat|less|"
    r"head|tail)\b.*\.(jsonl|log|md)\b", re.IGNORECASE)

# Signatures that mean "this account is not permitted", each specific enough that
# a match is not a guess. Ordered roughly by how often they appear in practice.
DENIAL_PATTERNS: tuple[tuple[str, str], ...] = (
    (r"Error from server \(Forbidden\)", "kubectl RBAC"),
    (r'cannot (?:get|list|watch|create|update|patch|delete) resource ', "kubectl RBAC"),
    (r'is forbidden: User "[^"]+" cannot ', "kubectl RBAC"),
    # [\s\S] rather than . — the two halves are usually on different lines
    # ("* permission denied" then "URL: GET https://vault...").
    (r"permission denied[\s\S]{0,60}\bvault\b|\bvault\b[\s\S]{0,80}permission denied",
     "Vault policy"),
    (r"Code: 403\. Errors", "Vault 403"),
    (r"sudo: a password is required", "sudo"),
    (r"is not in the sudoers file", "sudo"),
    (r"403 Forbidden", "HTTP 403"),
    (r'"status"\s*:\s*"?403', "HTTP 403"),
)

_COMPILED = tuple((re.compile(p, re.IGNORECASE), label) for p, label in DENIAL_PATTERNS)

REMINDER = """\
That command was refused by an access boundary ({kind}) — this account is not \
permitted to do it, so retrying or working around it will not help.

If something is **broken right now** and this wall is what blocks fixing it, \
file a `broken` issue on Forgejo `viktor/infra` (use the `file-issue` skill). \
That dispatches the fixer, which repairs it with full cluster access and reports \
back on the issue. File it yourself — do not wait to be asked; it is not a \
destructive action. Put what you already tried and ruled out in the body, since \
the fixer starts with no memory of this session.

If nothing is currently failing and this is a change you want, file it `change` \
instead — that is reviewed rather than dispatched."""


def _state_path(session_id: str) -> str:
    """A per-session counter file, in the user's own temp space."""
    digest = hashlib.sha256(session_id.encode()).hexdigest()[:16]
    return os.path.join(tempfile.gettempdir(), f"fixer-suggest-{os.getuid()}-{digest}")


def _fires(path: str) -> int:
    try:
        with open(path) as fh:
            return int(fh.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def _record(path: str, count: int) -> None:
    try:
        with open(path, "w") as fh:
            fh.write(str(count))
    except OSError:
        pass  # a counter we cannot persist just means one extra reminder


def find_denial(text: str) -> str | None:
    """The kind of access wall in ``text``, or None. Pure — the tests drive it."""
    if not text:
        return None
    for pattern, kind in _COMPILED:
        if pattern.search(text):
            return kind
    return None


def attempted_access(command: str) -> bool:
    """Whether ``command`` plausibly tried to do something privileged.

    A denial signature in output only means something when the command could
    have been denied. Reading memory, logs or a transcript is never that, even
    when the text it returns is full of past denials.
    """
    if not command:
        return False
    if _READS_STORED_TEXT.search(command):
        return False
    return bool(_ACCESS_ATTEMPT.search(command))


def output_text(payload: dict) -> str:
    """Everything the command produced, as one string."""
    response = payload.get("tool_response")
    if isinstance(response, str):
        return response
    if not isinstance(response, dict):
        return ""
    parts = [
        str(response.get(key) or "")
        for key in ("stdout", "stderr", "output", "error", "content")
    ]
    return "\n".join(p for p in parts if p)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    command = str((payload.get("tool_input") or {}).get("command") or "")
    if not attempted_access(command):
        return 0

    kind = find_denial(output_text(payload))
    if kind is None:
        return 0

    session = str(payload.get("session_id") or "no-session")
    path = _state_path(session)
    fired = _fires(path)
    if fired >= MAX_FIRES_PER_SESSION:
        return 0
    _record(path, fired + 1)

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": REMINDER.format(kind=kind),
        }
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never wedge a session over a reminder.
        sys.exit(0)
