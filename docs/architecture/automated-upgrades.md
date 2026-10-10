# Automated Upgrades

This doc covers three independent automation paths, plus a short section on Keel, which applied in-cluster image updates until it was parked on 2026-10-10 (see "Keel").

1. **Service-level upgrades** — Container image bumps for OSS apps (DIUN → n8n → claude-agent → Terraform). Most of this doc.
2. **OS-level upgrades on K8s nodes** — `unattended-upgrades` + `kured` with sentinel-gate + Prometheus halt-on-alert. See "K8s Node OS Upgrades" section and the runbook at `docs/runbooks/k8s-node-auto-upgrades.md`.
3. **K8s component version upgrades** (kubeadm/kubelet/kubectl) — daily detection CronJob → chain of phase Jobs (preflight → master → one worker Job per worker, enumerated live → postflight). See "K8s Version Upgrades" section and the runbook at `docs/runbooks/k8s-version-upgrade.md`.

Since 2026-10-10 the Trivy Operator reports which running images have fixable Critical/High CVEs (`docs/architecture/trivy.md`). It does not trigger upgrades itself; the software-currency design (`docs/plans/2026-10-09-software-currency-design.md`) has Renovate pick up fixed versions, and rewrites this doc around Renovate when Phase 3 lands.

The Renovate stack itself (`stacks/renovate`, runbook `docs/runbooks/renovate.md`) exists since 2026-10-10 and is suspended until the rails and the Keel cutover are in place. Its repo config is `renovate.json5` at the repo root.

Also since 2026-10-10, every chart, database and GPU stack has a `stacks/<stack>/verify.sh`, run as a Kubernetes Job by `scripts/verify/run` (`docs/runbooks/verify-jobs.md`). The Woodpecker rails (`scripts/renovate-rails`, runbook `docs/runbooks/renovate.md` "Rails") run these checks after every Renovate apply and revert a bump that fails them.

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

Since 2026-10-10 every active `helm_release` in `stacks/` sets an explicit chart `version`, so Renovate can own each one (`docs/plans/2026-10-09-software-currency-design.md`, "Ownership of versions"). The last unpinned release, `homepage`, was pinned to its live chart 2.1.0. Each release also sets `atomic = true` and `cleanup_on_fail = true`, with two documented exceptions:

- `prometheus` (`stacks/monitoring/modules/monitoring/prometheus.tf`) sets `cleanup_on_fail` only. It runs with `wait = false`, and Helm turns waiting back on whenever `atomic` is set.
- `vault` (`stacks/vault/main.tf`) keeps `atomic = false`, because HA pods start sealed and fail readiness until they are unsealed.

Any change to a `helm_release`, even a flag such as `cleanup_on_fail`, runs a full `helm upgrade` that re-renders the chart. Where Keel has moved a workload's image past the tag in Terraform, that upgrade puts the Terraform tag back and rolls the pods. On 2026-10-10 this rolled `homepage` (same image) and moved `woodpecker` from Keel's v3.14.1 back to v3.14.0. Because CI runs inside Woodpecker, the roll stopped the pipeline that was applying it and left the release in `pending-upgrade`; the fix was to delete the dead revision Secret, set the tag to v3.14.1, and apply `stacks/woodpecker` from a workstation. Apply `stacks/woodpecker` changes that roll its pods from a workstation, then push, so the CI apply finds nothing to change. Before changing a `helm_release`, compare its live images with the Terraform tags.

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
- **DIUN Slack**: REMOVED 2026-07-02 (per-tag @channel pings in #image-updates; human cadence is the weekly upgrade report). The n8n webhook feed to the upgrade agent is unchanged.

## Bulk Upgrades

To upgrade all outdated services at once, fire webhooks for each service:

```bash
WEBHOOK="https://n8n.viktorbarzin.me/webhook/<uuid>"
curl -s -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d '{"diun_entry_status":"update","diun_entry_image":"<image>","diun_entry_imagetag":"<new_tag>","diun_entry_provider":"kubernetes"}'
```

n8n processes all webhooks in parallel (one `claude -p` per webhook); `claude-agent-service` runs them concurrently via a bounded pool (`MAX_CONCURRENCY`, default 10, excess queued) — it no longer single-flight-locks. Before bulk runs, increase the rate limit in the n8n Code node (`MAX_UPGRADES_PER_WINDOW`) and reset the counter:

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

## Keel

Status since 2026-10-10: Keel is parked (`local.keel_enabled = false` in `stacks/keel/main.tf` uninstalls the helm release, so it runs 0 pods; chart 1.2.3 hard-codes `replicas: 1`, so a `replicaCount` value has no effect) and the Kyverno `inject-keel-annotations` policy, with its background-controller ClusterRole, is deleted. This is batch B00 of the Keel to Renovate cutover (`docs/plans/2026-10-09-software-currency-design.md`, Phase 3). Keel stops first because a running Keel writes back its cached copy of a workload and would revert the edits of the later batches. Nothing rolls app images on its own until Renovate takes over each stack. The `keel.sh/*` annotations already on workloads stay in place and are inert; later batches remove the ones Terraform declares, and the stack is removed after the last batch. Re-enabling Keel means setting `keel_enabled = true` and restoring `keel-annotations.tf` from git history.

Cutover progress, one batch per landing (batches and classes: the Keel inventory of 2026-10-10). Each migrated stack pins every third-party image to the exact string that was running, so the apply changes no pod template; drops the `KEEL_IGNORE_IMAGE` image ignores and the `keel.sh/policy|trigger|pollSchedule|match-tag` annotation ignores; and removes the `keel.sh/enrolled` namespace label. Two kinds of ignore stay, under neutral markers: `keel.sh/update-time` on the pod template (`# LEGACY_TEMPLATE_ANNOTATIONS`), because stripping it restarts the pod, and first-party images that their own CI deploys (`# CI_SETS_IMAGE`) or that are built by hand and pushed as `:latest` (`# FIRST_PARTY_IMAGE`; Renovate skips first-party images). Stacks that could not move cleanly are listed with the reason in the batch commit and stay on their previous lines.

| Batch | Stacks | Date |
|---|---|---|
| B01 | ac, actualbudget, affine, agentmd, android-emulator, blog, broker-sync, browser-bridge, city-guesser, claude-breakglass, claude-memory, coturn, cyberchef (anisette stays: digest-only pin) | 2026-10-10 |
| B02 | dashy, dawarich, drone-logbook, ebook2audiobook, ebooks, echo, f1-stream, fire-planner, freedify, freshrss, goldmane-edge-aggregator, grampsweb, hackmd (excalidraw stays: Keel was its only deploy path) | 2026-10-10 |
| B03 | health, insta2spotify, instagram-poster, job-hunter, jsoncrack, kms, learn, lesson-harvester, linkwarden, matrix, navidrome (interview-prep-app, k8s-portal and learning stay: Keel was their only deploy path) | 2026-10-10 |
| B04 | netbox, networking-toolbox, nextcloud-todos, novelapp, offline-reader, openclaw, osm_routing, owntracks, paperless-ai, paperless-mcp, payslip-ingest, phpipam, plotting-book (pages-publish stays: Keel was its only deploy path; in openclaw, modelrelay and task-webhook keep their image ignore until the floating-tag batch; plotting-book's image stays with Anca's CI as `# CI_SETS_IMAGE`) | 2026-10-10 |
| B05 | poison-fountain, priority-pass, privatebin, real-estate-crawler, recruiter-responder, resume, rustdesk, rybbit, send, speedtest, stirling-pdf, t3-afk, t3code (repowise stays: Keel was its only deploy path; t3-afk's floating `node:24` and `busybox:1.37` pins wait for the floating-tag batch; rustdesk needed no edit) | 2026-10-10 |
| B06 | tandoor, tasks, terminal, trek, tts, tuya-bridge, url, vaultwarden, vpn-portal, wealthfolio, webhook_handler, whisper (trading-bot stays: Keel was its only deploy path; tasks, tuya-bridge, vpn-portal and webhook_handler keep their image as `# CI_SETS_IMAGE`; the tts image is Terraform-owned through `var.image_tag`) | 2026-10-10 |
| B07 | beads-server, chrome-service, claude-agent-service, homepage, isponsorblocktv, meshcentral, ntfy, paperless-ngx, servarr, stremio, tripit, ytdlp, plus the floating pins left over in openclaw (B04) and t3-afk (B05). This is the floating-tag batch: a floating tag is pinned to the version tag that has the running digest (`v2.23` -> `v2.23.0`, `canary` -> `canary-0.2.47`, `nightly` -> `nightly-2025-03-18`), or to `tag@digest` where the tag was re-pushed and no version tag has the running digest any more (`busybox:1.37@sha256:9532d8...`, `library/nginx:alpine@sha256:62ff20...`). The new string is a pod-template change, so the 12 workloads running these pins restart onto the same image digest; openclaw, task-webhook and t3-afk run 0 replicas. claude-agent-service's image ignores now point at the init containers its CI sets (`init_container[2]` and `[3]`, previously `[0]` and `[1]`, the busybox ones). renovate.json5 gained regex versioning for listenarr (`canary-X.Y.Z`) and youtubedl-material (`nightly-YYYY-MM-DD`) | 2026-10-10 |
| B08 | changedetection, partly. The Deployment runs its two images in the wrong containers (container `sockpuppetbrowser` runs `ghcr.io/dgtlmoon/changedetection.io:0.55.8`, container `changedetection` runs `dgtlmoon/sockpuppetbrowser:0.0.3`, since a Keel update on 2026-08-26), so both image ignores stay, marked `# IMAGE_SWAP_DEFERRED`, and Renovate does not track either image yet. The `keel.sh/policy|trigger|pollSchedule|match-tag` annotation ignores and the `keel.sh/enrolled` namespace label are removed as in the other batches. Putting each image back in its own container restarts the pod and is left for a supervised session | 2026-10-10 |
| B09 | bastion, cloudflared, crowdsec (crowdsec-web only), descheduler, external-secrets, forgejo, frigate, headscale (headscale container), immich, k8s-dashboard, k8s-version-upgrade. Pins moved to the live strings: cloudflared bare -> `2026.7.3`, headscale `0.29.3` -> `v0.29.4`, nginx-unprivileged `1.27-alpine` -> `1.27.5-alpine`, and `var.immich_version` `v3.3.0` -> `v3.3.1` with a `# renovate:` annotation on immich-server (one value drives immich-worker, immich-api, immich-machine-learning `-cuda` and the thumbnail-reconcile CronJob). Forgejo is Terraform-owned now and Renovate holds it. No pin change restarts a pod in this batch, so four images keep their ignore: the crowdsec firewall-bouncer `debian:bookworm-slim`, immich-frame `immich_v3` and immich-postgresql (`# FLOATING_TAG_DEFERRED`: a version or `tag@digest` pin changes the pod template), and headscale-ui (`# DIGEST_PIN_DEFERRED`). crowdsec-web is `# FIRST_PARTY_IMAGE`. calico and cnpg needed no edit; their chart-managed workloads and those of crowdsec, external-secrets and k8s-dashboard stay with their charts | 2026-10-10 |
| B10 | kured, llama-cpp, local-path, mailserver, metallb, metrics-server, nfs-csi, nodelocal-dns, nvidia, proxmox-csi, proxy, pvc-autoresizer. Pins moved to the live strings: local-path-provisioner `v0.0.31` -> `v0.0.37`, docker-mailserver `docker.io/...:15.0.0` -> `mailserver/docker-mailserver:15.0.2`, roundcubemail `1.6.13-apache` -> `1.6.19-apache`, and the three python pins (gpu-vram-watchdog, gpu-pod-exporter, proxy-broker) from `python:3.1x-*` to `library/python:3.12.15-alpine`, `3.11.16-slim` and `3.12.15-slim`. The explicit `keel.sh/policy = "never"` annotation on the proxy-gw-1 egress gateway is removed, as is the shadowed `image` default in the nodelocal-dns module. metallb, metrics-server, nfs-csi, proxmox-csi and pvc-autoresizer only lost the namespace label; their images stay with their charts. kured-sentinel-gate keeps its image ignore as `# FLOATING_TAG_DEFERRED` (`bitnami/kubectl:latest` has no version tag with the running digest, and a `tag@digest` pin restarts its 6 pods). llama-swap and gluetun stay on digest-only pins that Renovate cannot bump. nextcloud stays unchanged for its supervised session (Renovate holds it, and its image comes from a live-tag lookup) | 2026-10-10 |
| B11 | redis, reloader, reverse-proxy, sablier, sealed-secrets, shadowsocks, tor-proxy, uptime-kuma, wireguard, woodpecker, xray. Pins moved to the live strings: xray bare -> `teddysun/xray:26.7.28` and prometheus-wireguard-exporter bare -> `3.6.6`; redis, sablier, shadowsocks, torrserver and uptime-kuma were already pinned to the live string. The explicit `keel.sh/policy = "never"` annotations on redis-v2 and uptime-kuma are removed; both now carry exact version pins, which is what guards against the downgrades that motivated the opt-outs. reloader, sealed-secrets and woodpecker only lost the namespace label; their images stay with their charts (woodpecker values already pin the live `v3.14.1`, and Renovate holds Woodpecker). trivy-operator needed no edit. Three images keep their ignore as `# FLOATING_TAG_DEFERRED`, because a pin restarts pods and this batch allows none: lean-proxy `openresty/openresty:alpine` (its 2 pods run different digests), tor-proxy `dperson/torproxy:latest` and the wireguard and wg-peer-sync containers on `sclevine/wg:latest` (no version tag has the running digest). renovate.json5 gained regex versioning for TorrServer (`MatriX.N[.M]`) | 2026-10-10 |

While it ran, Keel (`stacks/keel/`) polled the registry of each enrolled workload hourly and rolled it when a newer tag or digest matched the workload's `keel.sh/policy`. Enrollment and default annotations came from the Kyverno `inject-keel-annotations` policy (formerly `stacks/kyverno/modules/kyverno/keel-annotations.tf`). Design and history: `docs/plans/2026-05-16-auto-upgrade-apps-design.md`.

### Patched image (`keel.sh/pollTagsAfterCurrent`)

Since 2026-10-08 the cluster runs Keel 0.22.4 plus one patch, built from `github.com/ViktorBarzin/keel` (branch `homelab`, workflow `homelab-image.yml`) and pinned by digest in `stacks/keel/main.tf`.

- **Why**: stock Keel lists every tag of a repository on each poll, 100 per page. `ghcr.io/immich-app/immich-machine-learning` has more than 150,000 tags, and ghcr returned HTTP 429 around page 1,537 on every hourly poll from 2026-08 to 2026-10, so the ML deployment was never updated by Keel in that period and drifted behind immich-api.
- **What it adds**: the annotation `keel.sh/pollTagsAfterCurrent: "true"`. Keel then lists only the tags pushed after the running tag, using the registry's `last` cursor. ghcr lists tags in push order, so this is a few pages instead of the whole list.
- **Safety net**: the distribution spec lists tags lexically (Docker Hub, quay), where a cursor would skip `v3.10.0` when running `v3.9.x`. The patch uses the cursor result only when the registry's response shows push order, and otherwise lists every tag as stock Keel does.
- **Scope**: it applies only when every workload polling the same image opts in. It was set on immich-api, immich-worker and immich-machine-learning until B09 removed the annotation (2026-10-10); Renovate now takes the Immich version from the immich-server tags, a lookup of about 260 tags. Other repositories with large tag lists (frigate, rybbit, openclaw, the lscr images) poll successfully today and are left on the full listing.
- **Known limitation**: a newer version pushed *before* the running tag (for example, while running a backport release) is not seen.
- **When to use it**: a workload whose image repository has a very large tag list on a push-ordered registry (ghcr), and whose Keel poll fails with 429 or times out.
- **Release watch**: DIUN watches `ghcr.io/keel-hq/keel` for the newest semver tag and posts the first new one to Slack through a script notifier that ignores every other image (`stacks/diun/main.tf`, `kubernetes_config_map.keel_release_watch`). PR keel-hq/keel#943 merged on 2026-10-08; the message asks you to confirm the release contains it. Remove the watch after the exit below.
- **Exit**: upstream issue keel-hq/keel#942, PR keel-hq/keel#943. When a Keel release contains the patch, remove the `image` override in `stacks/keel/main.tf`, bump the chart, and archive the fork's `homelab` branch.

## K8s Node OS Upgrades

Independent of the service-upgrade pipeline above. Drives apt package updates + reboots on the 5 K8s VMs (master + 4 workers).

### Stack
- **In-guest**: `unattended-upgrades` runs apt upgrades within Allowed-Origins (`-security`, `-updates`, ESM). Package-Blacklist excludes runtime components (`containerd`, `containerd.io`, `runc`, `cri-tools`, `kubernetes-cni`, `calico-*`, `cni-plugins-*`, `docker-ce`). `apt-mark hold` on `kubelet`, `kubeadm`, `kubectl` (and runtime pkgs as belt-and-braces). `Automatic-Reboot=false` — kured handles reboots.
- **Reboot driver**: `kured` (chart `kured-6.1.0`, app `1.23.0`). Window 02:00-06:00 Europe/London every day of the week (Mon-Fri-only restriction dropped 2026-05-16 — see PM), period=1h, concurrency=1, reboot-delay=30s, drainTimeout=30m.
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

  **Replaced by an opt-in allowlist on 2026-09-19 (bead `code-rl8j`, now closed).** `HALT_IGNORE` is gone. `UPGRADE_GATE_ALERTS` in `upgrade-step.sh` names the 32 alertnames that mean "the cluster is unfit to be upgraded right now", and the gate blocks only on those, intersected with `severity: critical`.

  The mismatch it fixes: `severity: critical` in this cluster means "wake a human", while the gate read it as "the cluster is unfit to upgrade", and those are different sets. `BankSyncConsentExpired`, an expired Amex GoCardless consent only a human at the bank can clear, was the sole firing critical cluster-wide and held 1.35.8 for 2 days 20 hours. A denylist could never win that argument, since it grows by one entry per unrelated application alert forever.

  All 120 critical rules were reviewed (114 in `prometheus_chart_values.tpl`, 6 in `loki.tf`) against one test: an upgrade drains and reboots one node at a time, so it must not start when the cluster cannot absorb losing a node, when pods cannot move, when the grid or network is already degraded, when the monitoring that would catch a bad upgrade is blind, or when a platform incident is already under way. 32 qualified.

  **The fail-open inversion this doc warned about is handled two ways.** The allowlist *is* the hardcoded floor of always-blocking alertnames that the earlier note asked for, so there is no second list to keep in step. And if `UPGRADE_GATE_ALERTS` is ever empty or unset, `halt_on_alert_query` falls back to blocking on every firing critical, so a mistake fails closed rather than draining nodes during an outage.

  Keeping the list in the consumer rather than as an `upgrade_gate: "true"` label on 32 rules is deliberate: one reviewable place, and no risk of an edit in the monitoring stack silently changing upgrade behaviour.

  **The pipeline's own alerts are absent by design.** `K8sUpgradeStalled` and `EtcdPreUpgradeSnapshotMissing` are driven by this pipeline's own Pushgateway gauges, and preflight's gate runs before `in_flight` is refreshed, so counting them would let a stale gauge abort every preflight before it could clear anything (RC3, 2026-07-25). An allowlist expresses that by omission.

  Still true and still unused: `halt_on_alert_query` reads Prometheus `/api/v1/alerts` directly, so Alertmanager **silences do not affect whether the chain blocks**. Silencing a gate alert will not let an upgrade proceed. Honouring silences was considered as a cheaper alternative and rejected, because a silence is a notification preference that can be set for reasons unrelated to whether a reboot is safe.
- Package-Blacklist on runtime components prevents the exact failure mode (containerd/runc auto-bumps).
- `Automatic-Reboot=false` keeps reboot policy in kured (window, ordering, gating), not in apt.

### Operational reference
See `docs/runbooks/k8s-node-auto-upgrades.md` for: verifying health, halting rollout, restoring config to a re-imaged node, rolling back a bad upgrade, and the past-incident timeline.

## K8s Version Upgrades

Independent of the OS-upgrade and service-upgrade pipelines. Drives
kubeadm/kubelet/kubectl bumps (patch + minor) on all 5 K8s VMs.

### Architecture

```
k8s-version-check CronJob   (23:00 UTC nightly, k8s-upgrade ns)
  │ probe apt-cache madison kubeadm (master) → latest available patch
  │ probe HEAD https://pkgs.k8s.io/.../v<NEXT_MINOR>/deb/Release → next minor?
  │ push k8s_upgrade_available metric to Pushgateway
  │
  ▼ if a target is detected
envsubst on /template/job-template.yaml | kubectl apply -f -
  │ spawns Job 0 = k8s-upgrade-preflight-<target_version>
  ▼

Job 0 — preflight       (pinned: first worker = node1; +nvidia.com/gpu tol)
Job 1 — master upgrade  (pinned: first worker = node1; +nvidia.com/gpu tol)  drains k8s-master
Job 2..N — worker       (pinned: k8s-master)       drains each worker still off-target
                                                   ← control-plane toleration; one Job
                                                     per worker, enumerated live from
                                                     `kubectl get nodes` (covers node5/6
                                                     + any future node automatically)
Job N+1 — postflight    (no pinning)
```

Each Job runs `scripts/upgrade-step.sh`, which dispatches on `$PHASE` and ends
by spawning the next Job (`envsubst < /template/job-template.yaml | kubectl
apply -f -`). Job names are deterministic (`k8s-upgrade-<phase>-<target_version>[-<node>]`)
so `apply` reconciles to a single Job per run — re-running won't duplicate
downstream Jobs. The detection CronJob and `spawn_next` additionally delete +
re-spawn a terminally-**Failed** Job of the same name (rather than skipping it
on existence), so a transient preflight gate self-heals on the next cycle
instead of wedging the pipeline until the dead Job's 7d TTL expires
(retry-on-failure, added 2026-06-17 after a spurious critical alert stalled
1.34.9 for 5 days).

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
  upgrade-step.sh. The master path runs `kubeadm upgrade apply` with
  `--ignore-preflight-errors=CoreDNSMigration,CoreDNSUnsupportedPlugins
  --skip-phases=addon/coredns` so kubeadm never touches CoreDNS (custom Corefile
  + separately-tracked image; CoreDNS is pinned off Keel via `keel.sh/policy=never`).
  See the runbook's "CoreDNS is NOT upgraded by kubeadm here".
- **Four Upgrade Gates alerts**:
  - `K8sVersionSkew` — `count(count by (kubelet_version)(kube_node_info)) > 1 unless on() (<chain job>.active>0)` for 15m. Catches a half-done rollout **at rest**. Rebuilt 2026-07-25 off `kube_node_info` (the old `kubernetes_build_info{job=~"kubernetes-nodes|kubernetes-apiservers"}` source was never scraped → the alert could never fire, RC5); the `unless active>0` guard suppresses it only during a genuinely-running phase.
  - `EtcdPreUpgradeSnapshotMissing` — `k8s_upgrade_in_flight==1 && k8s_upgrade_snapshot_taken==0` for 10m. Catches preflight failing silently. (Deliberately NOT given the live-Job guard — its snapshot runs while the master Job is Active.)
  - `K8sUpgradeStalled` — `k8s_upgrade_in_flight==1 && time()-started > 14400 && sum(<chain job>.active)>0` for 5m. Catches a chain Job **genuinely running** >4h. Hardened 2026-07-25 with the live-Job guard + 90m→4h — the old latch-only expr fired forever on any leaked `in_flight=1` (also blocking kured); a leaked latch is auto-cleared by the detection reconcile within 12h.
  - `K8sUpgradeChainJobFailed` — `(kube_job_status_failed{namespace="k8s-upgrade",job_name=~"k8s-upgrade-(preflight|master|worker|postflight)-.*",reason=~"BackoffLimitExceeded|DeadlineExceeded"} > 0) unless on() (k8s_upgrade_blocked == 1)` for 15m (warning). Catches a phase Job that terminally failed **before `in_flight` was set** (the preflight gates exit pre-metric) — invisible to the two `in_flight`-based alerts above; this was the blind spot behind the 5-day 1.34.9 preflight wedge. Reason-scoped so a retry-success doesn't false-positive (and so it doesn't needlessly block kured). The `unless k8s_upgrade_blocked == 1` clause (2026-06-21) excludes a deliberate compat-gate refusal (owned by `K8sUpgradeBlocked`) so a block doesn't double-fire as a wedge.
- **Pushgateway metrics**:
  - `k8s_upgrade_in_flight` (set in preflight, cleared in postflight)
  - `k8s_upgrade_snapshot_taken` (set after etcd snapshot Job completes with ≥1 KiB)
  - `k8s_upgrade_started_timestamp` (set in preflight; used by `K8sUpgradeStalled`)
  - `k8s_upgrade_available{kind,running,target}` (pushed by detection CronJob)
  - `k8s_version_check_last_run_timestamp` (staleness watchdog)
- **Leaked-latch reconcile** (2026-07-25): the detection CronJob, at the start of every run, clears a stale `k8s_upgrade_in_flight=1` (no active chain Job AND >12h) by DELETEing the Pushgateway `k8s-version-upgrade` group + stale ns annotations + terminal chain Jobs. Ground-truth via `kubectl`, so it survives a SIGKILL that a shell `trap` cannot. The pipeline's own criticals (`K8sUpgradeStalled`, `EtcdPreUpgradeSnapshotMissing`) are also in the preflight halt-on-alert ignore-list so a still-firing self-emitted critical can't deadlock the very preflight that would clear it (RC3).

### Source of truth

| Concern | Location |
|---|---|
| Stack (CronJob + ConfigMaps + SA/RBAC + ExternalSecret) | `stacks/k8s-version-upgrade/main.tf` |
| Phase orchestration | `stacks/k8s-version-upgrade/scripts/upgrade-step.sh` |
| Job template | `stacks/k8s-version-upgrade/job-template.yaml` |
| Per-node upgrade script | `scripts/update_k8s.sh` |
| Alerts | `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (group "Upgrade Gates") |
| Vault secrets | `secret/k8s-upgrade/{ssh_key, ssh_key_pub, slack_webhook}` |
| Deprecated agent prompt (reference, removed 2026-10-04) | `git show fd0f4a03:.claude/agents/k8s-version-upgrade.deprecated.md` |

### Why this design

The cluster has a single control plane (no HA). A failed `kubeadm upgrade apply` is an outage. Mitigations:

- **Mandatory etcd snapshot before every run** (even patch). Recovery point if master breaks.
- **Halt-on-alert before every drain**. Reuses the same Prometheus ignore-list regex kured uses — any unrelated cluster-health alert blocks. Three gate alerts catch upgrade-specific half-states (version skew, missing snapshot, stalled chain).
- **Job pinning eliminates self-preemption**. Each Job's pod runs on a node that is NOT its drain target: the master-drain Job runs on the first worker; every worker-drain Job runs on k8s-master (already upgraded, control-plane toleration). The worker set is enumerated live from `kubectl get nodes`, so new nodes are covered with no script change; SSH targets are node InternalIPs (no DNS dependency). **The first worker is k8s-node1, which carries `nvidia.com/gpu:NoSchedule` (flipped from PreferNoSchedule 2026-07-19, code-j3tx), so the preflight and master-drain Jobs also carry a matching GPU toleration — without it they hang Pending indefinitely (fixed 2026-07-24 after a ~5-day preflight stall surfaced by a cluster health check).**
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
