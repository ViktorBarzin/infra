# K8s Version Upgrade Pipeline

## Overview

Kubernetes component versions (`kubeadm`/`kubelet`/`kubectl`) on the 5 K8s
VMs are upgraded automatically by a weekly detection CronJob that fires the
`k8s-version-upgrade` agent through `claude-agent-service`. The agent walks
the cluster through pre-flight → etcd snapshot → optional master containerd
skew fix → optional apt repo URL rewrite (minor only) → master kubeadm
upgrade → workers rolled sequentially → post-flight, with Slack notification
at every transition and Prometheus halt-on-alert gating before every drain.

This is **independent** of the OS-side `unattended-upgrades + kured`
pipeline (see `k8s-node-auto-upgrades.md`). They do not share rollouts and
their schedules don't overlap (kured runs Mon-Fri 02:00-06:00 London;
detection here runs Sun 12:00 UTC).

## Architecture

```
k8s-version-check CronJob   (Sun 12:00 UTC)
  │ kubectl get nodes  → running version
  │ ssh master 'apt-cache madison kubeadm'  → latest patch (within current minor)
  │ HEAD pkgs.k8s.io/.../v<NEXT_MINOR>/deb/Release  → next minor available?
  │
  ▼ if running != latest_patch  OR  next minor available
POST claude-agent-service /execute
  { prompt: "Run k8s-version-upgrade agent. Inputs: {target_version, kind, dry_run, stages}" }
  │
  ▼
k8s-version-upgrade agent  (inside claude-agent-service pod)
  ├── Stage 0: parse inputs, mark in-flight annotation + Pushgateway gauge
  ├── Stage 1: pre-flight (5 nodes Ready + halt-on-alert + 24h-quiet + plan target match)
  ├── Stage 2: etcd snapshot save → /mnt/main/etcd-backup/k8s-upgrade-pre-X.Y.Z-EPOCH.db
  │            push k8s_upgrade_snapshot_taken=1
  ├── Stage 3: master containerd bump (only if master < workers)
  ├── Stage 4: apt repo URL rewrite to v<NEW_MINOR>/deb (only if kind=minor)
  ├── Stage 5: drain master → ssh < update_k8s.sh --role master --release X.Y.Z → uncordon → verify
  ├── Stage 6: each worker k8s-node4 → k8s-node3 → k8s-node2 → k8s-node1:
  │            halt-on-alert wait → drain → ssh script --role worker → uncordon → 10-min soak
  └── Stage 7: post-flight (all nodes match target, alerts clean, pod-ready ratio ≥ 0.9)
               clear in-flight annotation, push k8s_upgrade_in_flight=0
```

## Components

### Detection CronJob (`k8s-version-check`)
- **Stack**: `infra/stacks/k8s-version-upgrade/main.tf`
- **Image**: `forgejo.viktorbarzin.me/viktor/claude-agent-service` (ships kubectl, ssh-client, curl, jq)
- **Schedule**: `0 12 * * 0` (Sunday 12:00 UTC). Outside kured window.
- **SA**: `k8s-version-check` (cluster-read nodes, ns-scoped get on `k8s-upgrade-creds` Secret)
- **Pushgateway metrics**:
  - `k8s_upgrade_available{kind, running, target}` — 1 when a target is detected
  - `k8s_version_check_last_run_timestamp` — staleness watchdog

### Agent (`k8s-version-upgrade`)
- **Prompt**: `infra/.claude/agents/k8s-version-upgrade.md`
- **Runtime**: claude-agent-service pod (claude-agent ns)
- **Inputs** (JSON in prompt): `target_version`, `kind` (patch|minor), `dry_run`, `stages`
- **Library script**: `infra/scripts/update_k8s.sh` (run on each node via SSH pipe — `ssh ... 'bash -s' < update_k8s.sh -- --role master|worker --release X.Y.Z`)

### Upgrade Gates alerts (additions for this pipeline)
- **`K8sVersionSkew`** — distinct kubelet/apiserver `gitVersion` count >1 for 30m. Catches a half-done rollout where some nodes are upgraded and some aren't.
- **`EtcdPreUpgradeSnapshotMissing`** — `k8s_upgrade_in_flight==1 && k8s_upgrade_snapshot_taken==0` for 10m. Catches Stage 2 failing silently.
- Both join the existing 10 Upgrade Gates alerts (KubeAPIServerDown, RecentNodeReboot, etc.) — kured ALSO blocks rolling reboots whenever any of these are firing.

### Vault secrets
- `secret/k8s-upgrade/ssh_key` — ed25519 PRIVATE key, used by detection CronJob + agent to SSH into all 5 nodes (user `wizard`)
- `secret/k8s-upgrade/ssh_key_pub` — matching PUBLIC key, deployed to `/home/wizard/.ssh/authorized_keys` on every node
- `secret/k8s-upgrade/slack_webhook` — Slack incoming-webhook URL (separate channel from kured for clean alerting)

Both keys exposed in K8s via ExternalSecret `k8s-upgrade-creds` in `k8s-upgrade` namespace.

## Common Operations

### Verify the pipeline is healthy
```bash
# CronJob present + not suspended
kubectl -n k8s-upgrade get cronjob k8s-version-check

# Latest run output
kubectl -n k8s-upgrade get jobs -l app=k8s-version-check
kubectl -n k8s-upgrade logs -l app=k8s-version-check --tail=200

# Pushgateway metric — fresh discovery?
curl -s http://prometheus-prometheus-pushgateway.monitoring:9091/metrics | \
  grep -E '^(k8s_upgrade_available|k8s_version_check_last_run_timestamp)'

# Upgrade Gates rules loaded
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O- 'http://localhost:9090/api/v1/rules' | \
  jq -r '.data.groups[] | select(.name == "Upgrade Gates") | .rules[] | "  \(.name): \(.state)"'
```

### Manually trigger a detection run (no upgrade)
Use `detection_dry_run=true` to short-circuit before the POST to
claude-agent-service:

```bash
# One-shot job from the cron, with DRY_RUN env override:
kubectl -n k8s-upgrade create job --from=cronjob/k8s-version-check version-check-test
kubectl -n k8s-upgrade logs -l job-name=version-check-test -f
```

To make `detection_dry_run` permanent (e.g. while debugging),
toggle the var in `stacks/k8s-version-upgrade/main.tf` and `scripts/tg apply`.

### Manually dispatch the agent (skip detection)
Useful when you want to force a run on a specific version without waiting for
Sunday, or when testing.

```bash
TOKEN=$(vault kv get -field=api_bearer_token secret/claude-agent-service)

# Dry-run (no mutations)
curl -X POST http://claude-agent-service.claude-agent.svc.cluster.local:8080/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Run the k8s-version-upgrade agent. Inputs: {\"target_version\":\"1.34.5\",\"kind\":\"patch\",\"dry_run\":true,\"stages\":\"all\"}",
    "agent": ".claude/agents/k8s-version-upgrade",
    "max_budget_usd": 5
  }'

# Snapshot-only (Test 3 in the plan)
curl -X POST ... -d '{
    "prompt": "Run the k8s-version-upgrade agent. Inputs: {\"target_version\":\"1.34.5\",\"kind\":\"patch\",\"dry_run\":false,\"stages\":\"preflight,snapshot\"}",
    ...
}'

# Real run
curl -X POST ... -d '{
    "prompt": "... Inputs: {\"target_version\":\"1.34.5\",\"kind\":\"patch\",\"dry_run\":false,\"stages\":\"all\"}",
    ...
}'
```

Poll job status:
```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://claude-agent-service.claude-agent.svc.cluster.local:8080/jobs/$JOB_ID | jq .
```

### Halt the pipeline in an emergency
The pipeline is gated by Prometheus alerts — any firing Upgrade Gates alert
blocks the next drain. To explicitly halt:

```bash
# Option 1: suspend the detection CronJob (won't stop an in-flight agent run)
kubectl -n k8s-upgrade patch cronjob k8s-version-check \
  -p '{"spec":{"suspend":true}}' --type=merge
# Re-enable: --type=merge -p '{"spec":{"suspend":false}}'

# Option 2: kill an in-flight agent job
TOKEN=$(vault kv get -field=api_bearer_token secret/claude-agent-service)
JOB_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  http://claude-agent-service.claude-agent.svc.cluster.local:8080/jobs | \
  jq -r '.[] | select(.agent | test("k8s-version-upgrade")) | .id' | head -1)
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://claude-agent-service.claude-agent.svc.cluster.local:8080/jobs/$JOB_ID

# Option 3: force a blocker alert (Upgrade Gates expression that always fires)
# — see infra/docs/runbooks/k8s-node-auto-upgrades.md "Force halt by adding a custom blocker alert"
```

### Rollback paths

`kubeadm` does **not** support in-place downgrade. If a run fails:

#### Master broke during/after kubeadm upgrade
1. Identify the etcd snapshot: `kubectl get ns k8s-upgrade -o jsonpath='{.metadata.annotations.viktorbarzin\.me/k8s-upgrade-snapshot-path}'`
2. Restore etcd per `infra/docs/runbooks/restore-etcd.md`.
3. Manually downgrade master `kubeadm`/`kubelet`/`kubectl` to the pre-upgrade version. Find versions in `/var/log/apt/history.log` on the node:
   ```bash
   ssh wizard@k8s-master 'sudo cat /var/log/apt/history.log | tail -40'
   # Pre-upgrade versions are in the most recent "Commandline: apt-get install"
   sudo apt-mark unhold kubeadm kubelet kubectl
   sudo apt-get install --allow-downgrades -y \
     kubeadm=<OLD>-1.1 kubelet=<OLD>-1.1 kubectl=<OLD>-1.1
   sudo apt-mark hold kubeadm kubelet kubectl
   sudo systemctl daemon-reload && sudo systemctl restart kubelet
   ```

#### Worker broke
1. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --grace-period=300`
2. Downgrade apt packages on that node only (see above)
3. `kubectl uncordon <node>`
4. The cluster continues running on the master + remaining workers throughout

#### Pipeline aborts mid-flight (halt-on-alert blocks >30 min)
- The agent posts a Slack message with the blocking alert list and exits non-zero
- The in-flight annotation on `ns/k8s-upgrade` stays set → `EtcdPreUpgradeSnapshotMissing` may fire if Stage 2 didn't complete
- Operator: triage the blocker, clear the alert, re-dispatch the agent manually (see "Manually dispatch the agent")
- After successful retry: the agent's Stage 7 clears the annotation. If you decide NOT to retry, clear by hand:
  ```bash
  kubectl annotate ns k8s-upgrade \
    viktorbarzin.me/k8s-upgrade-in-flight- \
    viktorbarzin.me/k8s-upgrade-target- \
    viktorbarzin.me/k8s-upgrade-snapshot-path-
  # Also reset the Pushgateway gauge so the alert clears:
  printf '# TYPE k8s_upgrade_in_flight gauge\nk8s_upgrade_in_flight 0\n' | \
    curl --data-binary @- http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/k8s-version-upgrade
  ```

### One-shot SSH key rotation
1. Generate new keypair: `ssh-keygen -t ed25519 -f /tmp/k8s-upgrade -N ""`
2. Update Vault:
   ```bash
   vault kv patch secret/k8s-upgrade \
     ssh_key=@/tmp/k8s-upgrade \
     ssh_key_pub=@/tmp/k8s-upgrade.pub
   ```
3. Push the new pubkey to every node:
   ```bash
   for n in k8s-master k8s-node1 k8s-node2 k8s-node3 k8s-node4; do
     # Remove old upgrade key (tag with "k8s-upgrade") then append new
     ssh wizard@$n 'sed -i "/k8s-upgrade-key$/d" ~/.ssh/authorized_keys'
     ssh wizard@$n 'echo "$(cat /tmp/k8s-upgrade.pub) k8s-upgrade-key" >> ~/.ssh/authorized_keys'
   done
   ```
4. ESO refreshes the K8s Secret within 15 min — or force: `kubectl -n k8s-upgrade annotate externalsecret k8s-upgrade-creds force-sync=$(date +%s) --overwrite`

## Past Incidents

- (none yet — pipeline went live 2026-05-10)
- Pre-pipeline manual upgrades documented in commit history; the `update_k8s.sh` shell of those manual runs is preserved in `infra/scripts/update_k8s.sh` and is what the agent shells into nodes with.

## File Pointers

| What | Where |
|------|-------|
| Detection CronJob + RBAC + ExternalSecret | `infra/stacks/k8s-version-upgrade/main.tf` |
| Agent prompt | `infra/.claude/agents/k8s-version-upgrade.md` |
| Library node script | `infra/scripts/update_k8s.sh` |
| Upgrade Gates alerts (incl. K8sVersionSkew + EtcdPreUpgradeSnapshotMissing) | `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` |
| Vault secrets | `secret/k8s-upgrade/{ssh_key, ssh_key_pub, slack_webhook}` |
| Architecture doc | `infra/docs/architecture/automated-upgrades.md` — "K8s Version Upgrades" section |
| Related (OS reboots) | `infra/docs/runbooks/k8s-node-auto-upgrades.md` |
