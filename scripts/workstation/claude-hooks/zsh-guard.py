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
intercept a command; this hook can. The two are handled differently:

  - The first has one safe mechanical fix, zsh's explicit split ${=VAR}, which
    gives the variable the meaning the agent intended under bash. The hook
    rewrites the command to use it and returns the result as updatedInput,
    without a permission decision, so Claude Code's own checks still run on
    it. In one renovate-upgrades workflow on 2026-10-15 the old block fired 13
    times on `G="git -c filter.git-crypt..."; $G push`, and each one cost the
    agent a retry. A use the rewrite cannot reach, such as ${VAR:-x}, is still
    blocked.
  - The second has no single right fix, so it is still blocked.

It is deliberately narrow: it fires only on the high-confidence shapes above,
and stays silent on quoted values, arrays, `${=VAR}`, heredoc bodies,
arithmetic, command substitution and subshells. A quoted string inside "$(...)"
opens its own quoting level, so `"$(psql -c "select count(*)")"` is quoted.

Process substitution, <(...) and >(...), works in zsh the same as in bash. A
check that blocked it as a glob was removed on 2026-10-15 after it stopped five
working `diff <(...) <(...)` commands in one workflow.

Exit codes: 0 = allow (with updatedInput on stdout when rewritten),
2 = block and return stderr to Claude.
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
    the paren check on any conventional-commit subject. Bodies are blanked with
    spaces of the same length, so an index into the result is an index into
    the original command, which the rewrite relies on.
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
                out.append(" " * len(lines[i]))  # keep offsets, drop content
                i += 1
            if i < len(lines):
                out.append(lines[i])  # the closing delimiter
        i += 1
    return "\n".join(out)


def _unquoted_spans(cmd):
    """Yield (index, char) for every character outside single/double quotes.

    "$(...)" starts a new unquoted level inside a double-quoted string, with its
    own quotes, as the shell reads it. A backslash escapes the next character
    outside single quotes.
    """
    # Each frame is [kind, paren depth]: "u" unquoted (top level, or inside
    # $(...)), "d" double-quoted, "s" single-quoted.
    stack = [["u", 0]]
    i = 0
    while i < len(cmd):
        c = cmd[i]
        frame = stack[-1]
        kind = frame[0]
        if kind == "s":
            if c == "'":
                stack.pop()
            i += 1
            continue
        if c == "\\":
            if kind == "u":
                yield i, c
            i += 2
            continue
        if kind == "d":
            if c == '"':
                stack.pop()
            elif cmd.startswith("$(", i):
                stack.append(["u", 0])
                i += 2
                continue
            i += 1
            continue
        # unquoted
        if c == "'":
            stack.append(["s", 0])
        elif c == '"':
            stack.append(["d", 0])
        elif c == "(":
            frame[1] += 1
        elif c == ")":
            if frame[1] == 0 and len(stack) > 1:
                stack.pop()           # end of a $(...) opened inside quotes
            elif frame[1]:
                frame[1] -= 1
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


def _flag_list_vars(cmd):
    """Yield (name, value) for each NAME=value whose value reads as an argv:
    more than one word, starting with a flag or with a command and a flag."""
    for m in ASSIGN.finditer(cmd):
        var = m.group(1)
        val = m.group(3) or m.group(4) or m.group(5) or ""
        if not val or not re.search(r"\s", val):
            continue                                  # one word: splitting is a no-op
        if val.lstrip().startswith("("):
            continue                                  # array assignment
        looks_like_flags = val.lstrip().startswith("-")
        looks_like_cmd = bool(re.match(r"^[A-Za-z0-9_./-]+\s+-", val.strip()))
        if looks_like_flags or looks_like_cmd:
            yield var, val


def rewrite(cmd):
    """Return cmd with each unquoted $VAR / ${VAR} of a flag-list variable
    turned into ${=VAR}, or None when there is nothing to rewrite."""
    scan = _strip_heredocs(cmd)
    spans = []
    for var, _ in _flag_list_vars(scan):
        pat = re.compile(r"\$(?:" + re.escape(var) + r"(?![A-Za-z0-9_])|\{" + re.escape(var) + r"\})")
        for i, c in _unquoted_spans(scan):
            if c == "$":
                m = pat.match(scan, i)
                if m:
                    spans.append((m.start(), m.end(), "${=" + var + "}"))
    if not spans:
        return None
    out, last = [], 0
    for start, end, text in sorted(set(spans)):
        out.append(cmd[last:start])
        out.append(text)
        last = end
    out.append(cmd[last:])
    return "".join(out)


def _check_word_splitting(cmd):
    for var, val in _flag_list_vars(cmd):
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
    return (
        _check_word_splitting(cmd)
        or _check_paren_glob(cmd)
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)                       # never break the session on bad input
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    tool_input = payload.get("tool_input") or {}
    cmd = tool_input.get("command", "")
    if not cmd:
        sys.exit(0)
    try:
        new = rewrite(cmd)
        hit = check(new or cmd)
    except Exception:
        sys.exit(0)                       # a guard bug must never block real work
    if hit:
        print(f"BLOCKED by zsh-guard — {hit[1]}", file=sys.stderr)
        sys.exit(2)
    if new:
        # No permissionDecision: the rewritten command still goes through
        # Claude Code's normal permission checks.
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": {**tool_input, "command": new},
        }}))
    sys.exit(0)


if __name__ == "__main__":
    main()
