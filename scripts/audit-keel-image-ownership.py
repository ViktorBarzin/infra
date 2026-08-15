#!/usr/bin/env python3
"""Audit the invariant: nothing Keel auto-upgrades is tracked by Terraform.

For every pod-owning Terraform resource, resolve the live workload it manages and
check that exactly one owner controls the image version:

  * Keel owns it  -> keel.sh/policy is set and is not "never", and every container
                     index carries a KEEL_IGNORE_IMAGE entry
  * Terraform owns it -> keel.sh/policy is "never" (or absent), image tracked normally

Anything else means the two fight on every apply, which is not just drift noise —
it has silently reverted Keel upgrades to older releases. See AGENTS.md
("The invariant: nothing auto-upgraded is tracked by Terraform").

Exit status is 1 when any gap is found, so this can gate CI.

Usage:  scripts/audit-keel-image-ownership.py [repo-root]
"""
import json
import os
import re
import subprocess
import sys

KINDS = r"kubernetes_(?:deployment|stateful_set|daemon_set|daemonset)(?:_v1)?"
# Declaration must start a line, so commented-out `# resource "..."` blocks are skipped.
RES_RE = re.compile(r'^[ \t]*resource\s+"(%s)"\s+"([^"]+)"\s*\{' % KINDS, re.M)


def close_brace(t, ob):
    """Index of the brace closing the one at `ob`, ignoring strings/comments/heredocs.

    A naive counter mis-parses stacks that embed shell scripts (openclaw, crowdsec,
    technitium all carry heredocs with unbalanced braces).
    """
    i, depth, n = ob, 0, len(t)
    while i < n:
        c = t[i]
        if c == "#" or (c == "/" and i + 1 < n and t[i + 1] == "/"):
            j = t.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == "/" and i + 1 < n and t[i + 1] == "*":
            j = t.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        m = re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)", t[i:i + 40])
        if m:
            end = re.search(r"^\s*%s\s*$" % re.escape(m.group(1)), t[i:], re.M)
            i = n if not end else i + end.end()
            continue
        if c == '"':
            i += 1
            while i < n:
                if t[i] == "\\":
                    i += 2
                    continue
                if t[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def live_inventory():
    out = subprocess.run(
        ["kubectl", "get", "deploy,statefulset,daemonset", "-A", "-o", "json"],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("kubectl failed: %s" % out.stderr.strip())
    live = {}
    for i in json.loads(out.stdout)["items"]:
        md = i["metadata"]
        ann = md.get("annotations") or {}
        lbl = md.get("labels") or {}
        live.setdefault(md["name"], []).append({
            "ns": md["namespace"],
            # Keel honours the annotation; the label form is used as an opt-out too.
            "policy": ann.get("keel.sh/policy") or lbl.get("keel.sh/policy"),
            "containers": len(i["spec"]["template"]["spec"].get("containers", [])),
        })
    return live


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    live = live_inventory()
    gaps, enrolled, unresolved = [], 0, []

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".terraform", ".worktrees")]
        for fn in sorted(filenames):
            if not fn.endswith(".tf"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in RES_RE.finditer(text):
                ob = text.index("{", m.start())
                ce = close_brace(text, ob)
                if ce is None:
                    unresolved.append((os.path.relpath(p, root), m.group(2), "unparsable block"))
                    continue
                block = text[ob:ce + 1]
                nm = re.search(r'metadata\s*\{[^}]*?name\s*=\s*"([^"]+)"', block, re.S)
                if not nm:
                    continue  # name is an expression; can't resolve statically
                cands = live.get(nm.group(1), [])
                if len(cands) != 1:
                    continue  # not deployed, or ambiguous across namespaces
                w = cands[0]
                if not w["policy"] or w["policy"] == "never":
                    continue  # Terraform legitimately owns this one
                enrolled += 1
                ignored = set(int(x) for x in re.findall(r"container\[(\d+)\]\.image", block))
                missing = [i for i in range(w["containers"]) if i not in ignored]
                if missing:
                    gaps.append((os.path.relpath(p, root), m.group(2),
                                 "%s/%s" % (w["ns"], nm.group(1)), w["policy"], missing))

    print("Keel-enrolled workloads managed in Terraform: %d" % enrolled)
    if unresolved:
        print("\nUnparsable blocks (%d):" % len(unresolved))
        for f, n, why in unresolved:
            print("  %-50s %-24s %s" % (f, n, why))
    if not gaps:
        print("\nOK: no Keel-enrolled workload has its image tracked by Terraform.")
        return 0
    print("\nGAPS (%d) — Keel may bump these but Terraform still tracks the image:" % len(gaps))
    for f, n, w, pol, missing in sorted(gaps):
        print("  %-50s %-24s %-30s policy=%-6s container idx %s"
              % (f, n, w, pol, missing))
    print("\nAdd, for each listed index N:")
    print('  spec[0].template[0].spec[0].container[N].image, # KEEL_IGNORE_IMAGE')
    print("Read N off the live pod — it is not always 0.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
