#!/usr/bin/env python3
"""Regenerate the Tier-0 half of the stray-workload reconciler's inventory.

The reconciler (stacks/monitoring/modules/monitoring/stray_workload_detect.py)
reads Tier-1 declarations straight out of the `terraform_state` database on the
CNPG cluster, so those need no help. Tier-0 stacks keep LOCAL state in the repo
(root terragrunt.hcl: infra, platform, cnpg, vault, dbaas, external-secrets),
which a CronJob has no way to reach — hence this committed projection.

    python3 scripts/gen-tier0-workload-inventory.py

Run it from the repo root. Tier-0 state is committed as SOPS-encrypted
`.enc` files and decrypted locally by `scripts/state-sync decrypt <stack>`
(Vault token needed), so the plaintext may be absent; the script then names the
command that produces it rather than writing a short inventory. Output goes to
stacks/monitoring/modules/monitoring/declared_tier0.json.

When to run it: after adding, removing, or renaming a Deployment, StatefulSet,
DaemonSet, CronJob or helm_release in one of the six Tier-0 stacks. Those six
exist to be bootstrap-stable and change a couple of times a year, so this is
rare. Forgetting produces a FALSE POSITIVE — the new workload is reported as
stray until the file is regenerated — never a false negative, and the alert
text names this script.

Only kind, namespace, name and stack are written out. The state documents also
hold secrets, so anything beyond those four fields must stay out of the file.
"""

import glob
import json
import os
import sys
from datetime import datetime, timezone

# From the root terragrunt.hcl `tier0_stacks` local. Kept as a literal so the
# script says plainly which stacks it covers; a mismatch shows up as a stack
# with no state file, which the run reports.
TIER0_STACKS = ["infra", "platform", "cnpg", "vault", "dbaas", "external-secrets"]

KIND_OF = {
    "kubernetes_deployment": "Deployment",
    "kubernetes_deployment_v1": "Deployment",
    "kubernetes_stateful_set": "StatefulSet",
    "kubernetes_stateful_set_v1": "StatefulSet",
    "kubernetes_daemonset": "DaemonSet",
    "kubernetes_daemon_set": "DaemonSet",
    "kubernetes_daemon_set_v1": "DaemonSet",
    "kubernetes_cron_job": "CronJob",
    "kubernetes_cron_job_v1": "CronJob",
    "helm_release": "HelmRelease",
}

OUT = "stacks/monitoring/modules/monitoring/declared_tier0.json"


def load_state(path):
    with open(path) as fh:
        return json.load(fh)


def declarations(state, stack):
    out = []
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        kind = KIND_OF.get(resource.get("type"))
        if not kind:
            continue
        for instance in resource.get("instances", []):
            attrs = instance.get("attributes") or {}
            metadata = attrs.get("metadata")
            # kubernetes_* keeps metadata as a single-element list; helm_release
            # keeps name/namespace at the top level.
            if isinstance(metadata, list) and metadata:
                name = metadata[0].get("name")
                namespace = metadata[0].get("namespace") or ""
            else:
                name = attrs.get("name")
                namespace = attrs.get("namespace") or ""
            if not name:
                sys.exit(f"{stack}: {resource['type']}.{resource['name']} has no name in state")
            out.append([kind, namespace, name, stack])
    return out


def main():
    if not os.path.isdir("state/stacks"):
        sys.exit("run this from the repo root (no state/stacks directory here)")

    # Refuse on ANY missing stack rather than writing a short inventory. A
    # partial file is the failure mode that matters here: it produces phantom
    # findings for the stacks that were skipped.
    missing = [s for s in TIER0_STACKS
               if not os.path.exists(f"state/stacks/{s}/terraform.tfstate")]
    if missing:
        sys.exit(
            "no decrypted state for: " + ", ".join(missing) + "\n"
            "run: " + " && ".join(f"scripts/state-sync decrypt {s}" for s in missing))

    rows = []
    for stack in TIER0_STACKS:
        rows += declarations(load_state(f"state/stacks/{stack}/terraform.tfstate"), stack)

    # The repo root carries a small state file of its own (3 cloudflare
    # records, 2 manifests, a service — no workloads today, read anyway so a
    # future one is not a surprise).
    for path in sorted(glob.glob("state/terraform.tfstate")):
        rows += declarations(load_state(path), "root")

    rows.sort()
    payload = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generated_by": "scripts/gen-tier0-workload-inventory.py",
        "why": (
            "Tier-0 stacks keep local state in the repo, which the "
            "stray-workload reconciler CronJob cannot read. Regenerate after "
            "changing a workload or helm_release in one of these stacks."
        ),
        "stacks": TIER0_STACKS,
        "declarations": rows,
    }
    with open(OUT, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")

    print(f"wrote {OUT}: {len(rows)} declarations from {len(TIER0_STACKS)} stacks")
    for kind, namespace, name, stack in rows:
        print(f"  {kind} {namespace}/{name}  ({stack})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
