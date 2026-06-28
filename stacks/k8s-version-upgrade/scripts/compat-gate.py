#!/usr/bin/env python3
"""
Preflight compatibility gate for the k8s version-upgrade chain.

Decides whether it is SAFE to auto-upgrade Kubernetes to a target version, so the
chain can "upgrade whenever it can, and halt + alert when it can't" without a
human in the loop. Reads the addon-compat matrix (JSON on stdin) and checks three
classes of blocker:

  1. addon compat  — every critical addon's RUNNING version must support the
                     target k8s minor (Calico is the usual blocker)
  2. removed APIs  — no in-use API (Prometheus apiserver_requested_deprecated_apis)
                     is removed at/before the target minor
  3. containerd    — every node's containerd >= the target's floor, if the matrix
                     declares one (e.g. the 1.7.x -> k8s 1.37 cliff)

Each reason line is tagged with its class so the caller can act differently:
  [ACTIONABLE]  a newer addon version (present in the matrix) supports the
                target — upgrading it clears the block. Also covers removed-API
                / containerd blocks and the unreadable-version fail-safe.
  [WAITING]     no released addon version supports the target yet — only an
                upstream release can clear it (e.g. kyverno/ESO behind a new k8s).
  [PINNED]      a supporting version exists but the addon is deliberately held
                (matrix `pinned: true`, e.g. gpu-operator's driver/OS coupling).

Exit 0  = safe, proceed.
Exit 2  = BLOCKED, actionable — >=1 blocker, none held. Caller pushes
          k8s_upgrade_blocked=1 (-> K8sUpgradeBlocked alert) and halts.
Exit 4  = HELD — >=1 waiting-upstream/pinned blocker (held wins over actionable).
          Caller pushes k8s_upgrade_held=1 (no alert; nightly report only) and halts.
Exit 3  = the gate itself errored — caller treats as a block (fail safe).

Read-only: kubectl get + one Prometheus query. No mutations. PROM is overridable
via $PROM for local testing (cluster DNS isn't resolvable off-cluster).
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

PROM = os.environ.get("PROM", "http://prometheus-server.monitoring.svc.cluster.local:80")


def minor(v):
    """'v1.35.6' | '1.35.6' | '1.35' -> (1, 35); None if unparseable."""
    m = re.search(r"(\d+)\.(\d+)", v or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def kget(args):
    try:
        r = subprocess.run(["kubectl", *args], capture_output=True, text=True, timeout=30)
        return r.stdout.strip()
    except Exception:
        return ""


def running_minor():
    """Oldest kubelet minor across all nodes, as a (major, minor) tuple.

    Mirrors the detector's "oldest kubelet" choice so a partially-upgraded
    cluster is judged by its lowest node, not its newest. RUNNING_K8S overrides
    for local testing. None if undeterminable (treated as a minor jump → the
    addon checks run in full, fail-safe)."""
    env = os.environ.get("RUNNING_K8S")
    if env:
        return minor(env)
    out = kget(["get", "nodes", "-o",
                "jsonpath={range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}"])
    minors = [minor(line) for line in out.splitlines() if minor(line)]
    return min(minors) if minors else None


def _addon_resolution(a, tgt, running_ver):
    """For a BLOCKING addon, decide whether a newer matrix version would clear
    the block. Returns ("actionable", hint) when some version key has
    max_k8s >= target AND is newer than the running version (upgrading it clears
    the block); otherwise ("waiting", hint) — nothing released supports the
    target yet, so only an upstream release can clear it."""
    sufficient = [floor for floor, mk in a["max_k8s"].items()
                  if minor(mk) and minor(mk) >= tgt and minor(floor) > minor(running_ver)]
    if sufficient:
        best = min(sufficient, key=minor)  # smallest sufficient upgrade
        return "actionable", f"upgrade {a['name']} to >= {best}"
    return "waiting", f"no released {a['name']} version supports k8s {tgt[0]}.{tgt[1]} yet"


def check_addons(matrix, tgt, running):
    # A target at or below the RUNNING minor (a patch, or a same/lower minor)
    # crosses into no new k8s minor, so every installed addon is already
    # empirically proven on it — addon ceilings only constrain a true minor jump.
    # Without this guard an addon whose matrix ceiling sits below the running
    # minor (e.g. ESO 0.12 → 1.31 on a cluster already running 1.34) would
    # false-block legitimate patch upgrades, defeating autonomous patching.
    if running and tgt <= running:
        return []
    reasons = []
    for a in matrix.get("addons", []):
        img = kget(["-n", a["namespace"], "get", a["kind"], a["resource"],
                    "-o", "jsonpath={.spec.template.spec.containers[*].image}"])
        m = re.search(a["image_re"], img or "")
        if not m:
            # Fail safe: can't read the running version → block; a human must
            # look (ACTIONABLE), never upgrade blind.
            reasons.append(f"[ACTIONABLE] addon {a['name']}: could not read running "
                           f"version (img='{img or 'not found'}') — refusing to upgrade blind")
            continue
        running_ver = m.group(1)  # e.g. "3.26"
        # max_k8s maps an addon-version floor -> highest supported k8s minor.
        # Pick the highest floor that is <= the running version.
        max_k8s = None
        for floor, mk in sorted(a["max_k8s"].items(), key=lambda kv: minor(kv[0]), reverse=True):
            if minor(running_ver) >= minor(floor):
                max_k8s = mk
                break
        if max_k8s is None:
            reasons.append(f"[ACTIONABLE] addon {a['name']} v{running_ver}: below the lowest "
                           f"version in the compat matrix — unknown k8s support")
            continue
        if tgt > minor(max_k8s):
            base = (f"addon {a['name']} v{running_ver} supports k8s <= {max_k8s}; "
                    f"target {tgt[0]}.{tgt[1]} exceeds it")
            # A deliberately-pinned addon is HELD even if a newer version exists
            # (e.g. gpu-operator 26.3 supports 1.36 but its driver/OS coupling
            # means we don't take it yet) — the pin overrides actionable.
            if a.get("pinned"):
                why = a.get("pin_reason", "deliberately pinned")
                reasons.append(f"[PINNED] {base} — pinned ({why}); holding")
            else:
                kind, hint = _addon_resolution(a, tgt, running_ver)
                tag = "ACTIONABLE" if kind == "actionable" else "WAITING"
                reasons.append(f"[{tag}] {base} — {hint}")
    return reasons


def check_removed_apis(tgt):
    reasons = []
    try:
        url = PROM + "/api/v1/query?query=apiserver_requested_deprecated_apis"
        data = json.load(urllib.request.urlopen(url, timeout=20))
        for s in data.get("data", {}).get("result", []):
            lbl = s["metric"]
            rr = lbl.get("removed_release", "")
            if rr and minor(rr) and tgt >= minor(rr):
                g = lbl.get("group") or "core"
                reasons.append(f"[ACTIONABLE] deprecated API {g}/{lbl.get('version')} "
                               f"{lbl.get('resource')} is in use and is removed in "
                               f"k8s {rr} (target {tgt[0]}.{tgt[1]}) — migrate callers first")
    except Exception as e:
        reasons.append(f"[ACTIONABLE] removed-API check could not query Prometheus ({e}) — "
                       f"refusing to upgrade blind")
    return reasons


def check_containerd(matrix, tgt):
    reasons = []
    floor = matrix.get("containerd_min", {}).get(f"{tgt[0]}.{tgt[1]}")
    if not floor:
        return reasons
    out = kget(["get", "nodes", "-o",
                "jsonpath={range .items[*]}{.metadata.name}{\" \"}"
                "{.status.nodeInfo.containerRuntimeVersion}{\"\\n\"}{end}"])
    for line in out.splitlines():
        if not line.strip():
            continue
        name, _, ver = line.partition(" ")
        cv = ver.replace("containerd://", "")
        if minor(cv) and minor(cv) < minor(floor):
            reasons.append(f"[ACTIONABLE] node {name} containerd {cv} < required {floor} "
                           f"for k8s {tgt[0]}.{tgt[1]} — bump containerd first")
    return reasons


def held_reason(r):
    """True for a blocker the cluster cannot act on now: no released version
    supports the target (WAITING) or the addon is deliberately pinned (PINNED).
    These are quiet (no alert) — only an upstream release / a manual unpin clears
    them, so a nightly 'needs attention' alert would be crying wolf."""
    return r.startswith("[WAITING]") or r.startswith("[PINNED]")


def exit_code(reasons):
    """Map reasons to the gate verdict: 0 safe · 2 actionable block · 4 held.
    Held WINS over actionable on a mix — if anything is waiting/pinned the target
    can't proceed yet, so acting on the actionable blockers would be premature."""
    if not reasons:
        return 0
    return 4 if any(held_reason(r) for r in reasons) else 2


def main():
    if len(sys.argv) < 2:
        print("usage: compat-gate.py <target-k8s-version>  (matrix JSON on stdin)")
        sys.exit(3)
    tgt = minor(sys.argv[1])
    if not tgt:
        print(f"bad target version '{sys.argv[1]}'")
        sys.exit(3)
    try:
        matrix = json.load(sys.stdin)
    except Exception as e:
        print(f"could not parse compat matrix JSON: {e}")
        sys.exit(3)

    running = running_minor()
    reasons = (check_addons(matrix, tgt, running)
               + check_removed_apis(tgt)
               + check_containerd(matrix, tgt))
    if reasons:
        for r in reasons:
            print(r)
    else:
        print(f"compat-gate OK: cluster is safe to upgrade to {sys.argv[1]}")
    sys.exit(exit_code(reasons))


if __name__ == "__main__":
    main()
