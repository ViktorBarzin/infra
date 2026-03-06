# Infrastructure Repository Knowledge

## Instructions for Claude
- **When the user says "remember" something**: Always update this file (`.claude/CLAUDE.md`) with the information so it persists across sessions
- **When discovering new patterns or versions**: Add them to the appropriate section below
- **After every significant change**: Proactively update this file to reflect what changed — new services, config changes, version bumps, new patterns, etc.
- **After updating any `.claude/` files**: Always commit them immediately (`git add .claude/ && git commit -m "[ci skip] update claude knowledge"`)
- **Skills available**: Check `.claude/skills/` directory for specialized workflows (e.g., `setup-project` for deploying new services)
- **Reference data**: Check `.claude/reference/` for inventory tables, API patterns, and current state snapshots
- **CRITICAL: All infrastructure changes must go through Terraform/Terragrunt**. NEVER modify cluster resources directly (kubectl apply/edit/patch, helm install, docker run). Use `kubectl` only for read-only operations and ephemeral debugging.
- **CRITICAL: NEVER put sensitive data** (API keys, passwords, tokens, credentials) into committed files unless encrypted via git-crypt. Secrets belong in `terraform.tfvars` or `secrets/` directory.
- **CRITICAL: NEVER commit secrets** — triple-check before every commit. Zero exceptions.
- **CRITICAL: NEVER restart NFS** (`service nfsd restart` or equivalent on TrueNAS). This is destructive — it causes mount failures across all pods using NFS volumes cluster-wide. If NFS exports aren't taking effect, re-run `nfs_exports.sh` or wait; never restart the NFS service.
- **New services MUST have CI/CD** (Woodpecker CI pipeline) and **monitoring** (Prometheus alerts and/or Uptime Kuma).

## Execution Environment
- **Terraform/Terragrunt**: Always run locally: `cd stacks/<service> && terragrunt apply --non-interactive`
- **kubectl**: `kubectl --kubeconfig $(pwd)/config`
- **GitHub API**: Use `curl` with tokens from tfvars (see `.claude/reference/github-api.md`). `gh` CLI is blocked by sandbox.

---

## Overview
Terragrunt-based infrastructure repository managing a home Kubernetes cluster on Proxmox VMs, with per-service state isolation. Each service has its own Terragrunt stack under `stacks/`. Uses git-crypt for secrets encryption.

## Key File Paths
- `terraform.tfvars` — All secrets, DNS, Cloudflare config, WireGuard peers (git-crypt encrypted)
- `terragrunt.hcl` — Root config (providers, backend, variable loading)
- `stacks/<service>/` — Individual service stacks (`terragrunt.hcl` + `main.tf`)
- `stacks/platform/` — Core infrastructure (~22 services in `modules/` subdir)
- `stacks/infra/` — Proxmox VM resources
- `modules/kubernetes/ingress_factory/`, `setup_tls_secret/` — Shared utility modules
- `secrets/` — git-crypt encrypted TLS certs and keys

## Domains
- **Public**: `viktorbarzin.me` (Cloudflare-managed)
- **Internal**: `viktorbarzin.lan` (Technitium DNS)

## Key Patterns

### NFS Volume Pattern
**Use the `nfs_volume` shared module** for all NFS volumes. This creates CSI-backed PV/PVC with soft mount options (`soft,timeo=30,retrans=3`) — no stale mount hangs:
```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"  # or ../../../ for sub-stacks
  name       = "<service>-data"       # Must be globally unique (PV is cluster-scoped)
  namespace  = kubernetes_namespace.<service>.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/<service>"
}

# In pod spec:
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = module.nfs_data.claim_name
  }
}
```
For platform modules, use `source = "../../../../modules/kubernetes/nfs_volume"`.
**StorageClass**: `nfs-truenas` (deployed via `stacks/platform/modules/nfs-csi/`).
**DO NOT use inline `nfs {}` blocks** — they mount with `hard,timeo=600` defaults which hang forever on stale mounts.

### iSCSI Storage for Databases
**StorageClass**: `iscsi-truenas` (deployed via `stacks/platform/modules/iscsi-csi/` using democratic-csi).
- Used by: PostgreSQL (CNPG), MySQL (InnoDB Cluster), Redis, Prometheus, Loki — any pod, any node, same data
- Driver: `freenas-iscsi` (SSH-based, NOT `freenas-api-iscsi` which is TrueNAS SCALE only)
- ZFS datasets: `main/iscsi` (zvols), `main/iscsi-snaps` (snapshots)
- All K8s nodes have `open-iscsi` + `iscsid` running

### Adding NFS Exports
1. **Create the directory on TrueNAS first**: `ssh root@10.0.10.15 "mkdir -p /mnt/main/<service> && chmod 777 /mnt/main/<service>"`
2. Edit `secrets/nfs_directories.txt` — add path, keep sorted
3. Run `secrets/nfs_exports.sh` from `secrets/` to update TrueNAS
4. **Note**: If any path in `nfs_directories.txt` doesn't exist on TrueNAS, the API rejects the entire update and no paths are added. Fix missing dirs first.

### Factory Pattern (multi-user services)
Structure: `stacks/<service>/main.tf` + `factory/main.tf`. Examples: `actualbudget`, `freedify`.
To add a user: export NFS share, add Cloudflare route in tfvars, add module block calling factory.

### SMTP/Email
- **Use**: `var.mail_host` (defaults to `mail.viktorbarzin.me`) port 587 (STARTTLS). **NOT** `mailserver.mailserver.svc.cluster.local` (TLS cert mismatch).
- **Credentials**: `mailserver_accounts` in tfvars. Common: `info@viktorbarzin.me`

### Anti-AI Scraping (5-Layer Defense)
All services have `anti_ai_scraping = true` by default in `ingress_factory`. Layers:
1. **Bot blocking** (`traefik-ai-bot-block`): ForwardAuth → poison-fountain `/auth`. Returns 403 for GPTBot, ClaudeBot, CCBot, etc.
2. **X-Robots-Tag** (`traefik-anti-ai-headers`): Adds `noai, noimageai`
3. **Trap links** (`traefik-anti-ai-trap-links`): rewrite-body injects hidden links before `</body>` to `poison.viktorbarzin.me/article/*`
4. **Tarpit**: `/article/*` drip-feeds at ~100 bytes/sec
5. **Poison content**: 50 cached docs (CronJob every 6h, `--http1.1` required)

Key files: `stacks/poison-fountain/`, `stacks/platform/modules/traefik/middleware.tf`, `modules/kubernetes/ingress_factory/main.tf`
Disable per-service: `anti_ai_scraping = false` in ingress_factory call.

### Terragrunt Architecture
- Root `terragrunt.hcl` provides DRY provider, backend, variable loading, and shared `tiers` locals (via `generate "tiers"` block)
- Each stack: `stacks/<service>/main.tf` with resources inline, state at `state/stacks/<service>/terraform.tfstate`
- Platform modules: `stacks/platform/modules/<service>/`, shared modules: `modules/kubernetes/`
- Dependencies via `dependency` block; variables from `terraform.tfvars` (unused silently ignored)
- `secrets/` symlinks in stacks for TLS cert path resolution
- Syntax: `--non-interactive` (not `--terragrunt-non-interactive`), `terragrunt run --all -- <command>` (not `run-all`)
- **Tiers locals**: Auto-generated by Terragrunt into `tiers.tf` in every stack — do NOT add `locals { tiers = { ... } }` to stacks manually

### Adding a New Service
Use the **`setup-project`** skill for the full workflow. Quick reference:
1. Create `stacks/<service>/` with `terragrunt.hcl`, `main.tf`, `secrets` symlink
2. Add Cloudflare DNS in `terraform.tfvars`
3. Apply platform stack (for DNS): `cd stacks/platform && terragrunt apply --non-interactive`
4. Apply service: `cd stacks/<service> && terragrunt apply --non-interactive`

### Shared Infrastructure Variables
All stacks use variables from `terraform.tfvars` for shared service endpoints (auto-loaded by Terragrunt). **Never hardcode these values**:
- `var.nfs_server` — NFS server IP (10.0.10.15)
- `var.redis_host` — Redis hostname (redis.redis.svc.cluster.local)
- `var.postgresql_host` — PostgreSQL hostname (postgresql.dbaas.svc.cluster.local)
- `var.mysql_host` — MySQL hostname (mysql.dbaas.svc.cluster.local)
- `var.ollama_host` — Ollama hostname (ollama.ollama.svc.cluster.local)
- `var.mail_host` — Mail server hostname (mail.viktorbarzin.me)

For standalone stacks: add `variable "nfs_server" { type = string }` (etc.) to `main.tf`.
For platform submodules: add the variable AND pass it through in `stacks/platform/main.tf` module block.

## Useful Commands
```bash
bash scripts/cluster_healthcheck.sh            # Cluster health (24 checks)
bash scripts/cluster_healthcheck.sh --quiet    # Only WARN/FAIL
cd stacks/<service> && terragrunt apply --non-interactive  # Apply single stack
cd stacks && terragrunt run --all --non-interactive -- plan  # Plan all
terraform fmt -recursive                       # Format all
```

## CI/CD
- Woodpecker CI (`.woodpecker/`): pushes apply `platform` stack, hosted at `https://ci.viktorbarzin.me`
- TLS renewal pipeline: cron-triggered `renew2.sh` (certbot + Cloudflare DNS)
- **ALWAYS add `[ci skip]`** to commit messages when you've already applied locally
- **After committing, run `git push origin master`** to sync

## Infrastructure
- Proxmox hypervisor (192.168.1.127) — see `.claude/reference/proxmox-inventory.md` for full VM table
- Kubernetes cluster: 5 nodes (k8s-master + k8s-node1-4, v1.34.2), GPU on node1 (Tesla T4)
- Docker registry pull-through cache at `10.0.20.10` — only docker.io (port 5000) and ghcr.io (port 5010) are active. quay.io/registry.k8s.io/reg.kyverno.io caches disabled (caused corrupted images).
- GPU workloads need: `node_selector = { "gpu": "true" }` + `toleration { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }`

### Node Rebuild Procedure
1. **Drain the node** (if reachable): `kubectl drain k8s-nodeX --ignore-daemonsets --delete-emptydir-data`
2. **Delete from K8s**: `kubectl delete node k8s-nodeX`
3. **Destroy VM** (or remove from `stacks/infra/main.tf` and apply)
4. **Ensure K8s template exists**: `ubuntu-2404-cloudinit-k8s-template` (VMID 2000). If not, apply `stacks/infra/`.
5. **Get join command**: `ssh wizard@10.0.20.100 'sudo kubeadm token create --print-join-command'`
6. **Update `k8s_join_command`** in `terraform.tfvars`
7. **Create VM**: Add to `stacks/infra/main.tf` and apply
8. **Wait for cloud-init** — VM auto-joins cluster
9. **GPU node (k8s-node1) only**: Apply platform stack to re-apply GPU label/taint

**Note**: kubeadm tokens expire after 24h. Generate fresh just before creating the VM.

## Git Operations
- **Git is slow** — commands can take 30+ seconds. Use `GIT_OPTIONAL_LOCKS=0` if git hangs.
- Commit only specific files. **ALWAYS ask user before pushing**.

## Tier System
- **0-core**: Critical infra (ingress, DNS, VPN, auth) | **1-cluster**: Redis, metrics, security | **2-gpu**: GPU workloads | **3-edge**: User-facing | **4-aux**: Optional
- Tiers auto-generated into `tiers.tf` — available as `local.tiers.core`, `local.tiers.cluster`, etc.
- Governance: Kyverno in `stacks/platform/modules/kyverno/` (resource-governance.tf, security-policies.tf)
- Prometheus alerts: `stacks/platform/modules/monitoring/prometheus_chart_values.tpl`

### Kyverno Resource Governance (CRITICAL for debugging container failures)

**LimitRange defaults** — Kyverno auto-generates a `tier-defaults` LimitRange in every namespace. Containers WITHOUT explicit `resources {}` get these injected:

| Tier | Default CPU | Default Mem | Request CPU | Request Mem | Max CPU | Max Mem |
|------|-------------|-------------|-------------|-------------|---------|---------|
| 0-core | 500m | 512Mi | 50m | 64Mi | 4 | 8Gi |
| 1-cluster | 500m | 512Mi | 50m | 64Mi | 2 | 4Gi |
| 2-gpu | 1 | 2Gi | 100m | 256Mi | 8 | 16Gi |
| 3-edge | 250m | 256Mi | 25m | 64Mi | 2 | 4Gi |
| 4-aux | 250m | 256Mi | 25m | 64Mi | 2 | 4Gi |
| No tier | 250m | 256Mi | 25m | 64Mi | 1 | 2Gi |

**ResourceQuota** — auto-generated per namespace (opt-out: label `resource-governance/custom-quota=true`):

| Tier | req CPU | req Mem | lim CPU | lim Mem | Pods |
|------|---------|--------|---------|---------|------|
| 0-core | 8 | 8Gi | 32 | 64Gi | 100 |
| 1-cluster | 4 | 4Gi | 16 | 32Gi | 30 |
| 2-gpu | 8 | 8Gi | 48 | 96Gi | 40 |
| 3-edge | 4 | 4Gi | 16 | 32Gi | 30 |
| 4-aux | 2 | 2Gi | 8 | 16Gi | 20 |

Custom quota namespaces: `authentik` (16 req CPU/16Gi req mem/48 lim CPU/96Gi lim mem/50 pods), `monitoring` (opted out, no replacement), `nvidia` (opted out, no replacement), `nextcloud` (custom), `onlyoffice` (custom).

**LimitRange opt-out**: label `resource-governance/custom-limitrange=true` — skips Kyverno-generated LimitRange, requires a custom `kubernetes_limit_range` in the stack. Used by: `nextcloud` (max 16 CPU/8Gi), `onlyoffice` (max 8 CPU/8Gi).

**Other mutating policies**: `inject-priority-class-from-tier` (sets priorityClassName, **CREATE only**), `inject-ndots` (ndots:2 on all pods), `sync-tier-label-from-namespace`, `goldilocks-vpa-auto-mode` (sets VPA to `off` for ALL namespaces — Terraform owns container resources, Goldilocks is observe-only).

**Goldilocks VPA**: VPA is in `off` mode globally — it provides resource recommendations only via the Goldilocks dashboard, but never mutates pods. Terraform is the sole authority for container resources.

**Security policies** (ALL Audit mode, log-only): `deny-privileged-containers`, `deny-host-namespaces`, `restrict-sys-admin`, `require-trusted-registries`.

**Debugging container failures checklist**:
1. **OOMKilled?** → Check `kubectl describe limitrange tier-defaults -n <ns>`. Containers without explicit resources get 256Mi limit in edge/aux tiers.
2. **Won't schedule?** → Check `kubectl describe resourcequota tier-quota -n <ns>`. Namespace may be at capacity.
3. **Evicted?** → aux-tier pods (priority 200K, Never preempt) are first evicted under pressure.
4. **Unexpected limits?** → LimitRange injects defaults when `resources: {}` or no resources block exists. Always set explicit resources.
5. **Need more?** → Set explicit `resources {}` on container (overrides LimitRange defaults) or add `resource-governance/custom-quota=true` label + `resource-governance/custom-limitrange=true` label with custom resources in the stack.
6. **Pod patch failing with immutable spec?** → Kyverno `inject-priority-class-from-tier` was fixed to CREATE-only. If similar issues arise, check mutating webhooks with `kubectl get mutatingwebhookconfigurations`.

---

## User Preferences
- **Calendar**: Nextcloud at `https://nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default) at `https://ha-london.viktorbarzin.me`, ha-sofia at `https://ha-sofia.viktorbarzin.me`. "ha"/"HA" = ha-london.
- **Frontend**: Svelte for all new web apps
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w` instead

---

## Reference Data
- `.claude/reference/service-catalog.md` — Full service catalog (70+ services) with Cloudflare domains
- `.claude/reference/proxmox-inventory.md` — VM table, hardware specs, network topology, GPU config
- `.claude/reference/github-api.md` — GitHub API patterns with curl examples
- `.claude/reference/authentik-state.md` — Current applications, groups, users, login sources

## Authentik (Identity Provider)
- **URL**: `https://authentik.viktorbarzin.me` | **API**: `/api/v3/` | **Token**: `authentik_api_token` in tfvars
- **Architecture**: 3 server + 3 worker + 3 PgBouncer + embedded outpost
- **Traefik integration**: Forward auth via `protected = true` in ingress_factory
- **OIDC for K8s**: Issuer `https://authentik.viktorbarzin.me/application/o/kubernetes/`, client `kubernetes` (public)
- For management tasks and OIDC gotchas: see `authentik` and `authentik-oidc-kubernetes` skills
