# Automated Service Upgrades

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
| GitHub PAT | `secret/viktor` → `github_pat` | Changelog fetch (5000 req/hr) |
| Slack webhook | `secret/platform` → `alertmanager_slack_api_url` | Upgrade notifications |
| Woodpecker token | `secret/viktor` → `woodpecker_token` | CI pipeline polling |
| Dev VM SSH key | n8n credentials store → `devvm-ssh` | n8n → dev VM SSH |
