# Infrastructure Repository — AI Agent Instructions

## Critical Rules (MUST FOLLOW)
- **ALL changes through Terraform/Terragrunt** — NEVER `kubectl apply/edit/patch/delete` for persistent changes. Read-only kubectl is fine.
- **NEVER put secrets in plaintext** — use `secrets.sops.json` (SOPS-encrypted) or `terraform.tfvars` (git-crypt, legacy)
- **NEVER restart NFS on Proxmox host or TrueNAS** — causes cluster-wide mount failures across all pods
- **NEVER commit secrets** — triple-check before every commit
- **`[ci skip]` in commit messages** when changes were already applied locally
- **Ask before `git push`** — always confirm with the user first

## Execution
- **Apply a service**: `scripts/tg apply --non-interactive` (auto-decrypts SOPS secrets)
- **Legacy apply**: `cd stacks/<service> && terragrunt apply --non-interactive` (uses terraform.tfvars)
- **kubectl**: `kubectl --kubeconfig $(pwd)/config`
- **Health check**: `bash scripts/cluster_healthcheck.sh --quiet`
- **Plan all**: `cd stacks && terragrunt run --all --non-interactive -- plan`

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
- `modules/kubernetes/ingress_factory/` — standardized ingress with auth, rate limiting, anti-AI
- `modules/kubernetes/nfs_volume/` — NFS volume module (CSI-backed, soft mount)
- `config.tfvars` — non-secret configuration (plaintext)
- `secrets.sops.json` — all secrets (SOPS-encrypted JSON)
- `terraform.tfvars` — legacy secrets file (git-crypt, kept for reference)
- `scripts/cluster_healthcheck.sh` — 25-check cluster health script

## Storage
- **NFS — Proxmox host** (primary): HDD pool at `/srv/nfs` (ext4 thin LV `pve/nfs-data`, 1TB) and SSD pool at `/srv/nfs-ssd` (ext4 LV `ssd/nfs-ssd-data`, 100GB) on 192.168.1.127. Serves all workloads except Immich.
  - `nfs-proxmox` StorageClass: Dynamic provisioning (Vault uses this).
  - `nfs_volume` module: Static PVs for most services. Use this, never inline `nfs {}` blocks.
- **NFS — TrueNAS** (10.0.10.15): Now **only serves Immich** (8 PVCs). `nfs-truenas` StorageClass retained for Immich only.
- **proxmox-lvm** (`proxmox-lvm` StorageClass): For databases (PostgreSQL, MySQL). TopoLVM driver.
- **SQLite on NFS is unreliable** (fsync issues) — always use proxmox-lvm or local disk for databases.
- **NFS mount options**: Always `soft,timeo=30,retrans=3` to prevent uninterruptible sleep (D state).
- **NFS export directory must exist** on the NFS server before Terraform can create the PV.
- **NFS `insecure` option**: Required on Proxmox host exports — pfSense NATs source ports >1024 when routing between VLANs, which NFS `secure` mode rejects.
- **CSI PV volumeAttributes are immutable**: Can't update NFS server in place. Must create new PV/PVC pairs (pattern: append `-host` to PV name).

## Shared Variables (never hardcode)
`var.nfs_server` (192.168.1.127 — Proxmox host), `var.nfs_server_truenas` (10.0.10.15 — Immich only), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Tier System
`0-core` | `1-cluster` | `2-gpu` | `3-edge` | `4-aux` — Kyverno auto-generates LimitRange + ResourceQuota per namespace based on tier label.
- Containers without explicit `resources {}` get default limits (256Mi for edge/aux — causes OOMKill for heavy apps)
- Always set explicit resources on containers that need more than defaults
- Opt-out: labels `resource-governance/custom-quota=true` / `resource-governance/custom-limitrange=true`

## Infrastructure
- **Proxmox**: 192.168.1.127 (Dell R730, 22c/44t, 142GB RAM)
- **Nodes**: k8s-master (10.0.20.100), node1 (GPU, Tesla T4), node2-4
- **GPU**: `node_selector = { "gpu": "true" }` + toleration `nvidia.com/gpu`
- **Pull-through cache**: 10.0.20.10 — docker.io (:5000), ghcr.io (:5010) only. Caches stale manifests for :latest tags — use versioned tags or pre-pull with `ctr --hosts-dir ''` to bypass.
- **pfSense**: 10.0.20.1 (gateway, firewall, DNS forwarding)
- **MySQL InnoDB Cluster**: 3 instances on proxmox-lvm, anti-affinity excludes k8s-node1 (GPU node)
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
- **NFS exports**: Create dir on Proxmox host (`/srv/nfs/<dir>` or `/srv/nfs-ssd/<dir>`). For Immich (TrueNAS only): add to `secrets/nfs_directories.txt`, run `secrets/nfs_exports.sh`.

## Detailed Reference
See `.claude/reference/patterns.md` for: NFS volume code examples, iSCSI details, Kyverno governance tables, anti-AI scraping layers, Terragrunt architecture, node rebuild procedure, archived troubleshooting runbooks index.
