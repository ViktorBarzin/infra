# Infrastructure Repository — AI Agent Instructions

## Critical Rules (MUST FOLLOW)
- **ALL changes through Terraform/Terragrunt** — NEVER `kubectl apply/edit/patch/delete` for persistent changes. Read-only kubectl is fine.
- **NEVER put secrets in committed files** — use `terraform.tfvars` or `secrets/` (git-crypt encrypted)
- **NEVER restart NFS on TrueNAS** — causes cluster-wide mount failures across all pods
- **NEVER commit secrets** — triple-check before every commit
- **`[ci skip]` in commit messages** when changes were already applied locally
- **Ask before `git push`** — always confirm with the user first

## Execution
- **Apply a service**: `cd stacks/<service> && terragrunt apply --non-interactive`
- **kubectl**: `kubectl --kubeconfig $(pwd)/config`
- **Health check**: `bash scripts/cluster_healthcheck.sh --quiet`
- **Plan all**: `cd stacks && terragrunt run --all --non-interactive -- plan`

## Architecture
Terragrunt-based homelab managing a Kubernetes cluster (5 nodes, v1.34.2) on Proxmox VMs.
- **70+ services**, each in `stacks/<service>/` with its own Terraform state
- **Core platform**: `stacks/platform/modules/` (~22 modules: Traefik, Kyverno, monitoring, dbaas, etc.)
- **Public domain**: `viktorbarzin.me` (Cloudflare) | **Internal**: `viktorbarzin.lan` (Technitium DNS)
- **Secrets**: `terraform.tfvars` (git-crypt encrypted)

## Key Paths
- `stacks/<service>/main.tf` — service definition
- `stacks/platform/modules/<service>/` — core infra modules
- `modules/kubernetes/ingress_factory/` — standardized ingress with auth, rate limiting, anti-AI
- `modules/kubernetes/nfs_volume/` — NFS volume module (CSI-backed, soft mount)
- `terraform.tfvars` — all secrets, DNS config, shared variables
- `scripts/cluster_healthcheck.sh` — 25-check cluster health script

## Storage
- **NFS** (`nfs-truenas` StorageClass): For app data. Use the `nfs_volume` module, never inline `nfs {}` blocks.
- **iSCSI** (`iscsi-truenas` StorageClass): For databases (PostgreSQL, MySQL). democratic-csi driver.
- **TrueNAS**: 10.0.10.15. NFS exports managed via `secrets/nfs_exports.sh`.

## Shared Variables (never hardcode)
`var.nfs_server` (10.0.10.15), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Tier System
`0-core` | `1-cluster` | `2-gpu` | `3-edge` | `4-aux` — Kyverno auto-generates LimitRange + ResourceQuota per namespace based on tier label.
- Containers without explicit `resources {}` get default limits (256Mi for edge/aux — causes OOMKill for heavy apps)
- Always set explicit resources on containers that need more than defaults
- Opt-out: labels `resource-governance/custom-quota=true` / `resource-governance/custom-limitrange=true`

## Infrastructure
- **Proxmox**: 192.168.1.127 (Dell R730, 22c/44t, 142GB RAM)
- **Nodes**: k8s-master (10.0.20.100), node1 (GPU, Tesla T4), node2-4
- **GPU**: `node_selector = { "gpu": "true" }` + toleration `nvidia.com/gpu`
- **Pull-through cache**: 10.0.20.10 — docker.io (:5000), ghcr.io (:5010) only
- **pfSense**: 10.0.20.1 (gateway, firewall, DNS forwarding)
- **MySQL InnoDB Cluster**: 3 instances on iSCSI, anti-affinity excludes node2 (SIGBUS bug)
- **SMTP**: `var.mail_host` port 587 STARTTLS (not internal svc address — cert mismatch)

## Common Operations
- **Deploy new service**: Use `stacks/<existing-service>/` as template. Create stack, add DNS in tfvars, apply platform then service.
- **Fix crashed pods**: Run healthcheck first. Safe to delete evicted/failed pods and CrashLoopBackOff pods with >10 restarts.
- **OOMKilled**: Check `kubectl describe limitrange tier-defaults -n <ns>`. Increase `resources.limits.memory` in the stack's main.tf.
- **Helm stuck**: If Helm release is in `pending-upgrade`/`failed`, check `reference/patterns.md` for recovery.
- **NFS exports**: Create dir on TrueNAS first, add to `secrets/nfs_directories.txt`, run `secrets/nfs_exports.sh`.

## Detailed Reference
See `.claude/reference/patterns.md` for: NFS volume code examples, iSCSI details, Kyverno governance tables, anti-AI scraping layers, Terragrunt architecture, node rebuild procedure, archived troubleshooting runbooks index.
