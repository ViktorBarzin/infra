# Infrastructure Repository Knowledge

## Instructions for Claude
- **When the user says "remember" something**: Always update this file (`.claude/CLAUDE.md`) with the information so it persists across sessions
- **When discovering new patterns or versions**: Add them to the appropriate section below
- **When making infrastructure changes**: Always update this file to reflect the current state (new services, removed services, version changes, config changes)
- **After every significant change**: Proactively update this file (`.claude/CLAUDE.md`) to reflect what changed — new services, config changes, version bumps, new patterns, etc. This ensures knowledge persists across sessions automatically.
- **After updating any `.claude/` files**: Always commit them immediately (`git add .claude/ && git commit -m "[ci skip] update claude knowledge"`) to avoid building up unstaged changes.
- **Skills available**: Check `.claude/skills/` directory for specialized workflows (e.g., `setup-project` for deploying new services)
- **Reference data**: Check `.claude/reference/` for inventory tables, API patterns, and current state snapshots
- **CRITICAL: All infrastructure changes must go through Terraform/Terragrunt**. NEVER modify cluster resources directly (kubectl apply/edit/patch, helm install, docker run). Use `kubectl` only for read-only operations and ephemeral debugging.
- **CRITICAL: NEVER put sensitive data** (API keys, passwords, tokens, credentials) into committed files unless encrypted via git-crypt. Secrets belong in `terraform.tfvars` or `secrets/` directory.
- **CRITICAL: NEVER commit secrets** — triple-check before every commit. Zero exceptions.
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
**Prefer inline NFS volumes** over separate PV/PVC resources:
```hcl
volume {
  name = "data"
  nfs {
    server = "10.0.10.15"
    path   = "/mnt/main/<service>"
  }
}
```
Only use PV/PVC when a Helm chart requires `existingClaim`.

### Adding NFS Exports
1. Edit `secrets/nfs_directories.txt` — add path, keep sorted
2. Run `secrets/nfs_exports.sh` from `secrets/` to update TrueNAS

### Factory Pattern (multi-user services)
Structure: `stacks/<service>/main.tf` + `factory/main.tf`. Examples: `actualbudget`, `freedify`.
To add a user: export NFS share, add Cloudflare route in tfvars, add module block calling factory.

### SMTP/Email
- **Use**: `mail.viktorbarzin.me` port 587 (STARTTLS). **NOT** `mailserver.mailserver.svc.cluster.local` (TLS cert mismatch).
- **Credentials**: `mailserver_accounts` in tfvars. Common: `info@viktorbarzin.me`

### Anti-AI Scraping (5-Layer Defense)
All services have `anti_ai_scraping = true` by default in `ingress_factory`. Layers:
1. **Bot blocking** (`traefik-ai-bot-block`): ForwardAuth → poison-fountain `/auth`. Returns 403 for GPTBot, ClaudeBot, CCBot, etc.
2. **X-Robots-Tag** (`traefik-anti-ai-headers`): Adds `noai, noimageai`
3. **Trap links** (`traefik-anti-ai-trap-links`): rewrite-body injects 5 hidden links before `</body>` to `poison.viktorbarzin.me/article/*`
4. **Tarpit**: `/article/*` drip-feeds at ~100 bytes/sec
5. **Poison content**: 50 cached docs from rnsaffn.com/poison2/ (CronJob every 6h, `--http1.1` required)

Key files: `stacks/poison-fountain/`, `stacks/platform/modules/traefik/middleware.tf`, `modules/kubernetes/ingress_factory/main.tf`
Testing: `curl -s -H "Accept: text/html,application/xhtml+xml" https://vaultwarden.viktorbarzin.me/ | grep -oE 'href="https://poison[^"]*"'`
Disable per-service: `anti_ai_scraping = false` in ingress_factory call.

### Terragrunt Architecture
- Root `terragrunt.hcl` provides DRY provider, backend, and variable loading
- Each stack: `stacks/<service>/main.tf` with resources inline, state at `state/stacks/<service>/terraform.tfstate`
- Platform modules: `stacks/platform/modules/<service>/`, shared modules: `modules/kubernetes/`
- Dependencies via `dependency` block; variables from `terraform.tfvars` (unused silently ignored)
- `secrets/` symlinks in stacks for TLS cert path resolution
- Syntax: `--non-interactive` (not `--terragrunt-non-interactive`), `terragrunt run --all -- <command>` (not `run-all`)

### Adding a New Service
Use the **`setup-project`** skill for the full workflow. Quick reference:
1. Create `stacks/<service>/` with `terragrunt.hcl`, `main.tf`, `secrets` symlink
2. Add Cloudflare DNS in `terraform.tfvars`
3. Apply platform stack (for DNS): `cd stacks/platform && terragrunt apply --non-interactive`
4. Apply service: `cd stacks/<service> && terragrunt apply --non-interactive`

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
- NFS: `10.0.10.15`, Redis: `redis.redis.svc.cluster.local`
- Docker registry pull-through cache at `10.0.20.10` (ports 5000/5010/5020/5030/5040)
- GPU workloads need: `node_selector = { "gpu": "true" }` + `toleration { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }`

### Node Rebuild Procedure
To rebuild a K8s worker node from scratch (e.g., after disk failure or corruption):

1. **Drain the node** (if still reachable): `kubectl drain k8s-nodeX --ignore-daemonsets --delete-emptydir-data`
2. **Delete the node from K8s**: `kubectl delete node k8s-nodeX`
3. **Destroy the VM in Proxmox** (or via Terraform: remove from `stacks/infra/main.tf` and apply)
4. **Ensure K8s template exists**: The template `ubuntu-2404-cloudinit-k8s-template` (VMID 2000) must exist. If not, apply `stacks/infra/` to recreate it.
5. **Get a fresh join command**: `ssh wizard@10.0.20.100 'sudo kubeadm token create --print-join-command'`
6. **Update `k8s_join_command`** in `terraform.tfvars` with the new join command
7. **Create the new VM**: Add it back in `stacks/infra/main.tf` and `cd stacks/infra && terragrunt apply --non-interactive`
8. **Wait for cloud-init**: The VM will install packages, configure containerd mirrors, and join the cluster automatically via cloud-init
9. **Verify the node joined**: `kubectl get nodes` — should show the new node as `Ready`
10. **For GPU node (k8s-node1) only**: Apply the platform stack to re-apply GPU label and taint: `cd stacks/platform && terragrunt apply --non-interactive` (the `null_resource.gpu_node_config` in the nvidia module handles this)
11. **Verify containerd mirrors**: `ssh wizard@<node-ip> 'ls /etc/containerd/certs.d/'` — should show docker.io, ghcr.io, quay.io, registry.k8s.io, reg.kyverno.io

**Note**: kubeadm tokens expire after 24h by default. Generate a fresh one just before creating the VM.

## Git Operations
- **Git is slow** — commands can take 30+ seconds. Use `GIT_OPTIONAL_LOCKS=0` if git hangs.
- Commit only specific files. **ALWAYS ask user before pushing**.

## Prometheus Alerts
- Rules in `modules/kubernetes/monitoring/prometheus_chart_values.tpl`
- Groups: "R730 Host", "Nvidia Tesla T4 GPU", "Power", "Cluster"

## Tier System & Resource Governance
- **0-core**: Critical infra (ingress, DNS, VPN, auth) | **1-cluster**: Redis, metrics, security | **2-gpu**: GPU workloads | **3-edge**: User-facing | **4-aux**: Optional
- Kyverno-based governance in `modules/kubernetes/kyverno/resource-governance.tf`:
  1. PriorityClasses: `tier-0-core` (1M) through `tier-4-aux` (200K, preemption=Never)
  2. LimitRange defaults (Kyverno generate): auto-created per namespace tier
  3. ResourceQuotas (Kyverno generate): auto-created per namespace tier (skip with label `resource-governance/custom-quota=true`)
  4. Priority injection (Kyverno mutate): sets priorityClassName on Pods
- Custom quota override: monitoring, crowdsec, nvidia, realestate-crawler

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

---

## Service-Specific Notes

### Authentik (Identity Provider)
- **URL**: `https://authentik.viktorbarzin.me` | **API**: `/api/v3/` | **Token**: `authentik_api_token` in tfvars
- **Architecture**: 3 server + 3 worker + 3 PgBouncer + embedded outpost
- **Database**: PostgreSQL via `postgresql.dbaas:5432`, PgBouncer at `pgbouncer.authentik:6432`
- **Traefik integration**: Forward auth via `protected = true` in ingress_factory
- **OIDC for K8s**: Issuer `https://authentik.viktorbarzin.me/application/o/kubernetes/`, client `kubernetes` (public)
- For management tasks, current state, and OIDC gotchas: see `authentik` and `authentik-oidc-kubernetes` skills
- For current apps/groups/users snapshot: see `.claude/reference/authentik-state.md`

### AFFiNE (Visual Canvas)
- **Image**: `ghcr.io/toeverything/affine:stable` | **Port**: 3010 | **Requires**: PostgreSQL + Redis
- **Migration**: Init container runs `node ./scripts/self-host-predeploy.js`
- **Storage**: NFS `/mnt/main/affine` → `/root/.affine/storage` and `/root/.affine/config`

### Wyoming Whisper (STT)
- **Image**: `rhasspy/wyoming-whisper:latest` | **Port**: 10300/TCP (Wyoming protocol)
- **Model**: `small-int8` (CPU-only) | **Access**: `10.0.20.202:10300` (internal, no public DNS)
- **HA Integration**: Wyoming Protocol in ha-london

### Gramps Web (Genealogy)
- **Image**: `ghcr.io/gramps-project/grampsweb:latest` | **Port**: 5000 | **URL**: `https://family.viktorbarzin.me`
- **Components**: Web app + Celery worker (2 containers in 1 pod) | **Redis**: DB 2 (broker), DB 3 (rate limiting)
- **Storage**: NFS `/mnt/main/grampsweb` with sub_paths

### Loki + Alloy (Log Collection)
- **Loki**: `grafana/loki:3.6.5` (single binary, 6Gi RAM, 7d retention)
- **Alloy**: `grafana/alloy:v1.13.0` (DaemonSet, 128Mi/pod)
- **Storage**: NFS PV `/mnt/main/loki/loki` (15Gi), WAL on tmpfs (2Gi)
- **Alert rules**: HighErrorRate, PodCrashLoopBackOff, OOMKilled (ConfigMap `loki-alert-rules`)
- **Troubleshooting**: "entry too far behind" on first start → restart Alloy DaemonSet

### OpenClaw (AI Agent Gateway)
- **Image**: `ghcr.io/openclaw/openclaw:2026.2.9` | **Port**: 18789 | **URL**: `https://openclaw.viktorbarzin.me`
- **Init container**: Downloads kubectl, terraform, git-crypt; clones infra repo
- **ServiceAccount**: `openclaw` with `cluster-admin` ClusterRoleBinding
- **Model providers**: Gemini (gemini-2.5-flash), Ollama (qwen2.5-coder:14b, deepseek-r1:14b), Llama API

## Service Versions (as of 2026-02)
Immich v2.4.1 | AFFiNE stable | Whisper latest | Loki 3.6.5 | Alloy v1.13.0 | OpenClaw 2026.2.9
