#!/usr/bin/env python3
"""Enforce the inline-comment convention for ingress_factory auth tiers.

Every `auth = "app"` or `auth = "none"` line under a stack must have an
immediately-preceding comment block containing `# auth = "<tier>":`
that documents what gates the app (for "app") or why the endpoint is
intentionally public (for "none").

This is the static guard for the anti-exposure rule documented in
`infra/.claude/CLAUDE.md` "Auth" section. It's invoked by `scripts/tg`
before every plan/apply/destroy/refresh, so it fires regardless of who
or what is running terragrunt — local laptop, CI, headless agent.

Stack-scoped by design: only checks the .tf files under the stack
being acted on. Other stacks' historical violations don't block work
on the current stack; each stack documents itself the next time it's
edited.

Usage:
  check-ingress-auth-comments.py <stack-path>     # scan one stack
  check-ingress-auth-comments.py --all            # scan every stack
"""

import argparse
import os
import re
import sys

AUTH_LINE = re.compile(r'^\s*auth\s*=\s*"(app|none)"\s*$')
COMMENT_LINE = re.compile(r'^\s*#')
COMMENT_TIER = re.compile(r'auth\s*=\s*"(app|none)"')


def scan_dir(path):
    violations = []
    for root, _, files in os.walk(path):
        for f in files:
            if not f.endswith('.tf'):
                continue
            full = os.path.join(root, f)
            try:
                with open(full) as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            for i, line in enumerate(lines):
                m = AUTH_LINE.match(line)
                if not m:
                    continue
                tier = m.group(1)
                # Walk backwards through contiguous comment lines.
                # Pass if ANY of them documents the matching tier.
                ok = False
                j = i - 1
                while j >= 0 and COMMENT_LINE.match(lines[j]):
                    cm = COMMENT_TIER.search(lines[j])
                    if cm and cm.group(1) == tier:
                        ok = True
                        break
                    j -= 1
                if not ok:
                    violations.append((full, i + 1, tier))
    return violations


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('path', nargs='?', help='Stack directory to scan')
    g.add_argument('--all', action='store_true', help='Scan every stack under stacks/')
    args = ap.parse_args()

    if args.all:
        scan_paths = ['stacks']
    else:
        if not os.path.isdir(args.path):
            print(f"ERROR: {args.path} is not a directory", file=sys.stderr)
            sys.exit(2)
        scan_paths = [args.path]

    violations = []
    for p in scan_paths:
        violations.extend(scan_dir(p))

    if not violations:
        return

    print(
        "\n"
        "==============================================================\n"
        "ingress_factory auth-comment convention violated\n"
        "==============================================================\n"
        "\n"
        "Every `auth = \"app\"` or `auth = \"none\"` line must have a\n"
        "preceding comment line documenting what gates the app (for\n"
        "\"app\") or why the endpoint is intentionally public (for\n"
        "\"none\"). This guard prevents accidentally exposing private\n"
        "services. See infra/.claude/CLAUDE.md Auth section.\n"
        "\n"
        "Add a comment line directly above the auth line:\n"
        "\n"
        "  # auth = \"app\":  <what gates the app, e.g. NextAuth + OAuth>\n"
        "  auth = \"app\"\n"
        "\n"
        "or:\n"
        "\n"
        "  # auth = \"none\": <why public, e.g. webhook receiver, CalDAV>\n"
        "  auth = \"none\"\n"
        "\n"
        "Violations:",
        file=sys.stderr,
    )
    for path, line_no, tier in violations:
        print(
            f"  {path}:{line_no}: auth = \"{tier}\" missing preceding "
            f"`# auth = \"{tier}\":` comment",
            file=sys.stderr,
        )
    print(file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
