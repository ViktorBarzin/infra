#!/usr/bin/env python3
"""PreToolUse(Bash) guard for two zsh-vs-bash semantics that keep biting agents.

Claude Code's Bash tool runs the user's login shell, which on this devvm is zsh
(there is no setting to change it — `defaultShell` only covers input-box `!`
commands). Agents write bash-idiomatic shell, and two zsh differences fail
quietly rather than loudly:

  1. NO WORD SPLITTING on unquoted expansions. `F='-a -b'; cmd $F` passes ONE
     argument, so the command sees a single malformed flag. This is the
     git-crypt filter-flag shape that has recurred here for months.
  2. GLOBBING of unquoted `word(...)`. An unquoted conventional-commit subject
     like `fix(scope): x` raises "no matches found" and expands to NOTHING, so
     a commit silently takes the wrong subject.

Both are recorded in memory repeatedly and still recur, because memory cannot
intercept a command — this hook can. It is deliberately narrow: it fires only
on the high-confidence shapes above, and stays silent on quoted values, arrays,
`${=VAR}`, heredoc bodies, arithmetic, command substitution and subshells.

Exit codes: 0 = allow, 2 = block and return stderr to Claude.
"""
import json
import re
import sys

# NAME=value, where value is single/double-quoted or bare.
ASSIGN = re.compile(
    r"""(?:^|[;&|\s(])([A-Za-z_][A-Za-z0-9_]*)=("([^"]*)"|'([^']*)'|([^\s;&|)]+))"""
)


def _strip_heredocs(cmd):
    """Blank out heredoc bodies — their contents are data, not shell syntax.

    Without this, the repo's own `git commit -F - <<'EOF'` convention would trip
    the paren check on any conventional-commit subject.
    """
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m:
            delim = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != delim:
                out.append("")  # keep line numbering, drop content
                i += 1
            if i < len(lines):
                out.append(lines[i])  # the closing delimiter
        i += 1
    return "\n".join(out)


def _unquoted_spans(cmd):
    """Yield (index, char) for every character outside single/double quotes."""
    i, in_s, in_d = 0, False, False
    while i < len(cmd):
        c = cmd[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif not in_s and not in_d:
            yield i, c
        i += 1


def _uses_unquoted(cmd, var):
    """True if $var / ${var} is expanded unquoted (and not via zsh's ${=var})."""
    plain = re.compile(r"\$\{?" + re.escape(var) + r"\}?(?![A-Za-z0-9_])")
    split = re.compile(r"\$\{=" + re.escape(var) + r"\}")
    for i, c in _unquoted_spans(cmd):
        if c != "$":
            continue
        if split.match(cmd, i):      # ${=VAR} — explicit split, correct
            continue
        if plain.match(cmd, i):
            return True
    return False


def _check_word_splitting(cmd):
    for m in ASSIGN.finditer(cmd):
        var = m.group(1)
        val = m.group(3) or m.group(4) or m.group(5) or ""
        if not val or not re.search(r"\s", val):
            continue                                  # one word: splitting is a no-op
        if val.lstrip().startswith("("):
            continue                                  # array assignment
        looks_like_flags = val.lstrip().startswith("-")
        looks_like_cmd = bool(re.match(r"^[A-Za-z0-9_./-]+\s+-", val.strip()))
        if not (looks_like_flags or looks_like_cmd):
            continue                                  # a message or path, not an argv
        if _uses_unquoted(cmd, var):
            return (
                var,
                f"zsh does not word-split unquoted ${var}.\n"
                f"  ${var} = {val!r}\n"
                f"  reaches the command as ONE argument, not several, so it reads as a\n"
                f"  single malformed flag. bash would have split it; zsh does not.\n"
                f"Fix, in order of preference:\n"
                f"  1. inline the flags on the command itself\n"
                f'  2. an array:  {var}=(...)   then   "${{{var}[@]}}"\n'
                f"  3. zsh explicit split:  ${{={var}}}\n"
                f"  4. wrap the whole invocation in  bash -c '...'",
            )
    return None


# A bare word immediately followed by '(' — zsh reads this as a glob pattern.
PAREN = re.compile(r"[A-Za-z_][A-Za-z0-9_.+-]*\(")


def _check_paren_glob(cmd):
    for i, c in _unquoted_spans(cmd):
        m = PAREN.match(cmd, i)
        if not m:
            continue
        # Skip if this is part of a larger construct rather than a bare word.
        prev = cmd[i - 1] if i else " "
        if prev in "$=({":            # $(...), x=(...), nested
            continue
        if not (prev.isspace() or prev in ";&|" or i == 0):
            continue                  # mid-token, e.g. the tail of $(foo)
        rest = cmd[m.end():]
        close = rest.find(")")
        if close == -1:
            continue
        after = rest[close + 1:]
        if re.match(r"\s*\{", after):  # name() { ... }  — a function definition
            continue
        word = m.group(0)[:-1]
        return (
            word,
            f"zsh globs the unquoted token `{word}(...)`.\n"
            f"  It is treated as a filename pattern, fails with 'no matches found',\n"
            f"  and expands to NOTHING — so a commit subject or message silently\n"
            f"  goes missing rather than erroring visibly.\n"
            f"Fix: quote it, or pass the text via  git commit -F -  with a\n"
            f"quoted heredoc (<<'EOF'), which is this repo's convention.",
        )
    return None


def check(cmd):
    """Return (token, message) if the command should be blocked, else None."""
    cmd = _strip_heredocs(cmd)
    return _check_word_splitting(cmd) or _check_paren_glob(cmd)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)                       # never break the session on bad input
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not cmd:
        sys.exit(0)
    try:
        hit = check(cmd)
    except Exception:
        sys.exit(0)                       # a guard bug must never block real work
    if not hit:
        sys.exit(0)
    print(f"BLOCKED by zsh-guard — {hit[1]}", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
