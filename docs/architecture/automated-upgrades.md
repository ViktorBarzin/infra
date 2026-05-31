# Automated Upgrades

This doc covers three independent automation paths:

1. **Service-level upgrades** — Container image bumps for OSS apps (DIUN → n8n → claude-agent → Terraform). Most of this doc.
2. **OS-level upgrades on K8s nodes** — `unattended-upgrades` + `kured` with sentinel-gate + Prometheus halt-on-alert. See "K8s Node OS Upgrades" section and the runbook at `docs/runbooks/k8s-node-auto-upgrades.md`.
3. **K8s component version upgrades** (kubeadm/kubelet/kubectl) — weekly detection CronJob → chain of phase Jobs (preflight → master → worker × 4 → postflight). See "K8s Version Upgrades" section and the runbook at `docs/runbooks/k8s-version-upgrade.md`.

## Overview

OSS services are automatically upgraded via a pipeline that detects new container image versions, analyzes changelogs for breaking changes, backs up databases, applies version bumps through Terraform, and verifies health post-upgrade with automatic rollback on failure.

## Architecture

```
DIUN (every 6h)
  │ detects new image tags
  │
  ▼
n8n Webhook (POST /webhook/<uuid>)
  │ filters: skip databases, custom images, infra, :latest
  │ rate limit: max 5 upgrades per 6h window
  │
  ▼
HTTP POST → claude-agent-service (K8s)
  │
  ▼
claude -p "upgrade agent prompt" (in-cluster)
  │
  ▼
Service Upgrade Agent
  ├── 1. Identify service + .tf files (grep stacks/)
  ├── 2. Resolve GitHub repo (config overrides + auto-detect)
  ├── 3. Fetch changelogs via GitHub API (authenticated, 5000 req/hr)
  ├── 4. Classify risk (SAFE / CAUTION / UNKNOWN)
  ├── 5. Slack notification — starting
  ├── 6. DB backup (if DB-backed service)
  ├── 7. Edit .tf files (version bump + config changes)
  ├── 8. Commit + push (Woodpecker CI applies)
  ├── 9. Wait for CI (poll Woodpecker API)
  ├── 10. Verify (pod ready + HTTP + Uptime Kuma)
  ├── 11a. SUCCESS → Slack report
  └── 11b. FAILURE → git revert + CI re-applies → Slack alert
```

## Components

### DIUN (Docker Image Update Notifier)
- **Stack**: `stacks/diun/`
- **Schedule**: Every 6 hours (`DIUN_WATCH_SCHEDULE=0 */6 * * *`)
- **Role**: Detection only — fires a webhook to n8n when a new image tag is found
- **Skip patterns**: Databases, `viktorbarzin/*`, `registry.viktorbarzin.me/*`, infrastructure images
- **Webhook**: `DIUN_NOTIF_WEBHOOK_ENDPOINT` from Vault `secret/diun` → `n8n_webhook_url`

### n8n Workflow ("DIUN Upgrade Agent")
- **Stack**: `stacks/n8n/`
- **Workflow backup**: `stacks/n8n/workflows/diun-upgrade.json`
- **Webhook path**: UUID-based (`/webhook/<uuid>`)
- **Filters**:
  - Only `status=update` (skip `new`, `unchanged`)
  - Skip databases, custom images, infra images, `:latest`
- **Rate limiting**: Max 5 upgrades per 6-hour window using `$getWorkflowStaticData('global')`
- **Action**: HTTP POST to `claude-agent-service.claude-agent.svc:8080/execute` with the upgrade agent prompt

### Upgrade Agent
- **Prompt**: `.claude/agents/service-upgrade.md`
- **Config**: `.claude/reference/upgrade-config.json`
- Contains:
  - 50+ Docker image → GitHub repo mappings
  - 22 Helm chart → GitHub repo mappings
  - 27 DB-backed service definitions with backup metadata
  - Skip patterns and breaking change keywords

## Risk Classification

| Risk | Criteria | Verification | Version Jump |
|------|----------|-------------|-------------|
| **SAFE** | Patch/minor bump, no breaking keywords in release notes | 2 minutes | Direct to target |
| **CAUTION** | Major bump, or breaking change keywords found, or in `version_jump_always_step` list | 10 minutes | Step through each version |
| **UNKNOWN** | Changelog unavailable | 2 minutes (SAFE defaults) | Direct to target |

**Breaking change keywords**: `breaking`, `BREAKING`, `migration required`, `schema change`, `database migration`, `manual intervention`, `action required`, `removed`, `deprecated`, `renamed`, `incompatible`

## Database Backup

DB-backed services trigger a pre-upgrade backup automatically:
- **Shared PostgreSQL**: `kubectl create job --from=cronjob/postgresql-backup -n dbaas`
- **Shared MySQL**: `kubectl create job --from=cronjob/mysql-backup -n dbaas`
- **Dedicated databases** (e.g., Immich): Trigger existing backup CronJob in the service's namespace

If the backup fails, the upgrade is **aborted**.

## Rollback

On verification failure:
1. `git revert --no-edit <upgrade-commit-sha>`
2. `git push` → Woodpecker CI re-applies the old version
3. Re-verify rollback succeeded
4. If rollback also fails → CRITICAL Slack alert for manual intervention

## Version Patterns

The agent handles all three version patterns in Terraform:

| Pattern | Example | Agent Action |
|---------|---------|-------------|
| Variable-based | `variable "immich_version" { default = "v2.7.4" }` | Edit the `default` value |
| Hardcoded | `image = "vaultwarden/server:1.35.4"` | Replace tag in image string |
| Helm chart | `version = "2026.2.2"` in `helm_release` | Bump chart version |

## Configuration

### Excluding images (handled by DIUN + n8n)
- Databases: `*postgres*`, `*mysql*`, `*redis*`, `*clickhouse*`, `*etcd*`
- Custom: `viktorbarzin/*`, `registry.viktorbarzin.me/*`, `ancamilea/*`, `mghee/*`
- Infrastructure: `registry.k8s.io/*`, `quay.io/tigera/*`, `nvcr.io/*`, `reg.kyverno.io/*`
- `:latest` tags

### Rate limiting
- Max 5 upgrades per 6-hour DIUN scan cycle
- Counter resets when the window expires
- Configurable in the n8n "Filter and Rate Limit" code node

### Services that always step through versions
- Authentik, Nextcloud, Immich (configured in `upgrade-config.json` → `version_jump_always_step`)

## Monitoring

- **Slack**: All upgrade events reported (start, success, failure, rollback)
- **Git**: Detailed commit messages with changelog summaries, risk level, backup status
- **DIUN Slack**: Independent Slack channel for raw version detection (separate from upgrade agent)

## Bulk Upgrades

To upgrade all outdated services at once, fire webhooks for each service:

```bash
WEBHOOK="https://n8n.viktorbarzin.me/webhook/<uuid>"
curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{"diun_entry_status":"update","diun_entry_image":"<image>","diun_entry_imagetag":"<new_tag>","diun_entry_provider":"kubernetes"}'
```

n8n processes all webhooks in parallel (one `claude -p` per webhook). Before bulk runs, increase the rate limit in the n8n Code node (`MAX_UPGRADES_PER_WINDOW`) and reset the counter:

```sql
-- Reset rate limiter
UPDATE workflow_entity SET "staticData" = '{}'::json WHERE name = 'DIUN Upgrade Agent';
```

### First Bulk Run (2026-04-16)

12 services upgraded in ~30 minutes, fully automated:

| Service | From | To | Notes |
|---------|------|----|-------|
| audiobookshelf | 2.32.1 | 2.33.1 | Security fixes (IDOR) |
| owntracks | 0.9.9 | 1.0.1 | Major version bump |
| open-webui | v0.7.2 | v0.8.12 | |
| immich | v2.7.4 | v2.7.5 | Patch, DB backup taken |
| coturn | 4.6.3-r1 | 4.10.0-r1 | Major version bump |
| shlink | 4.3.4 | 5.0.2 | Major, DB-backed |
| phpipam | v1.7.0 | v1.7.4 | Patch, DB-backed |
| onlyoffice | 8.2.3 | 9.3.1 | Major version bump |
| paperless-ngx | 2.16.4 | 2.20.14 | Agent also bumped memory 1Gi → 2Gi |
| linkwarden | v2.9.1 | v2.14.0 | 23 intermediate releases, 254M DB backup |
| synapse | v1.125.0 | v1.151.0 | Large jump, DB-backed |
| dawarich | 0.37.1 | 1.6.1 | Upgraded → verification failed → auto-rolled back → forward-fixed |

Key behaviors observed:
- **Auto-rollback works**: Dawarich upgrade failed verification, agent reverted, then re-applied with a forward fix
- **Resource awareness**: Paperless-ngx agent detected the new version needed more memory and bumped limits
- **DB backups**: All DB-backed services had pre-upgrade dumps taken automatically
- **Changelog analysis**: Linkwarden commit summarized 23 intermediate releases; vaultwarden (earlier test) identified 3 CVEs
- **Parallel execution**: 11 agents ran concurrently, handled git rebase conflicts automatically

## Secrets

| Secret | Vault Path | Purpose |
|--------|-----------|---------|
| n8n webhook URL | `secret/diun` → `n8n_webhook_url` | DIUN → n8n trigger |
| Agent API bearer token | `secret/claude-agent-service` → `api_bearer_token` | n8n → claude-agent-service `/execute` auth. Synced into both `claude-agent` ns (consumer) and `n8n` ns (caller) via ESO. n8n exposes it to the container as `CLAUDE_AGENT_API_TOKEN` env var. |
| Claude OAuth (primary) | `secret/claude-agent-service` → `claude_oauth_token` | Long-lived 1-year token from `claude setup-token`. Consumed by the CLI via `CLAUDE_CODE_OAUTH_TOKEN` env var (set on the container via `envFrom`). Preferred over the short-lived `.credentials.json` — CLI skips the refresh dance entirely. Rotate yearly; alert fires 30d out. |
| Claude OAuth (spares) | `secret/claude-agent-service-spare-{1,2}` → `claude_oauth_token` | Failover tokens. Minted alongside primary (verified Anthropic does NOT revoke earlier sessions on new mint). Swap into primary if revocation or compromise. |
| GitHub PAT | `secret/viktor` → `github_pat` | Changelog fetch (5000 req/hr) |
| Slack webhook | `secret/platform` → `alertmanager_slack_api_url` | Upgrade notifications |
| Woodpecker token | `secret/viktor` → `woodpecker_token` | CI pipeline polling |

## OAuth token lifecycle

The CLI supports two auth modes. We use the second — long-lived.

| Mode | How minted | TTL | Needs refresh? | When to use |
|------|-----------|-----|----------------|-------------|
| `claude login` → `.credentials.json` | Interactive browser OAuth | Access ~6h + refresh token | Yes — CLI auto-refreshes on startup if refresh token valid | Human dev machines |
| `claude setup-token` → opaque `sk-ant-oat01-*` | Interactive browser OAuth | **1 year** | No — expires hard | **Headless / service accounts (us)** |

When both are present on disk, `CLAUDE_CODE_OAUTH_TOKEN` env var wins.

**Harvesting headless**: `setup-token` uses Ink (React for terminals) and needs a real PTY with **≥300-column width**. At 80-col, Ink wraps and DROPS one character at the wrap boundary (107-char invalid instead of 108-char valid). Python wrapper pattern documented in memory; we harvested 2 spare tokens into Vault on 2026-04-18 using a temporary harvester pod.

**Monitoring**: CronJob `claude-oauth-expiry-monitor` (claude-agent ns, every 6h) pushes `claude_oauth_token_expiry_timestamp{path="..."}` to Pushgateway. Alerts: `ClaudeOAuthTokenExpiringSoon` (30d, warn), `ClaudeOAuthTokenCritical` (7d, crit), `ClaudeOAuthTokenMonitorStale` (48h no push, warn), `ClaudeOAuthTokenMonitorNeverRun` (metric absent, warn).

**Rotation**: on alert, harvest a new token, `vault kv patch secret/claude-agent-service claude_oauth_token=<new>`, update the `claude_oauth_token_mint_epochs` local in `stacks/claude-agent-service/main.tf`, `scripts/tg apply` → alert clears on next cron tick.

## n8n workflow gotchas

The `DIUN Upgrade Agent` workflow is imported once into n8n's PG DB — it is **not** Terraform-managed. The JSON at `stacks/n8n/workflows/diun-upgrade.json` is a backup; the live state lives in `workflow_entity.nodes`. Drift between the two is possible.

- **HTTP Request node header expressions must use template-literal form**: `=Bearer {{ $env.CLAUDE_AGENT_API_TOKEN }}` works; `='Bearer ' + $env.CLAUDE_AGENT_API_TOKEN` does NOT evaluate and sends an empty/bogus header → 401 from claude-agent-service.
- **`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`** must be set on the n8n deployment for expressions to read `$env.*` at all.
- **Troubleshooting 401**: the workflow will show `success` status on the webhook node but error on `Run Upgrade Agent`. Inspect in n8n UI → Executions, or query `execution_entity` + `execution_data` directly. Claude-agent-service logs will also show `POST /execute HTTP/1.1 401 Unauthorized`.
- **Patching the live workflow** (one-off, since it's not in TF): `UPDATE workflow_entity SET nodes = REPLACE(nodes::text, OLD, NEW)::json WHERE name = 'DIUN Upgrade Agent';`

## K8s Node OS Upgrades

Independent of the service-upgrade pipeline above. Drives apt package updates + reboots on the 5 K8s VMs (master + 4 workers).

### Stack
- **In-guest**: `unattended-upgrades` runs apt upgrades within Allowed-Origins (`-security`, `-updates`, ESM). Package-Blacklist excludes runtime components (`containerd`, `containerd.io`, `runc`, `cri-tools`, `kubernetes-cni`, `calico-*`, `cni-plugins-*`, `docker-ce`). `apt-mark hold` on `kubelet`, `kubeadm`, `kubectl` (and runtime pkgs as belt-and-braces). `Automatic-Reboot=false` — kured handles reboots.
- **Reboot driver**: `kured` (chart `kured-5.11.0`, app `1.21.0`). Window 02:00-06:00 Europe/London every day of the week (Mon-Fri-only restriction dropped 2026-05-16 — see PM), period=1h, concurrency=1, reboot-delay=30s, drainTimeout=30m.
- **Reboot gate (sentinel)**: `kured-sentinel-gate` DaemonSet creates `/var/run/gated-reboot-required` only when (a) host needs reboot, (b) all nodes Ready, (c) all calico-node pods Running, (d) **no node has transitioned Ready in the last 24h** (24h soak window). The gate runs as an immortal `bash` loop that forks `kubectl` each cycle; the pod whose host has a pending reboot runs the full kubectl-heavy path indefinitely and slowly leaks. Mitigated 2026-05-31 (limit 64Mi→256Mi + `MAX_ITER=72` self-exit ≈6h so kubelet restarts it fresh) — see PM `2026-05-31-kured-sentinel-gate-oom.md`.
- **Reboot gate (Prometheus)**: kured `--prometheus-url` polls `prometheus-server.monitoring.svc:80` before each drain. ANY firing alert blocks unless it matches the ignore-regex `^(Watchdog|RebootRequired|KuredNodeWasNotDrained|InfoInhibitor)$`.
- **Health alert library**: 10 alerts in the `Upgrade Gates` group (`prometheus_chart_values.tpl`): `KubeAPIServerDown`, `KubeStateMetricsDown`, `PrometheusRuleEvaluationFailing`, `PVCStuckPending`, `RecentNodeReboot` (the explicit 24h soak signal), `MysqlStandaloneDown`, `ClusterPodReadyRatioDropped`, `NodeMemoryPressure`, `NodeDiskPressure`, `KubeQuotaAlmostFull`. Plus the existing 200+ alerts in the cluster-wide library (anything firing blocks kured).
- **Notifications**: kured `notifyUrl` posts drain-start/drain-finish to Slack via Vault `secret/kured.slack_kured_webhook`. Alertmanager separately routes critical alerts to `#alerts`.

### Source of truth
| Concern | Location |
|---|---|
| Package config (uu, holds, blacklist) | `modules/create-template-vm/cloud_init.yaml` (within `is_k8s_template`) |
| kured Helm release + sentinel-gate DS | `stacks/kured/main.tf` |
| Upgrade Gates alerts | `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` |

### Day-2 changes
Cloud-init only runs on first boot. Existing nodes are brought into compliance with a one-shot SSH push — see the runbook section "Restore / re-apply unattended-upgrades config to existing nodes" in `docs/runbooks/k8s-node-auto-upgrades.md`.

### Why this design
The 26h cluster outage on 2026-03-16 was triggered by an unattended-upgrades kernel push that corrupted containerd's overlayfs snapshotter cluster-wide. The remediations:
- 24h soak (sentinel-gate Check 4) gives a full day of observation between consecutive node reboots — broken updates show up as Prometheus alerts before any other node restarts.
- Prometheus halt-on-alert turns ANY firing alert into a hard block — including the 6 Node Runtime Health alerts and the 10 Upgrade Gates alerts that explicitly model "the cluster is in a bad state."
- Package-Blacklist on runtime components prevents the exact failure mode (containerd/runc auto-bumps).
- `Automatic-Reboot=false` keeps reboot policy in kured (window, ordering, gating), not in apt.

### Operational reference
See `docs/runbooks/k8s-node-auto-upgrades.md` for: verifying health, halting rollout, restoring config to a re-imaged node, rolling back a bad upgrade, and the past-incident timeline.

## K8s Version Upgrades

Independent of the OS-upgrade and service-upgrade pipelines. Drives
kubeadm/kubelet/kubectl bumps (patch + minor) on all 5 K8s VMs.

### Architecture

```
k8s-version-check CronJob   (Sun 12:00 UTC, k8s-upgrade ns)
  │ probe apt-cache madison kubeadm (master) → latest available patch
  │ probe HEAD https://pkgs.k8s.io/.../v<NEXT_MINOR>/deb/Release → next minor?
  │ push k8s_upgrade_available metric to Pushgateway
  │
  ▼ if a target is detected
envsubst on /template/job-template.yaml | kubectl apply -f -
  │ spawns Job 0 = k8s-upgrade-preflight-<target_version>
  ▼

Job 0 — preflight       (pinned: k8s-node1)
Job 1 — master upgrade  (pinned: k8s-node1)        drains k8s-master
Job 2 — worker          (pinned: k8s-node1)        drains k8s-node4
Job 3 — worker          (pinned: k8s-node1)        drains k8s-node3
Job 4 — worker          (pinned: k8s-node1)        drains k8s-node2
Job 5 — worker          (pinned: k8s-master)       drains k8s-node1  ← control-plane toleration
Job 6 — postflight      (no pinning)
```

Each Job runs `scripts/upgrade-step.sh`, which dispatches on `$PHASE` and ends
by spawning the next Job (`envsubst < /template/job-template.yaml | kubectl
apply -f -`). Job names are deterministic (`k8s-upgrade-<phase>-<target_version>[-<node>]`)
so `apply` reconciles to a single Job per run — re-running a failed Job
won't duplicate downstream Jobs.

### Self-preemption history (the reason for the Job-chain rewrite)

The v1 design ran the whole upgrade inside the `claude-agent-service`
Deployment (1 replica, no nodeSelector). On 2026-05-11 the agent's pod was
scheduled to k8s-node4. When the agent ran `kubectl drain k8s-node4` during
Stage 6, it evicted itself — the bash process died after the drain but
before the SSH-pipe to install kubeadm on node4. The cluster ended up
half-upgraded (master at v1.34.7, workers at v1.34.2). The rewrite to a
chain of `nodeSelector`-pinned Jobs eliminates this failure mode because
each Job's pod and its drain target are always different nodes.

### Components

- **Detection CronJob + ConfigMaps + RBAC**: `infra/stacks/k8s-version-upgrade/main.tf`.
  - Image is the claude-agent-service image (kubectl + ssh-client + curl + jq + envsubst).
  - One unified ServiceAccount `k8s-upgrade-job` serves both the detection CronJob and every chain Job.
- **Phase body**: `infra/stacks/k8s-version-upgrade/scripts/upgrade-step.sh`.
  Dispatches on `$PHASE` (preflight | master | worker | postflight). Computes
  `NEXT_PHASE` / `NEXT_TARGET_NODE` / `NEXT_RUN_ON` and spawns the next Job.
  Includes a `predrain_unstick` helper that pre-deletes pods on the target
  node whose PDB has `disruptionsAllowed=0` (otherwise drain loops forever on
  single-replica deployments like Anubis instances).
- **Job template**: `infra/stacks/k8s-version-upgrade/job-template.yaml`.
  envsubst-rendered at runtime. Mounts a `creds` Secret, a `scripts`
  ConfigMap, and a `template` ConfigMap into each Job pod.
- **Per-node script**: `infra/scripts/update_k8s.sh`. Caller passes
  `--role master|worker --release X.Y.Z`. Piped via SSH into each node by
  upgrade-step.sh.
- **Three Upgrade Gates alerts**:
  - `K8sVersionSkew` — kubelet/apiserver `gitVersion` count >1 for 30m. Catches a half-done rollout.
  - `EtcdPreUpgradeSnapshotMissing` — `k8s_upgrade_in_flight==1 && k8s_upgrade_snapshot_taken==0` for 10m. Catches preflight failing silently.
  - `K8sUpgradeStalled` — `k8s_upgrade_in_flight==1 && time()-k8s_upgrade_started_timestamp > 5400` for 5m. Catches a chain Job dying without spawning its successor.
- **Pushgateway metrics**:
  - `k8s_upgrade_in_flight` (set in preflight, cleared in postflight)
  - `k8s_upgrade_snapshot_taken` (set after etcd snapshot Job completes with ≥1 KiB)
  - `k8s_upgrade_started_timestamp` (set in preflight; used by `K8sUpgradeStalled`)
  - `k8s_upgrade_available{kind,running,target}` (pushed by detection CronJob)
  - `k8s_version_check_last_run_timestamp` (staleness watchdog)

### Source of truth

| Concern | Location |
|---|---|
| Stack (CronJob + ConfigMaps + SA/RBAC + ExternalSecret) | `stacks/k8s-version-upgrade/main.tf` |
| Phase orchestration | `stacks/k8s-version-upgrade/scripts/upgrade-step.sh` |
| Job template | `stacks/k8s-version-upgrade/job-template.yaml` |
| Per-node upgrade script | `scripts/update_k8s.sh` |
| Alerts | `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (group "Upgrade Gates") |
| Vault secrets | `secret/k8s-upgrade/{ssh_key, ssh_key_pub, slack_webhook}` |
| Deprecated agent prompt (reference) | `.claude/agents/k8s-version-upgrade.deprecated.md` |

### Why this design

The cluster has a single control plane (no HA). A failed `kubeadm upgrade apply` is an outage. Mitigations:

- **Mandatory etcd snapshot before every run** (even patch). Recovery point if master breaks.
- **Halt-on-alert before every drain**. Reuses the same Prometheus ignore-list regex kured uses — any unrelated cluster-health alert blocks. Three gate alerts catch upgrade-specific half-states (version skew, missing snapshot, stalled chain).
- **Job pinning eliminates self-preemption**. Each Job's pod runs on a node that is NOT its drain target. k8s-node1 hosts every Job except the one that drains it (which runs on k8s-master with a control-plane toleration).
- **Sequential workers with 10-min inter-node soak**. Same risk-bounding as the 24h OS-reboot soak, but tightened because kubelet failures surface within minutes — not hours.
- **Master upgrade goes first, workers last**. If master breaks, the cluster is already degraded so further worker upgrades would just delay recovery. By upgrading master first, we either succeed (workers can roll afterward) or fail loud (operator triages before any worker is touched).
- **No auto-rollback**. kubeadm doesn't support clean downgrade; the snapshot + manual apt rollback in the runbook is the recovery path.
- **PDB-blocked pods don't stall the chain**. `predrain_unstick` deletes PDB=0 pods on the target node directly (bypassing the eviction API), so the parent Deployment recreates them elsewhere. This was the workaround applied manually during the 2026-05-11 recovery for Anubis single-replica instances.

### Secrets

| Secret | Vault Path | Purpose |
|--------|-----------|---------|
| SSH private key | `secret/k8s-upgrade.ssh_key` | Jobs SSH `wizard@<node>` |
| SSH public key | `secret/k8s-upgrade.ssh_key_pub` | Deployed to nodes' `~/.ssh/authorized_keys` |
| Slack webhook | `secret/k8s-upgrade.slack_webhook` | Pipeline notifications (separate channel from kured) |

The previous `api_bearer_token` entry is gone — the chain does not POST to `claude-agent-service`.

### Operational reference

See `docs/runbooks/k8s-version-upgrade.md` for: verifying health, manually triggering detection, killing a stuck Job, skipping a phase, rollback paths (master / worker / mid-flight abort), and SSH key rotation.
