#!/usr/bin/env python3
"""Require a catalog description on every dashboard-visible ingress.

Each `ingress_factory` module call that appears on the dashboard should set
`gethomepage.dev/description` in `extra_annotations`. Those annotations are the
source for two things: the Homepage dashboard at home.viktorbarzin.me, and
`homelab services`, which is how an agent finds out what we already run. A row
with a bare hostname and no description tells a reader very little.

Exempt: ingresses kept off the dashboard on purpose (`homepage_enabled = false`,
or an explicit `"gethomepage.dev/enabled" = "false"` override on a secondary /
carve-out ingress) — they are not in the catalog, so there is nothing to
describe. Also deferred: calls that pass `extra_annotations` as an expression
rather than a literal map (the factory pattern), where the caller decides.

Stack-scoped by design, matching check-ingress-auth-comments.py: only the stack
being acted on is checked, so an untouched stack never blocks unrelated work.

Usage:
  check-ingress-descriptions.py <stack-path>     # scan one stack
  check-ingress-descriptions.py --all            # scan every stack
"""

import argparse
import os
import re
import sys

MODULE_START = re.compile(r'^module\s+"([^"]+)"\s*\{', re.M)
INGRESS_SOURCE = re.compile(r'source\s*=\s*"[^"]*ingress_factory"')
DESCRIPTION = re.compile(r'"gethomepage\.dev/description"\s*=')
# Two equivalent ways to keep an ingress off the dashboard: the module input,
# and an explicit annotation override (used by secondary/carve-out ingresses so
# one app shows one tile). Both mean "not in the catalog", so both are exempt.
HOMEPAGE_DISABLED = re.compile(
    r'homepage_enabled\s*=\s*false'
    r'|"gethomepage\.dev/enabled"\s*=\s*"false"'
)
NAME_ATTR = re.compile(r'^\s*name\s*=\s*"([^"]+)"', re.M)
# `extra_annotations = var.homepage_annotations` (the factory pattern): the map
# is supplied by the caller, so this file cannot tell whether a description is
# present. Defer rather than report something we cannot see.
ANNOTATIONS_FROM_EXPR = re.compile(r'extra_annotations\s*=\s*(?!\{)\S')


def _module_blocks(src):
    """Yield (module_label, block_text) for each top-level module block."""
    for m in MODULE_START.finditer(src):
        start = m.start()
        depth = 0
        i = start
        while i < len(src):
            c = src[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield m.group(1), src[start:i + 1]


def find_missing(src):
    """Return [(identifier, module_label)] for ingresses lacking a description."""
    out = []
    for label, block in _module_blocks(src):
        if not INGRESS_SOURCE.search(block):
            continue
        if HOMEPAGE_DISABLED.search(block):
            continue
        if ANNOTATIONS_FROM_EXPR.search(block):
            continue
        if DESCRIPTION.search(block):
            continue
        nm = NAME_ATTR.search(block)
        out.append((nm.group(1) if nm else label, label))
    return out


def scan_dir(path):
    violations = []
    for root, _, files in os.walk(path):
        for f in files:
            if not f.endswith('.tf'):
                continue
            full = os.path.join(root, f)
            try:
                with open(full) as fh:
                    src = fh.read()
            except OSError:
                continue
            for ident, label in find_missing(src):
                violations.append((full, ident, label))
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
        "ingress is missing its catalog description\n"
        "==============================================================\n"
        "\n"
        "These annotations feed the Homepage dashboard AND `homelab\n"
        "services`, which is how agents find what we already self-host.\n"
        "Without a description the service shows up as a bare hostname.\n"
        "\n"
        "Add one line to the ingress_factory call:\n"
        "\n"
        "  extra_annotations = {\n"
        '    "gethomepage.dev/description" = "What this service is for"\n'
        "  }\n"
        "\n"
        "If the ingress is deliberately not on the dashboard, set\n"
        "`homepage_enabled = false` instead.\n",
        file=sys.stderr,
    )
    for full, ident, label in violations:
        print(f"  {full}: module \"{label}\" (ingress {ident})", file=sys.stderr)
    print("", file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
