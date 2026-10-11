#!/usr/bin/env python3
"""Audit guard for forward-auth allowed_groups (ADR-0023, ADR-0031).

Two checks, both static, invoked by `scripts/tg` before every
plan/apply/destroy/refresh, stack-scoped; the sibling of
`check-ingress-auth-comments.py`.

1. Every `allowed_groups = [...]` on an ingress_factory call must name a REAL
   Authentik group. A typo (e.g. "Home Server Admin" without the 's') matches
   nobody, so it silently locks users out of that host. Valid groups = every
   `authentik_group` NAME defined anywhere in the repo UNION the UI-managed
   groups below. Update UI_MANAGED_GROUPS if a new UI-managed group is used.

2. The ingress and stacks/authentik/forward-auth-apps.json must agree (ADR-0031).
   A host whose allowed_groups names anything besides Home Server Admins is
   enforced only through its own forward_single application, which is
   generated from that JSON, so a host listed in one place and not the other
   is either a grant nobody enforces or an enforced grant the app stack does
   not show. Home Server Admins is implied in the JSON. Scanning
   stacks/authentik (or --all) also flags JSON entries with no ingress.

Usage:
  check-allowed-groups.py <stack-path>   # scan one stack
  check-allowed-groups.py --all          # scan every stack
"""
import argparse
import json
import os
import re
import sys

ADMIN_GROUP = "Home Server Admins"
ROOT_DOMAIN = "viktorbarzin.me"
FORWARD_AUTH_MAP = os.path.join("stacks", "authentik", "forward-auth-apps.json")

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


_MODULE_START_RE = re.compile(r'^module\s+"([^"]+)"\s*\{', re.MULTILINE)
_ATTR_RE = re.compile(r'^\s*(\w+)\s*=\s*(.*?)\s*$')
_LITERAL_RE = re.compile(r'^"([^"$]*)"')


def _module_blocks(tf_text):
    """Yield (module name, top-level attribute lines) for each module block."""
    for m in _MODULE_START_RE.finditer(tf_text):
        depth, top = 1, []
        for line in tf_text[m.end():].splitlines():
            if depth == 1:
                top.append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                break
        yield m.group(1), top


def extract_forward_auth_ingresses(tf_text):
    """ingress_factory calls with auth="required" (the default).

    Returns dicts of module name, effective host (None when name/host/full_host
    is not a string literal) and allowed_groups (the module default when unset).
    """
    out = []
    for name, lines in _module_blocks(tf_text):
        attrs = {}
        for line in lines:
            am = _ATTR_RE.match(line)
            if am and am.group(1) not in attrs:
                attrs[am.group(1)] = am.group(2)
        if "ingress_factory" not in attrs.get("source", ""):
            continue

        def literal(key):
            if key not in attrs:
                return None
            lm = _LITERAL_RE.match(attrs[key])
            return lm.group(1) if lm else False

        if literal("auth") not in (None, "required"):
            continue
        full_host, host, mname = literal("full_host"), literal("host"), literal("name")
        if full_host:
            effective = full_host
        elif full_host is False or host is False or (host is None and not mname):
            effective = None
        else:
            effective = f"{host or mname}.{ROOT_DOMAIN}"
        groups = [ADMIN_GROUP]
        um = _USAGE_RE.search("\n".join(lines))
        if um:
            groups = _STRING_RE.findall(um.group(1))
        out.append({"module": name, "host": effective, "groups": groups})
    return out


def map_mismatches(ingresses, forward_auth_map):
    """Disagreements between ingress allowed_groups and the forward-auth map."""
    out = []
    for ing in ingresses:
        extra = sorted(set(ing["groups"]) - {ADMIN_GROUP})
        where = f'module "{ing["module"]}"'
        if ing["host"] is None:
            if extra:
                out.append(f"{where}: names {', '.join(extra)} but its host is not a "
                           "string literal, so it cannot be matched to forward-auth-apps.json")
            continue
        listed = sorted(set(forward_auth_map.get(ing["host"], [])) - {ADMIN_GROUP})
        if extra == listed:
            continue
        if not listed:
            out.append(f'{where} ({ing["host"]}): allowed_groups names {", ".join(extra)} '
                       "but the host is not in forward-auth-apps.json, so nothing enforces it")
        elif not extra:
            out.append(f'{where} ({ing["host"]}): forward-auth-apps.json grants '
                       f'{", ".join(listed)} but allowed_groups is admin-only')
        else:
            out.append(f'{where} ({ing["host"]}): allowed_groups {extra} != '
                       f"forward-auth-apps.json {listed}")
    return out


def orphan_map_entries(ingresses, forward_auth_map):
    """Hosts in the forward-auth map that no forward-auth ingress declares."""
    hosts = {i["host"] for i in ingresses}
    return sorted(h for h in forward_auth_map if h not in hosts)


def _read_tf(root):
    out = []
    for dirpath, dirs, files in os.walk(root):
        # .terraform / .terragrunt-cache hold copies of the stack and its modules.
        dirs[:] = [d for d in dirs if not d.startswith(".")]
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


def load_forward_auth_map(repo_root):
    with open(os.path.join(repo_root, FORWARD_AUTH_MAP), encoding="utf-8") as fh:
        return json.load(fh)


def forward_auth_ingresses(root):
    out = []
    for text in _read_tf(root):
        out.extend(extract_forward_auth_ingresses(text))
    return out


def scan_forward_auth(stack_path, repo_root, all_ingresses):
    """Map disagreements for one stack; the authentik stack also gets orphans."""
    fa_map = load_forward_auth_map(repo_root)
    problems = map_mismatches(forward_auth_ingresses(stack_path), fa_map)
    if os.path.realpath(stack_path) == os.path.realpath(
        os.path.join(repo_root, "stacks", "authentik")
    ):
        problems += [f"{h}: in forward-auth-apps.json but no forward-auth ingress declares it"
                     for h in orphan_map_entries(all_ingresses(), fa_map)]
    return problems


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

    cache = []

    def all_ingresses():
        if not cache:
            cache.extend(forward_auth_ingresses(os.path.join(repo_root, "stacks")))
        return cache

    bad_groups = bad_map = False
    for t in targets:
        violations = scan(t, repo_root)
        if violations:
            bad_groups = True
            print(f"[check-allowed-groups] {t}: unknown Authentik group(s) in "
                  f"allowed_groups: {', '.join(violations)}", file=sys.stderr)
        for p in scan_forward_auth(t, repo_root, all_ingresses):
            bad_map = True
            print(f"[check-allowed-groups] {t}: {p}", file=sys.stderr)
    if bad_groups:
        print("\nFix the group name, or (if it's a new UI-managed group) add it to "
              "UI_MANAGED_GROUPS in scripts/check-allowed-groups.py.", file=sys.stderr)
    if bad_map:
        print(f"\nMake the ingress allowed_groups and {FORWARD_AUTH_MAP} name the same "
              "groups (Home Server Admins is implied in the JSON). ADR-0031.",
              file=sys.stderr)
    if bad_groups or bad_map:
        sys.exit(1)


if __name__ == "__main__":
    main()
