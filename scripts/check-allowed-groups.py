#!/usr/bin/env python3
"""Audit guard for forward-auth allowed_groups (ADR-0023 / infra#84).

Every `allowed_groups = [...]` on an ingress_factory call must name a REAL
Authentik group. A typo (e.g. "Home Server Admin" without the 's') matches
nobody, so under default-deny it silently locks users out of that host. This
static check catches that before apply — the sibling of
`check-ingress-auth-comments.py`, invoked by `scripts/tg` before every
plan/apply/destroy/refresh, stack-scoped.

Valid groups = every `authentik_group` NAME defined anywhere in the repo
(TF-created groups: Chrome Users, TripIt Users, Proxy Users, …) UNION the
UI-managed groups below (which are NOT in Terraform). Update UI_MANAGED_GROUPS
if a new UI-managed group is used as an allowed_groups value.

Usage:
  check-allowed-groups.py <stack-path>   # scan one stack's allowed_groups
  check-allowed-groups.py --all          # scan every stack
"""
import argparse
import os
import re
import sys

# Authentik groups that are UI-managed (not created by any authentik_group
# resource) yet legitimately used as allowed_groups values. Keep in sync with
# the live Authentik group list + .claude/reference/authentik-state.md.
UI_MANAGED_GROUPS = {
    "authentik Admins",
    "Home Server Admins",
    "Allow Login Users",
    "Headscale Users",
    "Wrongmove Users",
    "Task Submitters",
    "T3 Users",
    "kubernetes-admins",
    "kubernetes-power-users",
    "kubernetes-namespace-owners",
}

# allowed_groups = ["A", "B", ...]  (single- or multi-line list)
_USAGE_RE = re.compile(r"allowed_groups\s*=\s*\[(.*?)\]", re.DOTALL)
_STRING_RE = re.compile(r'"([^"]*)"')
# resource "authentik_group" "x" { ... name = "Group Name" ... }
_GROUP_DEF_RE = re.compile(
    r'resource\s+"authentik_group"\s+"[^"]*"\s*\{[^}]*?\bname\s*=\s*"([^"]*)"',
    re.DOTALL,
)


def extract_group_usages(tf_text):
    """Return a list of group-name lists, one per allowed_groups assignment."""
    return [_STRING_RE.findall(body) for body in _USAGE_RE.findall(tf_text)]


def extract_defined_groups(tf_text):
    """Return the set of group names defined by authentik_group resources."""
    return set(_GROUP_DEF_RE.findall(tf_text))


def find_violations(usages, valid_groups):
    """Group names referenced in usages that aren't in valid_groups (sorted, unique)."""
    referenced = {g for usage in usages for g in usage}
    return sorted(referenced - set(valid_groups))


def _read_tf(root):
    out = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith(".tf"):
                with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                    out.append(fh.read())
    return out


def valid_groups(repo_root):
    """UI-managed groups UNION every authentik_group name defined in the repo."""
    groups = set(UI_MANAGED_GROUPS)
    for text in _read_tf(os.path.join(repo_root, "stacks")):
        groups |= extract_defined_groups(text)
    return groups


def scan(stack_path, repo_root):
    valid = valid_groups(repo_root)
    usages = []
    for text in _read_tf(stack_path):
        usages.extend(extract_group_usages(text))
    return find_violations(usages, valid)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("stack", nargs="?", help="path to a stack directory")
    g.add_argument("--all", action="store_true", help="scan every stack")
    args = ap.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if args.all:
        targets = [
            os.path.join(repo_root, "stacks", d)
            for d in os.listdir(os.path.join(repo_root, "stacks"))
            if os.path.isdir(os.path.join(repo_root, "stacks", d))
        ]
    else:
        targets = [args.stack]

    bad = False
    for t in targets:
        violations = scan(t, repo_root)
        if violations:
            bad = True
            print(f"[check-allowed-groups] {t}: unknown Authentik group(s) in "
                  f"allowed_groups: {', '.join(violations)}", file=sys.stderr)
    if bad:
        print("\nFix the group name, or (if it's a new UI-managed group) add it to "
              "UI_MANAGED_GROUPS in scripts/check-allowed-groups.py.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
