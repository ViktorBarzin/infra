#!/usr/bin/env python3
"""PreToolUse(Bash) guard for the disk scans that starved etcd on 2026-10-11.

The devvm's disk is a slice of one spinning drive on the Proxmox host, and that
drive also holds etcd. At 07:14 that day a subagent ran
`cd ~/.claude/projects; ls -t -- */*.jsonl | head -200 | xargs grep -l ...` six
times over 7.6 GB of transcripts, and etcd's WAL fsync p99 reached 8.2 s. In
the afternoon `find /` and `du` runs were among the ~80 sessions doing the same
to it. The session-reflection detector had already counted 39 transcript greps
by 2026-09-01, with `homelab claude-usage` named in every user's instructions,
so a written rule was not enough. A hook runs before the command does.

It blocks three shapes, with no override:

  1. grep, rg, ugrep, jq, cat, find, or `xargs grep`, across
     ~/.claude/projects: a glob, a directory, a recursive search, or a `cd`
     into it followed by any of those. One named file is allowed, because
     wrap-up and others read their own transcript.
  2. du or find rooted at /, ~, $HOME or /home. find with -maxdepth 2 or less
     is allowed. du is not, because --max-depth only limits what it prints;
     it still reads every directory underneath.
  3. A recursive grep, rg or ls -R rooted at the same places.

Matching works on shell tokens, so the same words inside a quoted grep pattern,
a commit message or a heredoc body never trigger it. devvm-io-guard covers the
rest at run time, by watching the disk instead of the command text.

Exit codes: 0 = allow, 2 = block and return stderr to Claude.
"""
import json
import os
import re
import shlex
import sys

PROJ = ".claude/projects"
GLOB = re.compile(r"[*?\[]")
FILE_LIKE = re.compile(r"\.[A-Za-z0-9]{1,8}$")
HOME = os.path.expanduser("~")
WIDE = {"/", "~", "$HOME", "${HOME}", "/home", HOME}

GREPS = {"grep", "egrep", "fgrep", "ugrep", "rg"}
READERS = GREPS | {"jq", "cat"}
# Short options that take a value, per tool, so the value is not read as a path.
VALUE_OPTS = {
    "grep": {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D"},
    "ugrep": {"-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "-g", "-t"},
    "rg": {"-e", "-f", "-m", "-A", "-B", "-C", "-g", "-t", "-T", "-M", "-j",
           "-E", "-r"},
    "jq": {"-f", "--indent", "--tab"},
}
JQ_TWO_ARGS = {"--arg", "--argjson", "--slurpfile", "--rawfile"}
WRAPPERS = {"sudo", "timeout", "nice", "ionice", "env", "command", "time",
            "nohup", "stdbuf", "exec"}
# Shell keywords that can sit in front of a command in the same segment.
KEYWORDS = {"do", "then", "else", "elif", "if", "while", "until", "!", "{", "}"}

TRANSCRIPT_MSG = (
    "{what}\n"
    "Transcripts under ~/.claude/projects are 7.6 GB on a disk shared with the\n"
    "Kubernetes control plane. Scanning them on 2026-10-11 pushed etcd fsync to\n"
    "8 s and set off false critical alerts. Instead:\n"
    "  - one past session:  homelab claude-usage --session <id|name>\n"
    "  - how Claude is used here:  homelab claude-usage\n"
    "  - across sessions:  homelab logs query with a label filter\n"
    "    (infra/docs/adr/0025-claude-session-telemetry.md has the LogQL)\n"
    "  - or narrow it to one named .jsonl file, which is allowed.\n"
    "There is no override."
)
WIDE_MSG = (
    "{what}\n"
    "This walks a whole filesystem on a disk shared with the Kubernetes control\n"
    "plane; `find /` and `du` runs were part of the 2026-10-11 etcd stall.\n"
    "Instead, narrow the path to the directory you mean, or for find add\n"
    "-maxdepth 2. For logs use `homelab logs query`, and for past Claude\n"
    "sessions `homelab claude-usage`. There is no override."
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


def _newlines_to_semicolons(cmd):
    """Unquoted newlines separate commands; shlex would treat them as spaces."""
    out, in_s, in_d, i = [], False, False, 0
    while i < len(cmd):
        c = cmd[i]
        if c == "\\" and not in_s and i + 1 < len(cmd):
            out.append(cmd[i:i + 2])
            i += 2
            continue
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif c == "\n" and not in_s and not in_d:
            c = " ; "
        out.append(c)
        i += 1
    return "".join(out)


def _segments(cmd):
    """Split into simple commands, dropping redirections and their targets."""
    lex = shlex.shlex(_newlines_to_semicolons(_strip_heredocs(cmd)),
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
                    skip = True   # the redirection target
                if cur and cur[-1].isdigit():
                    cur.pop()     # the fd number in 2>/dev/null
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
    """Drop leading keywords, NAME=value assignments and wrappers like sudo."""
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            i += 1
            continue
        name = os.path.basename(tok)
        if name not in WRAPPERS:
            break
        i += 1
        while i < len(argv) and argv[i].startswith("-"):
            opt = argv[i]
            i += 1
            if name == "sudo" and opt in ("-u", "-g", "-C", "-D", "-h"):
                i += 1
            elif name == "nice" and opt == "-n":
                i += 1
            elif name == "ionice" and opt in ("-c", "-n", "-p"):
                i += 1
        if name == "timeout" and i < len(argv):
            i += 1   # the duration
    return argv[i:]


def _norm(path):
    if path in ("/*", "/"):
        return "/"
    if path.endswith("/*"):
        path = path[:-2]
    return path.rstrip("/") or "/"


def _is_wide(path, cwd_wide):
    if cwd_wide and path in (".", "./"):
        return True
    return _norm(path) in WIDE


def _in_projects(path, cwd_projects):
    if PROJ in path:
        return True
    return cwd_projects and not path.startswith(("/", "~", "$"))


def _too_broad(path):
    """A glob or a directory reads many files; a named file reads one."""
    return bool(GLOB.search(path)) or not FILE_LIKE.search(path.rstrip("/"))


def _reader_args(name, args):
    """(flags, paths) for a grep-family, jq or cat invocation."""
    flags, positional, pattern_given = [], [], False
    value_opts = VALUE_OPTS.get("grep" if name in ("egrep", "fgrep") else name,
                                set())
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional.extend(args[i + 1:])
            break
        if name == "jq" and a in JQ_TWO_ARGS:
            i += 3
            continue
        if a.startswith("-") and a != "-":
            flags.append(a)
            if a in value_opts:
                if a in ("-e", "-f") and name != "jq":
                    pattern_given = True
                i += 2
                continue
            if a.startswith(("--regexp=", "--file=")):
                pattern_given = True
            i += 1
            continue
        positional.append(a)
        i += 1
    if name == "cat":
        return flags, positional
    if name == "jq" or not pattern_given:
        positional = positional[1:]   # the pattern, or jq's filter
    return flags, positional


def _recursive(name, flags):
    if name == "rg":
        return True
    return any(f in ("--recursive", "--dereference-recursive")
               or re.match(r"^-[A-Za-z]*[rR]", f) for f in flags
               if not f.startswith("--") or f.startswith("--recursive")
               or f.startswith("--dereference-recursive"))


def _find(args):
    """(roots, maxdepth or None, has_exec)."""
    i = 0
    while i < len(args) and args[i] in ("-H", "-L", "-P"):
        i += 1
    roots = []
    while i < len(args) and not args[i].startswith(("-", "(", "!")):
        roots.append(args[i])
        i += 1
    maxdepth = None
    for j, a in enumerate(args):
        if a == "-maxdepth" and j + 1 < len(args):
            try:
                maxdepth = int(args[j + 1])
            except ValueError:
                pass
    has_exec = any(a in ("-exec", "-execdir", "-ok", "-okdir") for a in args)
    return roots or ["."], maxdepth, has_exec


def check(cmd):
    """Return the block message for a command, or None to allow it."""
    try:
        segs = [_unwrap(s) for s in _segments(cmd)]
    except ValueError:
        return None   # unbalanced quotes: not ours to judge
    segs = [s for s in segs if s]

    touches = False
    for s in segs:
        if any(PROJ in t and not re.search(r"\s", t) for t in s[1:]):
            if os.path.basename(s[0]) not in GREPS:
                touches = True
            else:
                touches = touches or any(PROJ in p for p in _reader_args(
                    os.path.basename(s[0]), s[1:])[1])

    cwd_projects = cwd_wide = False
    for argv in segs:
        name = os.path.basename(argv[0])
        args = argv[1:]

        if name == "cd":
            target = args[0] if args else "~"
            cwd_projects = PROJ in target
            cwd_wide = _is_wide(target, False)
            continue

        if name == "xargs":
            sub = [os.path.basename(a) for a in args]
            if (touches or cwd_projects) and any(a in READERS for a in sub):
                return TRANSCRIPT_MSG.format(
                    what="BLOCKED by scan-guard: xargs feeding transcripts "
                         "under ~/.claude/projects to a reader.")
            continue

        if name in READERS:
            flags, paths = _reader_args(name, args)
            recursive = name in GREPS and _recursive(name, flags)
            if not paths and recursive and (cwd_projects or cwd_wide):
                paths = ["."]
            for p in paths:
                if _in_projects(p, cwd_projects) and (_too_broad(p) or recursive):
                    return TRANSCRIPT_MSG.format(
                        what="BLOCKED by scan-guard: `%s` over %s reads many "
                             "transcripts." % (name, p))
                if recursive and _is_wide(p, cwd_wide):
                    return WIDE_MSG.format(
                        what="BLOCKED by scan-guard: a recursive `%s` from %s."
                             % (name, p))
            continue

        if name == "find":
            roots, maxdepth, has_exec = _find(args)
            shallow = maxdepth is not None and maxdepth <= 2
            for r in roots:
                if _in_projects(r, cwd_projects) and (has_exec or not shallow):
                    return TRANSCRIPT_MSG.format(
                        what="BLOCKED by scan-guard: `find` across "
                             "~/.claude/projects.")
                if _is_wide(r, cwd_wide) and not shallow:
                    return WIDE_MSG.format(
                        what="BLOCKED by scan-guard: `find %s` without "
                             "-maxdepth 2 or less." % r)
            continue

        if name == "du":
            paths = [a for a in args if not a.startswith("-")] or ["."]
            for p in paths:
                if _is_wide(p, cwd_wide):
                    return WIDE_MSG.format(
                        what="BLOCKED by scan-guard: `du` over %s reads every "
                             "directory under it, whatever --max-depth says." % p)
            continue

        if name == "ls":
            if any(a == "--recursive" or re.match(r"^-[A-Za-z]*R", a)
                   for a in args):
                paths = [a for a in args if not a.startswith("-")] or ["."]
                if any(_is_wide(p, cwd_wide) for p in paths):
                    return WIDE_MSG.format(
                        what="BLOCKED by scan-guard: `ls -R` over a whole "
                             "filesystem.")
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
