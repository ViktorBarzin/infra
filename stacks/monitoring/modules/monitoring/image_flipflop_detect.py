#!/usr/bin/env python3
"""Detect Deployments whose container image is being rewritten by two owners.

Keel and whatever else declares a workload's image (a Terraform helm_release,
a raw kubernetes_deployment, the authentik server) can both be authoritative
over `spec.template.spec.containers[*].image`. When they are, each rewrites
the other's value forever. Nothing surfaces it: Keel logs a normal "resource
updated", the other owner logs a normal reconcile, and the only evidence is a
Deployment quietly replacing its pod every hour.

The Kyverno rule `keel-never-when-another-owner` prevents the cases that
declare an owner via `app.kubernetes.io/managed-by`. That label undercounts —
a raw kubernetes_deployment carries no such label — so this detector is the
backstop, keyed on observed BEHAVIOUR rather than on a label someone has to
remember to set.

Signal: within a 24h window, a Deployment produced >= 3 ReplicaSets and an
image set REAPPEARED after being replaced. That last part is what separates a
fight from ordinary deploy churn — a normal upgrade history only ever moves
forward.

Pure stdlib on purpose (no pip/apk at runtime — see the status-page-pusher
anti-pattern in .claude/CLAUDE.md).
"""

import json
import os
import ssl
import sys
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone

WINDOW_HOURS = 24
MIN_REPLICASETS = 3
# How recently the fight must have had a round to count as still running.
# Sized against the CronJob's 6h period: a live fight always has a round
# inside it, and a fixed one clears within one scan instead of a whole day.
ACTIVE_WITHIN_HOURS = 6

SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def _parse(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def find_flipflops(replicasets, now, window_hours=WINDOW_HOURS,
                   min_replicasets=MIN_REPLICASETS,
                   active_within_hours=ACTIVE_WITHIN_HOURS):
    """Return the deployments whose image set is being rewritten in a loop.

    `replicasets` is a list of {namespace, owner, creationTimestamp, images}.
    `now` is an RFC3339 string. Returns a list of dicts, one per offender.
    """
    cutoff = _parse(now) - timedelta(hours=window_hours)

    grouped = defaultdict(list)
    for item in replicasets:
        owner = item.get("owner")
        if not owner:
            continue  # orphan ReplicaSet — no Deployment to blame
        created = _parse(item["creationTimestamp"])
        if created <= cutoff:
            continue
        # Sorted, so a container REORDER (live order can differ from the
        # declared order — stacks/proxy hit exactly that) is not mistaken
        # for an image change.
        grouped[(item["namespace"], owner)].append(
            (created, tuple(sorted(item["images"])))
        )

    out = []
    for (namespace, deployment), entries in sorted(grouped.items()):
        if len(entries) < min_replicasets:
            continue
        entries.sort()

        # Collapse consecutive duplicates first: several ReplicaSets carrying
        # the same image (scale events, restarts) are one state, not churn.
        collapsed = [entries[0]]
        for created, images in entries[1:]:
            if images != collapsed[-1][1]:
                collapsed.append((created, images))
        states = [images for _, images in collapsed]

        # A forward-only history has every state exactly once. A repeat means
        # something put back a value that had already been replaced.
        if len(collapsed) < 3 or len(states) == len(set(states)):
            continue

        # Is the fight still running? Take the most recent moment an
        # already-seen image set came BACK — that is the last actual round of
        # the fight. Once someone fixes it no further rounds happen, so this
        # timestamp stops moving and the finding ages out within
        # `active_within_hours` instead of lingering for the full 24h window.
        # An alert that keeps firing for a day after the fix is how a new
        # alert gets muted.
        #
        # Deliberately NOT "the newest ReplicaSet": an ordinary deploy to a
        # brand-new image after the fight ended would revive the stale finding.
        #
        # Trade-off: a fight whose rounds are further apart than
        # `active_within_hours` can need a second scan to surface. Every
        # instance seen so far cycles far faster than that (Keel polls hourly;
        # proxy-gw-1 managed six rounds in 30 minutes), and the alternative —
        # reporting fights that are already over — is the worse failure.
        last_round = None
        for idx, (created, images) in enumerate(collapsed):
            if images in states[:idx]:
                last_round = created
        if last_round is None or last_round <= _parse(now) - timedelta(hours=active_within_hours):
            continue

        # Report only the images that actually vary — a multi-container pod
        # can be fought over by one sidecar while the app image never moves.
        varying = set().union(*states) - set.intersection(*map(set, states))
        out.append({
            "namespace": namespace,
            "deployment": deployment,
            "replicaset_count": len(entries),
            "distinct_states": len(set(states)),
            "images": sorted(varying),
        })
    return out


def _api(path):
    token = open(f"{SA}/token").read().strip()
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    req = urllib.request.Request(
        f"https://{host}:{port}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
        return json.load(resp)


def collect():
    """Flatten every ReplicaSet in the cluster into the detector's shape."""
    data = _api("/apis/apps/v1/replicasets?limit=5000")
    items = []
    for rs in data.get("items", []):
        meta = rs["metadata"]
        owners = meta.get("ownerReferences") or []
        owner = next((o["name"] for o in owners if o.get("kind") == "Deployment"), None)
        containers = rs["spec"]["template"]["spec"].get("containers") or []
        items.append({
            "namespace": meta["namespace"],
            "owner": owner,
            "creationTimestamp": meta["creationTimestamp"],
            "images": [c["image"] for c in containers],
        })
    return items


def push(findings, pushgateway):
    lines = [
        "# HELP image_owner_conflict Deployment whose image is rewritten by two owners.",
        "# TYPE image_owner_conflict gauge",
    ]
    for f in findings:
        lines.append(
            'image_owner_conflict{namespace="%s",deployment="%s"} 1'
            % (f["namespace"], f["deployment"])
        )
    lines += [
        "# HELP image_owner_conflict_count Number of deployments in an image-ownership fight.",
        "# TYPE image_owner_conflict_count gauge",
        "image_owner_conflict_count %d" % len(findings),
        "# HELP image_owner_conflict_last_run_timestamp Unix time of the last detector run.",
        "# TYPE image_owner_conflict_last_run_timestamp gauge",
        "image_owner_conflict_last_run_timestamp %d"
        % int(datetime.now(timezone.utc).timestamp()),
    ]
    body = ("\n".join(lines) + "\n").encode()
    req = urllib.request.Request(
        f"{pushgateway}/metrics/job/image-flipflop-detect", data=body, method="PUT"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status


def main():
    pushgateway = os.environ.get(
        "PUSHGATEWAY_URL",
        "http://prometheus-prometheus-pushgateway.monitoring:9091",
    )
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    findings = find_flipflops(collect(), now=now)

    if findings:
        print(f"{len(findings)} deployment(s) with a contested image:")
        for f in findings:
            print(
                f"  {f['namespace']}/{f['deployment']} — "
                f"{f['replicaset_count']} ReplicaSets in {WINDOW_HOURS}h, "
                f"{f['distinct_states']} states, contested: {', '.join(f['images'])}"
            )
    else:
        print(f"no image-ownership conflicts in the last {WINDOW_HOURS}h")

    # A push failure must not read as "nothing wrong" — exit non-zero so the
    # Job fails visibly rather than leaving a stale gauge behind.
    status = push(findings, pushgateway)
    if status >= 300:
        print(f"pushgateway returned {status}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
