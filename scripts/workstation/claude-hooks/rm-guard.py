#!/usr/bin/env python3
"""PreToolUse(Bash) guard for `rm -r` on a path an empty variable would turn
into / or a top-level directory.

Claude Code has its own check for this shape, and it asks a person even in a
session started with --dangerously-skip-permissions. On 2026-10-12 that raised
an "approve this command" card for

    S=/var/tmp/.../tfval; for b in f1-stream-b0 f1-stream-roles; do rm -rf $S/$b; ...

and the session waited until somebody answered. The check is right that the
command is dangerous: with $S and $b empty it is `rm -rf /`. What it asks for is
a person, which is the wrong tool in an unattended session. This hook blocks
the same shape first and tells the agent how to write it safely, so the agent
rewrites it and carries on without anyone being asked.

The fix it asks for is ${VAR:?}, which makes the shell stop with an error when
the variable is empty, so the path can never shrink to /. Claude Code runs that
form without asking.

What Claude Code 2.1.296 did in a bypass scratch session, which this follows:

  - Inside a for/while/until loop or an if, it ignores assignments made earlier
    in the same command, so `S=.; for b in z; do rm -rf $S/$b; done` asked.
  - Outside one, it reads literal assignments: `S=.; b=x; rm -rf $S/$b` ran.
  - A path that is harmless with the variables empty ran: `./$b`, `$b`,
    `build/$x`. A non-recursive rm ran.

It goes one step further than Claude Code on purpose: `rm -r $UNSET/zz` ran
there, and is blocked here, because an empty $UNSET deletes /zz. The cost of
that difference is one rewrite by the agent.

$HOME and $PWD count as set. A variable in single quotes, a heredoc body and
the arguments of other commands (echo, grep, git commit -m) are data, and are
never matched.

Exit codes: 0 = allow, 2 = block and return stderr to Claude.
"""
import json
import os
import re
import shlex
import sys

# Always set in a Claude Code Bash call.
ALWAYS_SET = {"HOME", "PWD"}
WRAPPERS = {"sudo", "timeout", "nice", "ionice", "env", "command", "time",
            "nohup", "stdbuf", "exec"}
COMPOUND_OPEN = {"for", "while", "until", "if", "case", "select"}
COMPOUND_CLOSE = {"done", "fi", "esac"}
KEYWORDS = {"do", "then", "else", "elif", "!", "{", "}"} | COMPOUND_OPEN | COMPOUND_CLOSE
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# ${NAME}, ${NAME:?msg}, ${NAME:-default}, ..., or $NAME / $1 / $@.
EXPANSION = re.compile(
    r"\$\{([A-Za-z_][A-Za-z0-9_]*|[0-9@*#])(:?[-=?+])?([^}]*)\}"
    r"|\$([A-Za-z_][A-Za-z0-9_]*|[0-9@*#])")

MSG = (
    "BLOCKED by rm-guard: `rm {flags} {target}` builds its path from {names}.\n"
    "If {either} empty, the path becomes `{emptied}` and rm deletes it. Claude Code\n"
    "stops for a person's approval on this shape even in bypass mode, so the\n"
    "session would sit waiting.\n"
    "Rewrite the path with ${{VAR:?}}, which stops the shell with an error when\n"
    "the variable is empty:\n"
    "  rm {flags} \"{fixed}\"\n"
    "Claude Code runs that form without asking."
)


def _strip_heredocs(cmd):
    """Blank out heredoc bodies; their contents are data, not commands."""
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
                i += 1
        i += 1
    return "\n".join(out)


def _mark_single_quotes(cmd):
    """Hide $ inside single quotes, where the shell expands nothing."""
    out, in_s, in_d = [], False, False
    for c in cmd:
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif c == "$" and in_s:
            c = "\x00"
        elif c == "\n" and not in_s and not in_d:
            c = " ; "
        out.append(c)
    return "".join(out)


def _segments(cmd):
    """Simple commands in order, with redirections and their targets dropped."""
    lex = shlex.shlex(_mark_single_quotes(_strip_heredocs(cmd)),
                      posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    segs, cur, skip = [], [], False
    for tok in lex:
        if skip:
            skip = False
            continue
        if tok and all(ch in "();<>|&" for ch in tok):
            if "<" in tok or ">" in tok:
                if not tok.endswith("&"):
                    skip = True
                if cur and cur[-1].isdigit():
                    cur.pop()
                continue
            if cur:
                segs.append(cur)
            cur = []
            continue
        cur.append(tok)
    if cur:
        segs.append(cur)
    return segs


def _unwrap(argv):
    """Split off leading keywords, then drop wrappers like sudo.

    Returns (keywords, assignments, argv). Assignments only count when they are
    the whole segment; `X=1 cmd` sets X for cmd alone.
    """
    keywords, i = [], 0
    while i < len(argv) and argv[i] in KEYWORDS:
        keywords.append(argv[i])
        i += 1
        if keywords[-1] in ("for", "select", "case") and i < len(argv):
            i = len(argv)      # `for b in a c` names and lists, no command
    rest = argv[i:]
    assigns = []
    j = 0
    while j < len(rest) and ASSIGN.match(rest[j]):
        assigns.append(rest[j])
        j += 1
    if j < len(rest):
        assigns = []           # a prefix assignment, scoped to the command
    rest = rest[j:]
    k = 0
    while k < len(rest) and os.path.basename(rest[k]) in WRAPPERS:
        name = os.path.basename(rest[k])
        k += 1
        while k < len(rest) and rest[k].startswith("-"):
            opt = rest[k]
            k += 1
            if name == "sudo" and opt in ("-u", "-g", "-C", "-D", "-h"):
                k += 1
        if name == "timeout" and k < len(rest):
            k += 1
    return keywords, assigns, rest[k:]


def _rm_parts(args):
    """(recursive, flags, targets) for rm's arguments."""
    flags, targets, done = [], [], False
    for a in args:
        if done or not a.startswith("-") or a == "-":
            targets.append(a)
        elif a == "--":
            done = True
        else:
            flags.append(a)
    recursive = any(f in ("--recursive", "-r", "-R")
                    or (not f.startswith("--") and re.search(r"[rR]", f))
                    for f in flags)
    return recursive, flags, targets


def _empty_out(target, known):
    """(path with unknown variables emptied, names emptied, ${VAR:?} rewrite)."""
    emptied = []

    def sub(m, fix):
        name = m.group(1) or m.group(4)
        op, default = m.group(2) or "", m.group(3) or ""
        if op.endswith("?") or name in ALWAYS_SET:
            return m.group(0) if fix else "x"
        if op and op.lstrip(":") in ("-", "=") and default:
            return m.group(0) if fix else "x"
        if name in known:
            return m.group(0) if fix else known[name]
        if not fix:
            emptied.append(name)
            return ""
        return "${%s:?}" % name

    path = EXPANSION.sub(lambda m: sub(m, False), target)
    fixed = EXPANSION.sub(lambda m: sub(m, True), target)
    return path, emptied, fixed


def _at_root(path):
    """True for /, /* and a top-level path such as /zz."""
    p = re.sub(r"/+", "/", path)
    if p != "/":
        p = p.rstrip("/")
    return p in ("/", "/*") or bool(re.fullmatch(r"/[^/]+", p))


def check(cmd):
    """Return the block message for a command, or None to allow it."""
    if "rm" not in cmd or "$" not in cmd:
        return None
    try:
        segs = _segments(cmd)
    except ValueError:
        return None            # unbalanced quotes: not ours to judge
    known, depth = {}, 0
    for argv in segs:
        keywords, assigns, rest = _unwrap(argv)
        for kw in keywords:
            if kw in COMPOUND_OPEN:
                depth += 1
            elif kw in COMPOUND_CLOSE:
                depth = max(0, depth - 1)
        for a in assigns:
            name, value = ASSIGN.match(a).groups()
            if depth == 0 and "$" not in value and "`" not in value and "\x00" not in value:
                known[name] = value
            else:
                known.pop(name, None)
        if not rest or os.path.basename(rest[0]) != "rm":
            continue
        recursive, flags, targets = _rm_parts(rest[1:])
        if not recursive:
            continue
        visible = known if depth == 0 else {}
        for t in targets:
            path, emptied, fixed = _empty_out(t, visible)
            if emptied and _at_root(path):
                names = " and ".join("$" + n for n in dict.fromkeys(emptied))
                return MSG.format(
                    flags=" ".join(flags), target=t, names=names,
                    either="it is" if len(set(emptied)) == 1 else "they are",
                    emptied=re.sub(r"/+", "/", path), fixed=fixed)
    return None


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
    print(hit, file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
