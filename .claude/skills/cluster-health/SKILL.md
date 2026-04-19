---
name: cluster-health
description: |
  Check Kubernetes cluster health and fix common issues. Use when:
  (1) User asks to check the cluster, check health, or "what's wrong",
  (2) User asks about pod status, node health, or deployment issues,
  (3) User asks to fix stuck pods, evicted pods, or CrashLoopBackOff,
  (4) User mentions "health check", "cluster status", "cluster health",
  (5) User asks "is everything running" or "any problems".
  Runs 42 cluster-wide checks (nodes, workloads, monitoring, certs,
  backups, external reachability) with safe auto-fix for evicted pods.
author: Claude Code
version: 2.0.0
date: 2026-04-19
---

# Cluster Health Check

## MANDATORY: Run the script first

When this skill is invoked, your **first action** must be to run the
cluster health check script and reason over its output before doing
anything else. Do not improvise individual `kubectl` calls — the
script is the authoritative surface.

```bash
cd /home/wizard/code
bash infra/scripts/cluster_healthcheck.sh --json | tee /tmp/cluster-health.json
```

If the session is rooted elsewhere, fall back to the absolute path:

```bash
bash /home/wizard/code/infra/scripts/cluster_healthcheck.sh --json
```

Then:

1. Parse the JSON. Report the PASS/WARN/FAIL counts + overall verdict.
2. Iterate every FAIL and WARN check, describe what tripped, and propose
   the remediation path (use the recipes below).
3. Only reach for ad-hoc `kubectl` commands when investigating a
   specific failure beyond what the script reported.

Exit codes: `0` = healthy, `1` = warnings only, `2` = failures.

## Quick flags

```bash
# Human-readable report (default), no auto-fix
bash infra/scripts/cluster_healthcheck.sh

# Machine-readable JSON summary
bash infra/scripts/cluster_healthcheck.sh --json

# Only show WARN + FAIL (suppress PASS noise)
bash infra/scripts/cluster_healthcheck.sh --quiet

# Enable auto-fix (delete evicted pods, kick stuck CrashLoop pods)
bash infra/scripts/cluster_healthcheck.sh --fix

# Combined: quiet JSON without auto-fix
bash infra/scripts/cluster_healthcheck.sh --no-fix --quiet --json

# Custom kubeconfig
bash infra/scripts/cluster_healthcheck.sh --kubeconfig /path/to/config
```

## What It Checks (42 checks)

| # | Check | Notes |
|---|-------|-------|
| 1 | Node Status | NotReady nodes, version drift |
| 2 | Node Resources | CPU/mem >80% (warn) / >90% (fail) |
| 3 | Node Conditions | MemoryPressure / DiskPressure / PIDPressure |
| 4 | Problematic Pods | CrashLoopBackOff / Error / ImagePullBackOff |
| 5 | Evicted/Failed Pods | `status.phase=Failed` |
| 6 | DaemonSets | desired == ready |
| 7 | Deployments | ready == desired replicas |
| 8 | PVC Status | all Bound |
| 9 | HPA Health | targets not `<unknown>`, utilization <100% |
| 10 | CronJob Failures | job conditions `Failed=True` in last 24h |
| 11 | CrowdSec Agents | all pods Running |
| 12 | Ingress Routes | every ingress has an LB IP + Traefik LB |
| 13 | Prometheus Alerts | count of firing alerts |
| 14 | Uptime Kuma Monitors | internal + external monitors up |
| 15 | ResourceQuota Pressure | any quota >80% used |
| 16 | StatefulSets | ready == desired |
| 17 | Node Disk Usage | ephemeral-storage <80% |
| 18 | Helm Release Health | all `deployed` (no `pending-*`) |
| 19 | Kyverno Policy Engine | all pods Running |
| 20 | NFS Connectivity | 192.168.1.127 showmount / port 2049 |
| 21 | DNS Resolution | Technitium resolves internal + external |
| 22 | TLS Certificate Expiry | TLS `Secret` certs >30d valid |
| 23 | GPU Health | nvidia namespace + device-plugin Running |
| 24 | Cloudflare Tunnel | pods Running |
| 25 | Resource Usage | node CPU/mem headroom |
| 26 | HA Sofia — Entity Availability | Home Assistant unavailable/unknown count |
| 27 | HA Sofia — Integration Health | config entries setup_error / not_loaded |
| 28 | HA Sofia — Automation Status | disabled / stale (>30d) automations |
| 29 | HA Sofia — System Resources | HA CPU / mem / disk |
| 30 | Hardware Exporters | snmp / idrac-redfish / proxmox / tuya pods + scrapes |
| 31 | cert-manager — Certificate Readiness | Certificate CRs with `Ready!=True` |
| 32 | cert-manager — Certificate Expiry (<14d) | notAfter within 14d |
| 33 | cert-manager — Failed CertificateRequests | `Ready=False, reason=Failed` |
| 34 | Backup Freshness — Per-DB Dumps | MySQL + PG dumps within 25h |
| 35 | Backup Freshness — Offsite Sync | Pushgateway `backup_last_success_timestamp` <27h |
| 36 | Backup Freshness — LVM PVC Snapshots | newest thin snapshot <25h (SSH PVE) |
| 37 | Monitoring — Prometheus + Alertmanager | `/-/ready` + AM pods Running |
| 38 | Monitoring — Vault Sealed Status | `vault status` reports `Sealed: false` |
| 39 | Monitoring — ClusterSecretStore Ready | `vault-kv` + `vault-database` Ready |
| 40 | External — Cloudflared + Authentik Replicas | deployments fully ready |
| 41 | External — ExternalAccessDivergence Alert | alert not firing |
| 42 | External — Traefik 5xx Rate (15m) | top-10 services emitting 5xx |

## Safe Auto-Fix Rules

`--fix` only performs operations that are genuinely reversible and
observable. Nothing here rewrites Terraform state or mutates the cluster
beyond "delete pod".

### Done automatically by `--fix`

- **Evicted / Failed pods** — delete them; the controller recreates.
  ```bash
  kubectl delete pods -A --field-selector=status.phase=Failed
  ```
- **CrashLoopBackOff pods with >10 restarts** — delete once to reset
  backoff timer.

### NEVER auto-fix (requires human investigation)

- NotReady nodes
- MemoryPressure / DiskPressure / PIDPressure
- ImagePullBackOff (usually a bad tag / registry credential)
- Deployment ready-replica mismatch
- Pending PVCs
- Node CPU/memory >90%
- CronJob failures
- DaemonSet desired != ready
- Vault sealed
- ClusterSecretStore not Ready
- cert-manager Certificate failures
- Backup freshness regressions
- Any external-reachability failure

## Deep-investigation recipes per failure mode

### Node Issues (checks 1, 3, 17, 25)

```bash
kubectl describe node <node>
kubectl top nodes
kubectl get events --field-selector involvedObject.name=<node> --sort-by='.lastTimestamp'
# SSH to the node
ssh root@10.0.20.10X
systemctl status kubelet
journalctl -u kubelet --since "30 minutes ago" | tail -100
df -h ; free -h
```

Node IPs: `10.0.20.100` master, `.101` node1 (GPU), `.102` node2,
`.103` node3, `.104` node4.

### Pod Issues (checks 4, 5, 11, 19)

```bash
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> --tail=200
kubectl logs -n <ns> <pod> --previous --tail=200
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -20
```

Common failure causes: OOMKilled (raise mem limit in Terraform), bad
config / missing env var, DB connection failure (check `dbaas` pods),
NFS mount failure (`showmount -e 192.168.1.127`), stale
imagePullSecret.

### Deployment / StatefulSet / DaemonSet (checks 6, 7, 16)

```bash
kubectl describe deployment -n <ns> <name>
kubectl rollout status deployment -n <ns> <name>
kubectl rollout history deployment -n <ns> <name>
kubectl get rs -n <ns> -l app=<app>
```

### PVC (check 8)

```bash
kubectl describe pvc -n <ns> <pvc>
kubectl get events -n <ns> --field-selector reason=FailedMount --sort-by='.lastTimestamp'
kubectl get pv | grep <pvc>
showmount -e 192.168.1.127
```

### cert-manager (checks 31, 32, 33)

```bash
kubectl get certificate -A
kubectl describe certificate -n <ns> <name>
kubectl get certificaterequest -A
kubectl describe certificaterequest -n <ns> <name>
kubectl logs -n cert-manager deploy/cert-manager | tail -50
```

Common causes: ACME HTTP-01 challenge blocked, ClusterIssuer missing
DNS provider secret, rate-limit from Let's Encrypt.

### Backups (checks 34, 35, 36)

```bash
# Per-DB dumps (inside the DB pod)
kubectl exec -n dbaas mysql-standalone-0 -- ls -lah /backup/per-db/
kubectl exec -n dbaas pg-cluster-0 -- ls -lah /backup/per-db/

# Pushgateway metrics
kubectl exec -n monitoring deploy/prometheus-server -- \
    wget -qO- http://prometheus-prometheus-pushgateway:9091/metrics | \
    grep backup_last_success_timestamp

# LVM snapshots on PVE host
ssh -o BatchMode=yes root@192.168.1.127 \
    'lvs -o lv_name,lv_time,lv_size --noheadings | grep snap'
```

If offsite sync is stale, the common cause is the
`offsite-sync-backup.service` systemd unit on the PVE host failing.
`ssh root@192.168.1.127 'systemctl status offsite-sync-backup'`.

### Monitoring stack (checks 37, 38, 39)

```bash
# Prometheus
kubectl exec -n monitoring deploy/prometheus-server -- wget -qO- http://localhost:9090/-/ready
kubectl logs -n monitoring deploy/prometheus-server --tail=100

# Alertmanager
kubectl get pods -n monitoring | grep alertmanager
kubectl logs -n monitoring -l app=prometheus-alertmanager --tail=100

# Vault
kubectl exec -n vault vault-0 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
# If sealed: check raft peers with `vault operator raft list-peers` and unseal.

# ClusterSecretStore
kubectl get clustersecretstore
kubectl describe clustersecretstore vault-kv vault-database
kubectl logs -n external-secrets deploy/external-secrets --tail=100
```

### External reachability (checks 40, 41, 42)

```bash
# Cloudflared
kubectl get pods -n cloudflared
kubectl logs -n cloudflared -l app=cloudflared --tail=100

# Authentik
kubectl get pods -n authentik -l app=authentik-server
kubectl logs -n authentik -l app=authentik-server --tail=100

# ExternalAccessDivergence alert
kubectl exec -n monitoring deploy/prometheus-server -- \
    wget -qO- 'http://localhost:9090/api/v1/alerts' | \
    python3 -m json.tool | grep -A 5 ExternalAccessDivergence

# Traefik 5xx — find the hot service
kubectl exec -n monitoring deploy/prometheus-server -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=topk(10,rate(traefik_service_requests_total{code=~%225..%22}%5B15m%5D))' \
    | python3 -m json.tool
```

### OOMKilled remediation

1. `kubectl describe pod -n <ns> <pod> | grep -A 5 Limits`
2. Edit `infra/modules/kubernetes/<service>/main.tf` and raise
   `resources.limits.memory`.
3. `cd /home/wizard/code/infra && scripts/tg apply` (Tier 1) or
   `terraform apply -target=module.<service>` as appropriate.

### ImagePullBackOff remediation

1. `kubectl describe pod -n <ns> <pod> | grep -A 5 Events`
2. Verify tag exists on the source registry.
3. Check pull-through cache at `10.0.20.10:{5000,5010,5020,5030}`.
4. Update the image tag in Terraform + re-apply.

### Persistent CrashLoopBackOff after auto-fix

1. `kubectl logs -n <ns> <pod> --previous --tail=200`
2. `kubectl describe pod -n <ns> <pod>` and check Last State:
   - `OOMKilled` → raise memory limit
   - Exit code 137 → OOM or probe killed
   - Exit code 143 → SIGTERM / graceful shutdown failed
3. Cross-check dbaas + NFS + secrets are healthy.

## Notes on the canonical / hardlink setup

The authoritative copy of this SKILL.md lives at
`/home/wizard/code/.claude/skills/cluster-health/SKILL.md`. A hardlink
at `/home/wizard/code/infra/.claude/skills/cluster-health/SKILL.md`
points to the same inode so infra-rooted sessions also discover the
skill.

To verify the hardlink is intact:

```bash
stat -c '%i %n' \
    /home/wizard/code/.claude/skills/cluster-health/SKILL.md \
    /home/wizard/code/infra/.claude/skills/cluster-health/SKILL.md
```

Both should print the same inode number. If they diverge (e.g. `git
checkout` replaced the file rather than updating it), re-link:

```bash
ln -f /home/wizard/code/.claude/skills/cluster-health/SKILL.md \
      /home/wizard/code/infra/.claude/skills/cluster-health/SKILL.md
```
