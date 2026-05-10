# Automated Upgrades

This doc covers two independent automation paths:

1. **Service-level upgrades** — Container image bumps for OSS apps (DIUN → n8n → claude-agent → Terraform). Most of this doc.
2. **OS-level upgrades on K8s nodes** — `unattended-upgrades` + `kured` with sentinel-gate + Prometheus halt-on-alert. See "K8s Node OS Upgrades" section near the end and the runbook at `docs/runbooks/k8s-node-auto-upgrades.md`.

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
- **Reboot driver**: `kured` (chart `kured-5.11.0`, app `1.21.0`). Window Mon-Fri 02:00-06:00 Europe/London, period=1h, concurrency=1, reboot-delay=30s.
- **Reboot gate (sentinel)**: `kured-sentinel-gate` DaemonSet creates `/var/run/gated-reboot-required` only when (a) host needs reboot, (b) all nodes Ready, (c) all calico-node pods Running, (d) **no node has transitioned Ready in the last 24h** (24h soak window).
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
