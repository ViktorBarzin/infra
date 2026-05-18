---
name: upgrade-state
description: |
  Audit the three autonomous-upgrade pipelines (apps via Keel, OS via
  unattended-upgrades+kured, K8s components via the version-check chain).
  Use when:
  (1) User asks "/upgrade-state" or "are we current",
  (2) User asks "what's pending upgrade" or "what's the upgrade state",
  (3) User asks if Keel / kured / k8s-version-check is healthy,
  (4) User asks about kept-back / held packages or pending reboots,
  (5) Periodic survey before the next `k8s-version-check` daily run.
  Read-only — no `--fix`. Exits 0 healthy / 1 attention / 2 stalled.
author: Claude Code
version: 1.0.0
date: 2026-05-18
---

# Upgrade-state

## MANDATORY: Run the script first

When this skill is invoked, your **first action** must be to run
`upgrade_state.sh` and reason over its output before doing anything
else. Do NOT improvise individual `kubectl` / `ssh` calls — the script
is the authoritative surface.

```bash
bash /home/wizard/code/infra/scripts/upgrade_state.sh
```

For programmatic use:

```bash
bash /home/wizard/code/infra/scripts/upgrade_state.sh --json | tee /tmp/upgrade-state.json
```

Then:

1. Report the rendered table verbatim — it answers the user's
   "are we current" question in three lines.
2. For every `⚠` or `✗` row, surface the relevant drill-down lines
   underneath and propose a next action (links in the table below).
3. Only reach for ad-hoc commands when investigating beyond what the
   script reported.

Exit codes: `0` healthy, `1` attention warranted, `2` stalled / broken.

## What it covers (3 pipelines)

| Layer | What runs | Cadence | Data sources |
|---|---|---|---|
| **Apps** | Keel polls every watched Deployment's container registry; rolls on new digest | hourly | Prom (`pending_approvals`, `registries_scanned_total`), Keel pod logs |
| **OS** | `unattended-upgrades` in-release patching; `kured` reboots when `/var/run/reboot-required` is set | daily 02:00-06:00 London | SSH fan-out to all 5 nodes |
| **K8s** | `k8s-version-check` CronJob detects new kubeadm patch/minor; spawns the Job-chain that drains+upgrades node-by-node | daily 12:00 UTC | Pushgateway (`k8s_upgrade_*`), `kubectl get nodes` |

The K8s pipeline pushes a small set of gauges to the Prometheus
Pushgateway (`prometheus-prometheus-pushgateway.monitoring:9091`):

- `k8s_upgrade_available{kind="patch"|"minor",target=…}` — 1 if newer release detected
- `k8s_version_check_last_run_timestamp` — when detection last ran
- `k8s_upgrade_in_flight` — 0/1
- `k8s_upgrade_started_timestamp` — when the current chain started (0 when idle)

`K8sUpgradeStalled` alert fires when `in_flight=1` and the chain has
been running >90 minutes. The script raises `✗` in the same window.

## Status-icon legend

| Icon | Meaning |
|---|---|
| `✓` | Healthy, fully current |
| `→` | Update available, not yet applied (K8s patch/minor) |
| `…` | In flight — chain currently running |
| `⚠` | Attention: held-with-bumps, recent errors, pending approvals |
| `✗` | Broken: pod down, alert firing, chain stalled |

## Drill-down — when a row trips, what to do

### Apps `⚠` — pending approvals or errors

```bash
# Read recent Keel log lines
kubectl -n keel logs deploy/keel --since=24h --tail=200

# What is Keel currently tracking?
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=count by (image) (registries_scanned_total)'

# Is the scrape live?
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="kubernetes-pods",app="keel"}'
```

Common Keel errors:
- `failed to add image watch job` — image annotation mistyped (rare; Kyverno auto-injects)
- `registry authentication required` — bad imagePullSecret on the watched Deployment
- `bad tag pattern` — Keel can't parse the watched image's tag against its policy

### OS `⚠` — held packages with bumps

The script flags any package held via `apt-mark hold` that ALSO appears
in `apt list --upgradable` — excluding k8s components (the K8s pipeline
owns those) and the kernel (kured handles the reboot half).

Typical cause: a major-version bump (e.g. containerd 1.7 → 2.2,
runc 1.1 → 1.4). These are held because they need cluster-wide
coordination, not silent in-release patching.

```bash
# Inspect the situation on the flagged node
ssh wizard@10.0.20.10X 'apt-mark showhold; apt list --upgradable 2>/dev/null'

# Unhold + upgrade a specific package
ssh wizard@10.0.20.10X 'sudo apt-mark unhold containerd && sudo apt-get install -y containerd'
```

Node IPs: master=`100`, node1=`101`, node2=`102`, node3=`103`, node4=`104`.

### OS `⚠` — pending reboot

A node has `/var/run/reboot-required`. Kured will reboot it inside the
next 02:00-06:00 London window (any day of the week).

```bash
# Force a manual reboot inside the window (rare)
kubectl drain k8s-nodeX --delete-emptydir-data --ignore-daemonsets
ssh wizard@10.0.20.10X sudo systemctl reboot
```

### OS `✗` — kured not Running

```bash
kubectl -n kured get pods
kubectl -n kured logs daemonset/kured --tail=100
# Verify sentinel gate (kured-sentinel-gate DaemonSet writes /var/run/gated-reboot-required)
kubectl -n kured get pods -l name=kured-sentinel-gate
```

### K8s `→` — patch/minor available

Detection ran, target identified, chain NOT started. The chain spawns
on the same daily detection cycle — typically within ~24h of the
target first being detected.

```bash
# Inspect Pushgateway state
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
    wget -qO- 'http://prometheus-prometheus-pushgateway:9091/metrics' | grep ^k8s_upgrade

# Trigger a manual run of the detection CronJob
kubectl -n k8s-upgrade create job --from=cronjob/k8s-version-check manual-detect-$(date +%s)
```

### K8s `…` — in flight

The Job chain is running. Watch its progress:

```bash
kubectl -n k8s-upgrade get jobs --sort-by=.metadata.creationTimestamp
kubectl -n k8s-upgrade logs -l app=k8s-version-upgrade --tail=200 --prefix
```

### K8s `✗ stalled` — `K8sUpgradeStalled` would fire

Chain in-flight >90m. The Job is most likely stuck on drain or a
pre-flight check.

```bash
kubectl -n k8s-upgrade get jobs
kubectl -n k8s-upgrade describe job <stuck-job>
kubectl -n k8s-upgrade logs job/<stuck-job> --tail=300

# If you need to clear the in-flight flag (after diagnosing):
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- sh -c \
    "printf 'k8s_upgrade_in_flight 0\nk8s_upgrade_started_timestamp 0\n' | \
     wget -qO- --post-file=- 'http://prometheus-prometheus-pushgateway:9091/metrics/job/k8s-version-upgrade' \
       --header='Content-Type: text/plain'"
```

### K8s `✗ detection stale` — last detection >9 days

```bash
kubectl -n k8s-upgrade get cronjob k8s-version-check
kubectl -n k8s-upgrade get jobs --sort-by=.metadata.creationTimestamp | tail -5
```

If the CronJob hasn't fired on time, suspect:
- `suspend=true` on the CronJob (`var.enabled=false` in the
  `k8s-version-upgrade` Terraform stack)
- Image-pull failure on the version-check pod
- Pushgateway scrape gone stale

## Companion command-line flags

```bash
bash infra/scripts/upgrade_state.sh                 # rendered table (default)
bash infra/scripts/upgrade_state.sh --json          # machine output
bash infra/scripts/upgrade_state.sh --kubeconfig X  # override kubeconfig
```
