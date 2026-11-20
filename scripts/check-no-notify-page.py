#!/usr/bin/env python3
"""Refuse the retired `notify: page` alert label.

Until 2026-11-20 a rule posted to Slack #alerts when it carried the label
`notify: page` (Prometheus YAML) or `notify = "page"` (Loki rules in HCL).
Since then every alert goes to the notify pipe, and each person chooses on
https://notify.viktorbarzin.me which alerts reach them
(docs/plans/2026-11-20-notify-one-flow-design.md). The label does nothing
now, so a rule that adds it would page no one while its author thinks it
does. This check fails the stack instead.

Stack-scoped like the other checks scripts/tg runs.

Usage:
  check-no-notify-page.py <stack-path>     # scan one stack
  check-no-notify-page.py --all            # scan every stack
"""

import argparse
import os
import re
import sys

LABEL = re.compile(r'''^\s*(?:notify\s*:\s*["']?page["']?\s*$|.*\bnotify\s*=\s*"page")''')
SUFFIXES = (".tf", ".tpl", ".yaml", ".yml", ".hcl")


def scan(root):
    found = []
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("secrets", "node_modules")]
        for name in files:
            if not name.endswith(SUFFIXES):
                continue
            path = os.path.join(folder, name)
            try:
                with open(path, encoding="utf-8") as f:
                    for n, line in enumerate(f, 1):
                        if line.lstrip().startswith("#"):
                            continue
                        if LABEL.match(line):
                            found.append("%s:%d: %s" % (path, n, line.strip()))
            except (UnicodeDecodeError, OSError):
                continue
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.join(here, "stacks") if args.all else args.path
    if not root:
        ap.error("give a stack path or --all")
    found = scan(root)
    if found:
        print("The `notify: page` label is retired: it pages nobody now. Remove it, and switch the")
        print("alert on at https://notify.viktorbarzin.me (docs/runbooks/notify-pipe.md):")
        for line in found:
            print("  " + line)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
