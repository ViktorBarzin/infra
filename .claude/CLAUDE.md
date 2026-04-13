# Claude Code — Project Configuration

> **Shared knowledge**: Read `AGENTS.md` at repo root for architecture, patterns, rules, and operations. This file adds Claude-specific features on top.

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (7 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: All agents are global (`~/.claude/agents/`, shared via dotfiles). Install Viktor's dotfiles for the full set.
  - **Infra specialists**: cluster-health-checker, dba, home-automation-engineer, network-engineer, observability-engineer, platform-engineer, security-engineer, sre
  - **Incident pipeline**: post-mortem → sev-triage → sev-historian → sev-report-writer
  - **DevOps**: devops-engineer, deploy-app, review-loop
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)

## Critical Rule: Terraform Only

**ALL infrastructure changes MUST go through Terraform/Terragrunt.** Never use `kubectl apply/edit/patch/set`, `helm install/upgrade`, or any manual cluster mutation as the final state.

- **No exceptions for "quick fixes"** — even one-line changes must be in `.tf` files and applied via `scripts/tg apply`
- **kubectl is for read-only operations and temporary debugging only** (get, describe, logs, exec, port-forward)
- **If a resource isn't in Terraform yet**, evaluate whether it can be added before making manual changes. If manual change is unavoidable (e.g., emergency), document it immediately and create the Terraform resource in the same session
- **kubectl scale/patch during migrations is acceptable** as a transient step, but the final state must be in Terraform and applied via `scripts/tg apply`
- **Helm values live in Terraform** (templatefile or inline) — never `helm upgrade` directly

Violations cause state drift, which causes future applies to break or silently revert changes.

## Instructions
- **"remember X"**: Use `memory-tool store "content" --category facts --tags "tag1,tag2"` (via exec) for persistent cross-session memory. Also update this file + `AGENTS.md` (if shared knowledge), commit with `[ci skip]`. To recall: `memory-tool recall "query"`. To list: `memory-tool list`. To delete: `memory-tool delete <id>`. The native `memory_search` and `memory_get` tools are also available for searching indexed memory files. For **storing** new memories, always use the `memory-tool` CLI via exec.
- **Apply**: Authenticate via `vault login -method=oidc`, then use `scripts/tg` (preferred — handles state decrypt/encrypt) or `terragrunt` directly. `scripts/tg` adds `-auto-approve` for `--non-interactive` applies.
- **New services need CI/CD** and **monitoring** (Prometheus/Uptime Kuma)
- **New service**: Use `setup-project` skill for full workflow
- **Ingress**: `ingress_factory` module. Auth: `protected = true`. Anti-AI: on by default.
- **Docker images**: Always build for `linux/amd64`. Use 8-char git SHA tags — `:latest` causes stale pull-through cache.
- **Private registry**: `registry.viktorbarzin.me` (htpasswd auth, credentials in Vault `secret/viktor`). Use `image: registry.viktorbarzin.me/<name>:<tag>` + `imagePullSecrets: [{name: registry-credentials}]`. Kyverno auto-syncs the secret to all namespaces. Build & push from registry VM (`10.0.20.10`). Containerd `hosts.toml` redirects pulls to LAN IP directly. Web UI at `docker.viktorbarzin.me` (Authentik-protected).
- **LinuxServer.io containers**: `DOCKER_MODS` runs apt-get on every start — bake slow mods into a custom image (`RUN /docker-mods || true` then `ENV DOCKER_MODS=`). Set `NO_CHOWN=true` to skip recursive chown that hangs on NFS mounts.
- **Node memory changes**: When changing VM memory on any k8s node, update kubelet `systemReserved`, `kubeReserved`, and eviction thresholds accordingly. Config: `/var/lib/kubelet/config.yaml`. Template: `stacks/infra/main.tf`. Current values: systemReserved=512Mi, kubeReserved=512Mi, evictionHard=500Mi, evictionSoft=1Gi.
- **Node OS disk tuning** (in `stacks/infra/main.tf`): kubelet `imageGCHighThresholdPercent=70` (was 85), `imageGCLowThresholdPercent=60` (was 80), ext4 `commit=60` in fstab (was default 5s), journald `SystemMaxUse=200M` + `MaxRetentionSec=3day`.
- **Sealed Secrets**: User-managed secrets go in `sealed-*.yaml` files in the stack directory. Stacks pick them up via `kubernetes_manifest` + `fileset(path.module, "sealed-*.yaml")`. See AGENTS.md for full workflow.
- **CRITICAL — Update docs with every change**: When modifying infrastructure (Terraform, Vault, networking, storage, CI/CD, monitoring), you MUST update all affected documentation in the same commit. Check and update: `docs/architecture/*.md`, `docs/runbooks/*.md`, `.claude/CLAUDE.md`, `AGENTS.md`, `.claude/reference/service-catalog.md`. Stale docs cause incident response failures and onboarding confusion. If unsure which docs are affected, grep for the service/resource name across all doc files.

## Terraform State — SOPS-Encrypted in Git
- **State is local** (`backend "local"`), encrypted with SOPS and committed as `.tfstate.enc` files.
- **Decrypt priority**: Vault Transit (primary, uses existing `vault login` session) → age key fallback (`~/.config/sops/age/keys.txt`, for bootstrap/DR).
- **Encrypt**: Always encrypts to both Vault Transit (`transit/keys/sops-state`) + age recipients.
- **Scripts**: `scripts/state-sync {encrypt|decrypt|commit} [stack]` — handles all state sync. `scripts/tg` auto-decrypts before and auto-encrypts+commits after mutating ops (apply/destroy/import).
- **Workflow**: `git pull` → `scripts/tg plan` → `scripts/tg apply` → `git push`. State sync is transparent.
- **Config**: `.sops.yaml` at repo root defines encryption rules. age public keys listed there.
- **Backups disabled**: `terragrunt.hcl` passes `-backup=-` to prevent `.backup` file accumulation.
- **Adding operator**: Generate age key (`age-keygen`), add pubkey to `.sops.yaml`, run `sops updatekeys` on all `.enc` files.
- **Two workstations**: Laptop (macOS) + DevVM (10.0.10.10, Linux). Both have age keys + Vault access. Keys backed up in Vault (`secret/viktor/sops_age_key_laptop`, `sops_age_key_devvm`).

## Secrets Management — Vault KV
- **Vault is the sole source of truth** for secrets.
- **`secret/viktor`** — go-to path for ALL personal secrets (135 keys). Contains every API key, token, password, SSH key, and config from the old terraform.tfvars. Check here first: `vault kv get -field=KEY secret/viktor`.
- **Auth**: `vault login -method=oidc` (Authentik SSO) → `~/.vault-token` → read by Vault TF provider.
- **Vault stack self-reads**: `data "vault_kv_secret_v2" "vault"` reads its own OIDC creds from `secret/vault`.
- **ESO (External Secrets Operator)**: `stacks/external-secrets/` — 43 ExternalSecrets + 9 DB-creds ExternalSecrets. API version `v1beta1`. Two ClusterSecretStores: `vault-kv` and `vault-database`.
- **Plan-time pattern**: Former plan-time stacks use `data "kubernetes_secret"` to read ESO-created K8s Secrets at plan time (no Vault dependency). First-apply gotcha: must `terragrunt apply -target=kubernetes_manifest.external_secret` first, then full apply. `count` on resources using secret values fails — remove conditional counts.
- **14 hybrid stacks** still keep `data "vault_kv_secret_v2"` for plan-time needs (job commands, Helm templatefile, module inputs). Platform has 48 plan-time refs — no migration possible without restructuring modules.
- **Database rotation**: Vault DB engine rotates passwords every 7 days (604800s). MySQL: speedtest, wrongmove, codimd, nextcloud, shlink, grafana, phpipam. PostgreSQL: health, linkwarden, affine, woodpecker, claude_memory, crowdsec, technitium. Excluded: authentik (PgBouncer), root users. Technitium uses a password-sync CronJob (every 6h) to push rotated password to the Technitium app config via API, disable MySQL logging, install PG plugin if missing, and configure PG query logging (90-day retention).
- **K8s credentials**: Vault K8s secrets engine. Roles: `dashboard-admin`, `ci-deployer`, `openclaw`, `local-admin`. Use `vault write kubernetes/creds/ROLE kubernetes_namespace=NS`. Helper: `scripts/vault-kubeconfig`.
- **CI/CD (GHA + Woodpecker)**: Docker builds run on **GitHub Actions** (free on public repos). Woodpecker is **deploy-only** — receives image tag via API POST, runs `kubectl set image`. Woodpecker authenticates via K8s SA JWT → Vault K8s auth. Sync CronJob pushes `secret/ci/global` → Woodpecker API every 6h. Shell scripts in HCL heredocs: escape `$` → `$$`, `%{}` → `%%{}`.
- **Platform cannot depend on vault** (circular). Apply order: vault first, then platform. Platform has 48 vault refs, all in module inputs — no ESO migration possible.
- **Complex types** (maps/lists like `homepage_credentials`, `k8s_users`) stored as JSON strings in KV, decoded with `jsondecode()` in consuming stack `locals` blocks.
- **New stacks**: Add secret in Vault UI/CLI at `secret/<stack-name>`, add ExternalSecret + `data "kubernetes_secret"` for plan-time, `secret_key_ref` for env vars. Use `data "vault_kv_secret_v2"` only if `data "kubernetes_secret"` won't work (e.g., first-apply bootstrap).
- **Backup CronJob**: `vault-raft-backup` uses manually-created `vault-root-token` K8s Secret (independent of automation).
- **Bootstrap (fresh cluster)**: Comment out data source + OIDC → apply Helm → init+unseal → populate `secret/vault` → uncomment → re-apply.

## Resource Management Patterns
- **CPU**: All CPU limits removed cluster-wide (CFS throttling). Only set CPU requests based on actual usage.
- **Memory**: Set explicit `requests=limits` based on VPA upperBound. Target: upperBound x 1.2 for stable services, x 1.3 for GPU/volatile workloads.
- **VPA (Goldilocks)**: Must be `Initial` mode (not `Auto`) — Auto conflicts with Terraform's declarative resource management.
- **LimitRange**: Tier-based defaults silently apply to pods with `resources: {}`. Always set explicit resources on containers needing more than defaults. Tier 3-edge and 4-aux now use Burstable QoS (request < limit) to reduce scheduler pressure.
- **Democratic-CSI sidecars**: Must set explicit resources (32-80Mi) in Helm values — 17 sidecars default to 256Mi each via LimitRange. `csiProxy` is a TOP-LEVEL chart key, not nested under controller/node.
- **ResourceQuota blocks rolling updates**: When quota is tight, scale to 0 then back to 1 instead of RollingUpdate. Or use Recreate strategy.
- **Kyverno ndots drift**: Kyverno injects dns_config on all pods. Add `lifecycle { ignore_changes = [spec[0].template[0].spec[0].dns_config] }` to kubernetes_deployment resources to prevent perpetual TF plan drift.
- **NVIDIA GPU operator resources**: dcgm-exporter and cuda-validator resources configurable via `dcgmExporter.resources` and `validator.resources` in nvidia values.yaml.
- **Pin database versions**: Disable Diun (image update monitoring) for MySQL, PostgreSQL, Redis.
- **Quarterly right-sizing**: Check Goldilocks dashboard. Compare VPA upperBound to current request. Also check for under-provisioned (VPA upper > request x 0.8).

## CI/CD Architecture — GHA Builds + Woodpecker Deploy

**Flow**: `git push → GHA build+push DockerHub (8-char SHA) → POST Woodpecker API → kubectl set image`

**Migrated to GHA** (10): Website, k8s-portal, f1-stream, claude-memory-mcp, apple-health-data, audiblez-web, plotting-book, insta2spotify, audiobook-search, council-complaints
**Woodpecker-only**: travel_blog (1.4GB content too large for GHA), infra pipelines (terragrunt apply, certbot, build-cli — need cluster access)

**Per-project files**:
- `.github/workflows/build-and-deploy.yml` — GHA: checkout, build, push DockerHub, POST Woodpecker API
- `.woodpecker/deploy.yml` — Woodpecker: `kubectl set image` + Slack notify (event: `[manual, push]`)
- `.woodpecker/build-fallback.yml` — Old full build pipeline preserved (event: `deployment` — never auto-fires)

**Woodpecker API**: Uses **numeric repo IDs** (`/api/repos/2/pipelines`), NOT owner/name paths (those return HTML).
Repo IDs: infra=1, Website=2, finance=3, health=4, travel_blog=5, webhook-handler=6, audiblez-web=9, f1-stream=10, plotting-book=43, claude-memory-mcp=78, infra-onboarding=79, council-complaints=TBD

**Woodpecker YAML gotchas**:
- Commands with `${VAR}:${VAR}` must be **quoted** — unquoted `:` triggers YAML map parsing when vars are empty
- Use `bitnami/kubectl:latest` (not pinned versions — entrypoint compatibility issues)
- Global secrets must have `manual` in their events list for API-triggered pipelines

**GitHub repo secrets** (set on all repos): `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `WOODPECKER_TOKEN`

**Infra pipelines unchanged**: `default.yml` (terragrunt apply), `renew-tls.yml` (certbot cron), `build-cli.yml` (dual registry push), `k8s-portal.yml` (path-filtered build), `provision-user.yml` — all stay on Woodpecker.

## Database Host

**`postgresql_host`** in `config.tfvars` is `pg-cluster-rw.dbaas.svc.cluster.local` (the CNPG primary). The legacy `postgresql.dbaas` service has no endpoints — never use it. This variable is shared by ~12 stacks.

**CNPG tuning** (in `stacks/dbaas/modules/dbaas/main.tf`): `shared_buffers=512MB`, `work_mem=16MB`, `wal_compression=on`, `effective_cache_size=1536MB`, pod memory 2Gi.

## Networking & Resilience
- **Critical path services scaled to 3**: Traefik, Authentik, CrowdSec LAPI, PgBouncer, Cloudflared.
- **PDBs**: minAvailable=2 on Traefik and Authentik.
- **Fallback proxies**: basicAuth when Authentik is down, fail-open when poison-fountain is down.
- **CrowdSec bouncer**: graceful degradation mode (fail-open on error).
- **Rate limiting**: Return 429 (not 503). Per-service tuning: Immich/Nextcloud need higher limits.
- **Retry middleware**: 2 attempts, 100ms — in default ingress chain.
- **HTTP/3 (QUIC)**: Enabled cluster-wide via Traefik.
- **IPAM & DNS auto-registration**: pfSense Kea DHCP serves all 3 subnets (VLAN 10, VLAN 20, 192.168.1.x). Kea DDNS auto-registers every DHCP client in Technitium (RFC 2136, A+PTR). CronJob `phpipam-pfsense-import` (5min) pulls Kea leases + ARP into phpIPAM via SSH (passive, no scanning). CronJob `phpipam-dns-sync` (15min) bidirectional sync phpIPAM ↔ Technitium. 42 MAC reservations for 192.168.1.x.

## Service-Specific Notes
| Service | Key Operational Knowledge |
|---------|--------------------------|
| Nextcloud | MaxRequestWorkers=150, needs 8Gi limit (Apache transient memory spikes, see commit eb94144), very generous startup probe |
| Immich | ML on SSD, disable ModSecurity (breaks streaming), CUDA for ML, frequent upgrades |
| CrowdSec | Pin version, disable Metabase when not needed (CPU hog), LAPI scaled to 3, **DB on PostgreSQL** (migrated from MySQL), flush config: max_items=10000/max_age=7d/agents_autodelete=30d, DECISION_DURATION=168h in blocklist CronJob |
| Frigate | GPU stall detection in liveness probe (inference speed check), high CPU |
| Authentik | 3 replicas, PgBouncer in front of PostgreSQL, strip auth headers before forwarding |
| Kyverno | failurePolicy=Ignore to prevent blocking cluster, pin chart version |
| MySQL InnoDB | 1 instance (was 3 — only Uptime Kuma 34MB + phpIPAM 1.4MB remain), PriorityClass `mysql-critical` + PDB, `innodb_doublewrite=OFF`, anti-affinity excludes k8s-node1 (GPU), 2Gi req / 3Gi limit |
| phpIPAM | IPAM — no active scanning. `pfsense-import` CronJob (5min) pulls Kea leases + ARP via SSH. `dns-sync` CronJob (15min) bidirectional sync with Technitium. Kea DDNS on pfSense handles all 3 subnets. API app `claude` (ssl_token). |

## Monitoring & Alerting
- Alert cascade inhibitions: if node is down, suppress pod alerts on that node.
- Exclude completed CronJob pods from "pod not ready" alerts.
- Every new service gets Prometheus scrape config + Uptime Kuma monitor.
- Key alerts: OOMKill, pod replica mismatch, 4xx/5xx error rates, UPS battery, CPU temp, SSD writes, NFS responsiveness, ClusterMemoryRequestsHigh (>85%), ContainerNearOOM (>85% limit), PodUnschedulable.
- **E2E email monitoring**: CronJob `email-roundtrip-monitor` (every 20 min) sends test email via Mailgun API to `smoke-test@viktorbarzin.me` (catch-all → `spam@`), verifies IMAP delivery, deletes test email, pushes metrics to Pushgateway + Uptime Kuma. Alerts: `EmailRoundtripFailing` (60m), `EmailRoundtripStale` (60m), `EmailRoundtripNeverRun` (60m). Outbound relay: Brevo EU (`smtp-relay.brevo.com:587`, 300/day free — migrated from Mailgun). Mailserver on dedicated MetalLB IP `10.0.20.202` with `externalTrafficPolicy: Local` for CrowdSec real-IP detection. Vault: `mailgun_api_key` in `secret/viktor` (probe), `brevo_api_key` in `secret/viktor` (relay).

## Storage & Backup Architecture

### Storage Class Decision Rule (for new services)

Choose storage class based on workload type:

| Use **proxmox-lvm** when | Use **NFS** (`nfs_volume` module) when | Use **nfs-proxmox** SC when |
|--------------------------|----------------------------------------|-----------------------------|
| Database files (SQLite, embedded DBs) | Shared data across multiple pods (RWX) | Dynamic provisioning on Proxmox host NFS |
| Write-heavy / fsync-heavy workloads | Media libraries (music, ebooks, photos) | Vault (dynamic PVC creation) |
| Single-pod app state (RWO is fine) | Backup destinations (cloud sync picks up from NFS) | |
| Latency-sensitive data | Large datasets (>10Gi) where snapshots matter | |
| Any new service by default | Data you want to browse/inspect from outside k8s | |

**Default is proxmox-lvm.** Only use NFS when you need RWX, backup pipeline integration, or it's a large shared media library.

**NFS servers:**
- **Proxmox host** (192.168.1.127): Primary NFS for all workloads. HDD at `/srv/nfs` (ext4 thin LV `pve/nfs-data`, 1TB). SSD at `/srv/nfs-ssd` (ext4 LV `ssd/nfs-ssd-data`, 100GB). Exports use `async,insecure` options (`async` — safe with UPS + Vault Raft replication + databases on block storage; `insecure` — pfSense NATs source ports >1024 between VLANs).
- **TrueNAS** (10.0.10.15): **Immich only** (8 PVCs). `nfs-truenas` StorageClass retained exclusively for Immich.

**Migration note**: CSI PV `volumeAttributes` are immutable — cannot update NFS server in place. New PV/PVC pairs required (convention: append `-host` to PV name).

**proxmox-lvm PVC template** (Terraform):
```hcl
resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "<service>-data-proxmox"
    namespace = kubernetes_namespace.<ns>.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "1Gi" }
    }
  }
}
```
- `wait_until_bound = false` is **required** (WaitForFirstConsumer binding)
- Deployment strategy **must be Recreate** (RWO volumes)
- Autoresizer annotations are **required** on all proxmox-lvm PVCs
- Every proxmox-lvm app **MUST** add a backup CronJob writing to NFS `/mnt/main/<app>-backup/`

### 3-2-1 Backup Strategy
**Copy 1**: Live data on sdc thin pool (65 PVCs + VMs)
**Copy 2**: sda backup disk (`/mnt/backup`, 1.1TB ext4, VG `backup`)
**Copy 3**: Synology NAS offsite (two-tier: sda + NFS)

**PVE host scripts** (source: `infra/scripts/`):
- `/usr/local/bin/daily-backup` — Daily 05:00. Mounts LVM thin snapshots ro → rsyncs FILES to `/mnt/backup/pvc-data/<YYYY-WW>/<ns>/<pvc>/` with `--link-dest` versioning (4 weeks). Auto SQLite backup (magic number check, `?mode=ro`). Auto-discovered BACKUP_DIRS (glob, not hardcoded). Also backs up pfSense (config.xml + tar), PVE config. Prunes snapshots >7d.
- `/usr/local/bin/offsite-sync-backup` — Daily 06:00 (After=daily-backup). Step 1: sda → Synology `pve-backup/` (PVC snapshots, pfSense, PVE config). Step 2: NFS → Synology `nfs/` + `nfs-ssd/` via inotify change-tracked `rsync --files-from`. Monthly full `rsync --delete` on 1st Sunday.
- `/usr/local/bin/lvm-pvc-snapshot` — Daily 03:00. Thin snapshots of all PVCs except dbaas+monitoring. 7-day retention. Instant restore: `lvm-pvc-snapshot restore <lv> <snap>`.
- `nfs-change-tracker.service` — Continuous inotifywait on `/srv/nfs` + `/srv/nfs-ssd`. Logs changed file paths to `/mnt/backup/.nfs-changes.log`. Consumed by offsite-sync-backup for incremental rsync (completes in seconds instead of 30+ minutes).

**Synology layout** (`192.168.1.13:/volume1/Backup/Viki/`):
- `pve-backup/` — PVC file backups (`pvc-data/`), SQLite backups (`sqlite-backup/`), pfSense, PVE config (synced from sda)
- `nfs/` — mirrors `/srv/nfs` on Proxmox (inotify change-tracked rsync, renamed from `truenas/`)
- `nfs-ssd/` — mirrors `/srv/nfs-ssd` on Proxmox (inotify change-tracked rsync)

**App-level CronJobs** (write to Proxmox host NFS, synced to Synology via inotify):
- MySQL (daily), PostgreSQL (daily), Vault (weekly), Vaultwarden (6h + integrity), Redis (weekly), etcd (weekly)
- **Convention**: New proxmox-lvm apps MUST add a backup CronJob writing to `/mnt/main/<app>-backup/`

**Restore paths**:
- Accidental delete: `lvm-pvc-snapshot restore` (instant, 7 daily snapshots)
- Older data: Browse `/mnt/backup/pvc-data/<week>/<ns>/<pvc>/`, rsync back
- Database: Restore from dump at `/srv/nfs/<db>-backup/` or Synology `nfs/<db>-backup/`
- pfsense: Upload config.xml via web UI, or extract tar for custom scripts
- Full disaster: Restore from Synology

## Known Issues
- **CrowdSec Helm upgrade times out**: `terragrunt apply` on platform stack causes CrowdSec Helm release to get stuck in `pending-upgrade`. Workaround: `helm rollback crowdsec <rev> -n crowdsec`. Root cause: likely ResourceQuota CPU at 302% preventing pods from passing readiness probes. Needs investigation.
- **OpenClaw config is writable**: OpenClaw writes to `openclaw.json` at runtime (doctor --fix, plugin auto-enable). Never use subPath ConfigMap mounts for it — use an init container to copy into a writable volume. Needs 2Gi memory + `NODE_OPTIONS=--max-old-space-size=1536`.
- **Goldilocks VPA sets limits**: When increasing memory requests, always set explicit `limits` too — Goldilocks may have added a limit that blocks the change.

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
