# Infrastructure Repository — AI Agent Instructions

## Critical Rules (MUST FOLLOW)
- **ALL changes through Terraform/Terragrunt** — NEVER `kubectl apply/edit/patch/delete` for persistent changes. Read-only kubectl is fine.
- **NEVER put secrets in plaintext** — use `secrets.sops.json` (SOPS-encrypted) or `terraform.tfvars` (git-crypt, legacy)
- **NEVER restart NFS on the Proxmox host** — causes cluster-wide mount failures across all pods
- **NEVER commit secrets** — triple-check before every commit
- **`[ci skip]` in commit messages** when changes were already applied locally
- **Ask before `git push`** — always confirm with the user first

## Execution
- **Apply a service**: `scripts/tg apply --non-interactive` (auto-decrypts SOPS secrets)
- **Legacy apply**: `cd stacks/<service> && terragrunt apply --non-interactive` (uses terraform.tfvars)
- **kubectl**: `kubectl --kubeconfig $(pwd)/config`
- **Health check**: `bash scripts/cluster_healthcheck.sh --quiet`
- **Plan all**: `cd stacks && terragrunt run --all --non-interactive -- plan`

## Adopting Existing Resources — Use `import {}` Blocks, Not the CLI

When bringing a live cluster/Vault/Cloudflare resource under Terraform management, use an HCL `import {}` block (Terraform 1.5+). Do **NOT** use `terraform import` on the CLI for anything landing in this repo — the CLI path leaves no audit trail and makes multi-operator adoption fragile.

**Canonical workflow:**

1. Write the `resource` block that matches the live object.
2. In the same stack, add an `import {}` stanza naming the target and the provider-specific ID:
   ```hcl
   import {
     to = helm_release.kured
     id = "kured/kured"  # Helm ID format: <namespace>/<release-name>
   }

   resource "helm_release" "kured" {
     name       = "kured"
     namespace  = "kured"
     repository = "https://kubereboot.github.io/charts/"
     chart      = "kured"
     version    = "5.7.0"
     # ... values matching the live release
   }
   ```
3. `scripts/tg plan` — every change it proposes is real divergence between HCL and live state. Iterate on values until the plan is **0 changes**.
4. `scripts/tg apply` — the import runs alongside whatever zero-change apply you have. If your plan is 0 changes, this commits only the state-ownership transfer.
5. After the apply lands cleanly, **delete the `import {}` block** in a follow-up commit. The resource is now fully TF-owned and the stanza would be a no-op that clutters diffs.

**Why `import {}` and not `terraform import`:**

- Reviewable in PRs before any state mutation. The CLI path is an out-of-band action nobody sees.
- Plan-safe: the `import` plan step shows the exact object being adopted. Mistyped IDs or the wrong resource address are caught before apply, not after.
- Survives state backend changes (Tier 0 SOPS vs Tier 1 PG) transparently — both work identically from the operator's perspective because both use `scripts/tg`.
- Re-runnable: if the apply fails partway through, the `import {}` block is idempotent. The CLI path's state mutation is not.

**Finding the provider-specific ID:** each provider has its own convention.
| Resource | ID format | Example |
|---|---|---|
| `helm_release` | `<namespace>/<release-name>` | `kured/kured` |
| `kubernetes_manifest` | `{"apiVersion":"...","kind":"...","metadata":{"namespace":"...","name":"..."}}` | (pass as HCL object literal) |
| `kubernetes_<kind>_v1` | `<namespace>/<name>` for namespaced, `<name>` for cluster-scoped | `kube-system/coredns` |
| `authentik_provider_proxy` | provider UUID | `0eecac07-97c7-443c-...` |
| `cloudflare_record` | `<zone-id>/<record-id>` | `abc123/def456` |

## Secrets Management (SOPS)
- **`config.tfvars`** — plaintext config (hostnames, IPs, DNS records, public keys)
- **`secrets.sops.json`** — SOPS-encrypted secrets (passwords, tokens, SSH keys, API keys)
- **`.sops.yaml`** — defines who can decrypt (age public keys: Viktor + CI)
- **`scripts/tg`** — wrapper that auto-decrypts SOPS before running terragrunt
- **Edit secrets**: `sops secrets.sops.json` (opens $EDITOR, re-encrypts on save)
- **Add a secret**: `sops set secrets.sops.json '["new_key"]' '"value"'`
- **Operators** push PRs → Viktor reviews → CI decrypts and applies. No encryption keys needed for operators.

## Sealed Secrets (User-Managed Secrets)
For secrets that users manage themselves (no SOPS/git-crypt access needed):
1. **Create**: `kubectl create secret generic <name> --from-literal=key=value -n <ns> --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets -o yaml > sealed-<name>.yaml`
2. **Commit**: Place `sealed-*.yaml` files in the stack directory (`stacks/<service>/`)
3. **Terraform picks them up** automatically via `fileset` + `for_each`:
   ```hcl
   resource "kubernetes_manifest" "sealed_secrets" {
     for_each = fileset(path.module, "sealed-*.yaml")
     manifest = yamldecode(file("${path.module}/${each.value}"))
   }
   ```
4. **Deploy**: Push → CI runs `terragrunt apply` → controller decrypts into real K8s Secrets
- Only the in-cluster controller has the private key. `kubeseal` uses the public key — safe to distribute.
- Naming convention: files MUST match `sealed-*.yaml` glob pattern.
- The `kubernetes_manifest` block is safe to add even with zero sealed-*.yaml files (empty for_each).

## Architecture
Terragrunt-based homelab managing a Kubernetes cluster (5 nodes, v1.34.2) on Proxmox VMs.
- **100+ stacks**, each in `stacks/<service>/` with its own Terraform state
- **Core platform**: `stacks/platform/` is now an empty shell — all modules have been extracted to independent stacks under `stacks/`
- **Public domain**: `viktorbarzin.me` (Cloudflare) | **Internal**: `viktorbarzin.lan` (Technitium DNS)
- **Onboarding portal**: `https://k8s-portal.viktorbarzin.me` — self-service kubectl setup + docs
- **CI/CD**: Woodpecker CI — PRs run plan, merges to master auto-apply all stacks

## Key Paths
- `stacks/<service>/main.tf` — service definition
- `stacks/platform/modules/<service>/` — core infra modules
- `modules/kubernetes/ingress_factory/` — standardized ingress with auth, rate limiting, anti-AI, and auto Cloudflare DNS (`dns_type = "proxied"` or `"non-proxied"`)
- `modules/kubernetes/nfs_volume/` — NFS volume module (CSI-backed, soft mount)
- `config.tfvars` — non-secret configuration (plaintext)
- `secrets.sops.json` — all secrets (SOPS-encrypted JSON)
- `terraform.tfvars` — legacy secrets file (git-crypt, kept for reference)
- `scripts/cluster_healthcheck.sh` — 42-check cluster health script (nodes, workloads, monitoring, certs, backups, external reachability)

## Storage
- **NFS** (`nfs-proxmox` StorageClass): For app data. Use the `nfs_volume` module, never inline `nfs {}` blocks.
- **proxmox-lvm-encrypted** (`proxmox-lvm-encrypted` StorageClass): **Default for all sensitive data** — databases, auth, email, passwords, git repos, health data. LUKS2 encryption via Proxmox CSI. Passphrase in Vault, backup key on PVE host.
- **proxmox-lvm** (`proxmox-lvm` StorageClass): For non-sensitive stateful apps (configs, caches, tools). Proxmox CSI driver.
- **NFS server**: Proxmox host at 192.168.1.127 (sole NFS). HDD NFS at `/srv/nfs` (2TB ext4 LV `pve/nfs-data`), SSD NFS at `/srv/nfs-ssd` (100GB ext4 LV `ssd/nfs-ssd-data`). Exports use `async` mode (safe with UPS + databases on block storage). TrueNAS (VM 9000, 10.0.10.15) decommissioned 2026-04-13. Legacy `nfs-truenas` StorageClass name retained (48 PVs bind it; SC names are immutable on PVs) but now points to the Proxmox host, identical to `nfs-proxmox`.
- **SQLite on NFS is unreliable** (fsync issues) — always use proxmox-lvm or local disk for databases.
- **NFS mount options**: Always `soft,timeo=30,retrans=3` to prevent uninterruptible sleep (D state).
- **NFS export directory must exist** on the Proxmox host before Terraform can create the PV.
- **Backup (3-2-1)**: Copy 1 = live PVCs on sdc. Copy 2 = sda `/mnt/backup` (PVC file backups, auto SQLite backups, pfSense, PVE config). Copy 3 = Synology offsite (two-tier: sda→`pve-backup/`, NFS→`nfs/`+`nfs-ssd/` via inotify change tracking).
- **daily-backup** (Daily 05:00): Auto-discovered BACKUP_DIRS (glob), auto SQLite backup (magic number + `?mode=ro`), pfSense, PVE config. No NFS mirror step (NFS syncs directly to Synology via inotify).
- **offsite-sync-backup** (Daily 06:00): Step 1: sda→Synology `pve-backup/`. Step 2: NFS→Synology `nfs/`+`nfs-ssd/` via `rsync --files-from` (inotify change log). Monthly full `--delete`.
- **nfs-change-tracker.service**: inotifywait on `/srv/nfs` + `/srv/nfs-ssd`, logs to `/mnt/backup/.nfs-changes.log`. Incremental syncs complete in seconds.
- **Synology layout** (`/volume1/Backup/Viki/`): `pve-backup/` (from sda), `nfs/` (from `/srv/nfs`), `nfs-ssd/` (from `/srv/nfs-ssd`).

## Shared Variables (never hardcode)
`var.nfs_server` (192.168.1.127), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Redis Service Naming (read before wiring a new consumer)

The Redis stack (`stacks/redis/`) exposes three distinct entry points. Pick the one that matches the client's connection pattern — the wrong one causes READONLY errors or silent connection drops.

| Endpoint | Port(s) | Use for | Backed by |
|----------|---------|---------|-----------|
| `redis-master.redis.svc.cluster.local` | 6379 (redis), 26379 (sentinel) | **Default for new services.** Write-safe — HAProxy health-checks nodes and routes only to the current master. Matches `var.redis_host`. | `kubernetes_service.redis_master` → HAProxy → Bitnami StatefulSet |
| `redis-node-{0,1,2}.redis-headless.redis.svc.cluster.local` | 26379 | **Long-lived connections (PUBSUB, BLPOP, MONITOR, Sidekiq).** Use a sentinel-aware client with master name `mymaster`. Example: `stacks/nextcloud/chart_values.yaml:32-54`. | Bitnami-created headless service → pod DNS |
| `redis.redis.svc.cluster.local` | 6379 | **Do NOT use.** Helm chart's default service — selector patched by `null_resource.patch_redis_service` to match `redis-haproxy`, so today it behaves like `redis-master`. This patch is load-bearing but temporary; consumers hard-coded on this name are tracked in a beads follow-up (T0). | Bitnami chart (patched) |

**HAProxy's `timeout client 30s` closes idle raw Redis connections** — any client that holds a connection open for pub/sub, blocking commands, or replication streams MUST use the sentinel path. Uptime Kuma's Redis monitor hit this limit and had to be re-pointed at the sentinel endpoint (see memory id=748).

**When onboarding a new service:** start from `redis-master.redis.svc.cluster.local:6379` via `var.redis_host`. Only reach for sentinel discovery if the client library supports it natively (ioredis, redis-py Sentinel, go-redis FailoverClient, Sidekiq `sentinels` array) AND the workload uses long-lived connections.

## Kyverno Drift Suppression (`# KYVERNO_LIFECYCLE_V1`)

Kyverno's admission webhook mutates every pod with a `dns_config { option { name = "ndots"; value = "2" } }` block (fixes NxDomain search-domain floods — see `k8s-ndots-search-domain-nxdomain-flood` skill). Terraform does not manage that field, so without suppression every pod-owning resource shows perpetual `spec[0].template[0].spec[0].dns_config` drift.

**Rule**: every `kubernetes_deployment`, `kubernetes_stateful_set`, `kubernetes_daemon_set`, and `kubernetes_cron_job_v1` MUST include the following `lifecycle` block, tagged with the `# KYVERNO_LIFECYCLE_V1` marker so every site is greppable:

```hcl
# kubernetes_deployment / kubernetes_stateful_set / kubernetes_daemon_set
lifecycle {
  ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
}

# kubernetes_cron_job_v1 (extra job_template nesting)
lifecycle {
  ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
}
```

**Why not a shared module?** Terraform's `ignore_changes` meta-argument only accepts static attribute paths. It rejects module outputs, locals, variables, and any expression. A DRY module is therefore impossible — the canonical pattern IS the snippet + marker. When `kubernetes_manifest` resources get Kyverno `generate.kyverno.io/*` annotations mutated, a sibling convention `# KYVERNO_MANIFEST_V1` will be introduced (Phase B).

**Audit**: `rg "KYVERNO_LIFECYCLE_V1" stacks/ | wc -l` — should grow (never shrink). Add the marker to every new pod-owning resource. The `_template/main.tf.example` stub shows the canonical form.

## Tier System
`0-core` | `1-cluster` | `2-gpu` | `3-edge` | `4-aux` — Kyverno auto-generates LimitRange + ResourceQuota per namespace based on tier label.
- Containers without explicit `resources {}` get default limits (256Mi for edge/aux — causes OOMKill for heavy apps)
- Always set explicit resources on containers that need more than defaults
- Opt-out: labels `resource-governance/custom-quota=true` / `resource-governance/custom-limitrange=true`

## Infrastructure
- **Proxmox**: 192.168.1.127 (Dell R730, 22c/44t, 142GB RAM)
- **Nodes**: k8s-master (10.0.20.100), node1 (GPU, Tesla T4), node2-4
- **GPU**: `node_selector = { "nvidia.com/gpu.present" : "true" }` + toleration `nvidia.com/gpu`. The label is auto-applied by NFD/gpu-feature-discovery on any node with an NVIDIA PCI device — nothing is hostname-pinned, so the GPU card can move between nodes without Terraform edits.
- **Pull-through cache**: 10.0.20.10 — docker.io (:5000), ghcr.io (:5010) only. Caches stale manifests for :latest tags — use versioned tags or pre-pull with `ctr --hosts-dir ''` to bypass.
- **pfSense**: 10.0.20.1 (gateway, firewall, DNS forwarding)
- **MySQL InnoDB Cluster**: 1 instance on proxmox-lvm (scaled from 3 — only Uptime Kuma + phpIPAM remain), PriorityClass `mysql-critical` + PDB, anti-affinity excludes any GPU node (`nvidia.com/gpu.present=true`) so MySQL moves off the GPU host automatically if the card is relocated
- **SMTP**: `var.mail_host` port 587 STARTTLS (not internal svc address — cert mismatch)

## Contributor Onboarding
1. Get Authentik account + Headscale VPN access (ask Viktor)
2. Clone repo — `AGENTS.md` is auto-loaded by Codex
3. Create branch → edit → push → open PR
4. Viktor reviews → CI applies → Slack notification
5. Portal: `https://k8s-portal.viktorbarzin.me/onboarding` for full guide

## Common Operations
- **Deploy new service**: Use `stacks/<existing-service>/` as template. Create stack, add DNS in tfvars, apply platform then service.
- **Fix crashed pods**: Run healthcheck first. Safe to delete evicted/failed pods and CrashLoopBackOff pods with >10 restarts.
- **OOMKilled**: Check `kubectl describe limitrange tier-defaults -n <ns>`. Increase `resources.limits.memory` in the stack's main.tf.
- **Add a secret**: `sops set secrets.sops.json '["key"]' '"value"'` then commit.
- **NFS exports**: Create dir on Proxmox host (`ssh root@192.168.1.127 "mkdir -p /srv/nfs/<service>"`), add to `/etc/exports`, run `exportfs -ra`.

## Automated Service Upgrades
- **Pipeline**: DIUN (detect) → n8n webhook (filter + rate limit) → HTTP POST → `claude-agent-service` (K8s) → `claude -p` (upgrade agent)
- **Agent**: `.claude/agents/service-upgrade.md` — analyzes changelogs, backs up DBs, bumps versions, verifies health, rolls back on failure
- **Config**: `.claude/reference/upgrade-config.json` — GitHub repo mappings, DB-backed services, skip patterns
- **Rate limit**: Max 5 upgrades per 6h DIUN scan cycle (configured in n8n workflow)
- **Skipped**: databases, `:latest`, custom images (`viktorbarzin/*`), infrastructure images
- **Risk**: SAFE (2min verify) vs CAUTION (10min, DB backup, step through versions) based on changelog analysis
- **Docs**: `docs/architecture/automated-upgrades.md`

## Detailed Reference
See `.claude/reference/patterns.md` for: NFS volume code examples, iSCSI details, Kyverno governance tables, anti-AI scraping layers, Terragrunt architecture, node rebuild procedure, archived troubleshooting runbooks index.
