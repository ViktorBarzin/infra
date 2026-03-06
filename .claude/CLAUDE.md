# Infrastructure Repository Knowledge

## Instructions
- **"remember X"**: Update this file, commit with `[ci skip]`
- **Skills**: `.claude/skills/` (7 active workflows). Archived runbooks in `.claude/skills/archived/`
- **Reference**: `.claude/reference/` — patterns.md (detailed procedures), service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **Agents**: `.claude/agents/` — `cluster-health-checker` (haiku, autonomous health checks)

## Critical Rules
- **ALL changes through Terraform/Terragrunt** — never `kubectl apply/edit/patch` directly
- **NEVER put secrets in committed files** — use `terraform.tfvars` or `secrets/` (git-crypt)
- **NEVER restart NFS on TrueNAS** — causes cluster-wide mount failures
- **NEVER commit secrets** — triple-check every commit
- **New services need CI/CD** (Woodpecker) and **monitoring** (Prometheus/Uptime Kuma)
- **ALWAYS `[ci skip]`** in commit messages when already applied locally
- **Ask before pushing** to git. Commit specific files, not `git add -A`

## Execution
- **Terragrunt**: `cd stacks/<service> && terragrunt apply --non-interactive`
- **kubectl**: `kubectl --kubeconfig $(pwd)/config`
- **Health check**: `bash scripts/cluster_healthcheck.sh --quiet`
- **Plan all**: `cd stacks && terragrunt run --all --non-interactive -- plan`
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)

## Overview
Terragrunt-based homelab managing K8s cluster on Proxmox. Per-service stacks under `stacks/`. Git-crypt for secrets.
- **Public domain**: `viktorbarzin.me` (Cloudflare) | **Internal**: `viktorbarzin.lan` (Technitium DNS)
- **Cluster**: 5 nodes (master + node1-4, v1.34.2), GPU on node1 (Tesla T4)
- **CI/CD**: Woodpecker CI — pushes to master auto-apply platform stack

## Key Paths
- `terraform.tfvars` — secrets, DNS, Cloudflare (git-crypt)
- `stacks/<service>/` — individual stacks | `stacks/platform/modules/` — core infra (~22 modules)
- `modules/kubernetes/ingress_factory/`, `nfs_volume/`, `setup_tls_secret/` — shared modules

## Quick Patterns
- **NFS volumes**: Use `nfs_volume` module (see `reference/patterns.md`). StorageClass: `nfs-truenas`. Never use inline `nfs {}` blocks.
- **iSCSI (databases)**: StorageClass `iscsi-truenas` (democratic-csi). Used by PostgreSQL, MySQL.
- **SMTP**: `var.mail_host` port 587 STARTTLS. NOT `mailserver.mailserver.svc.cluster.local` (cert mismatch).
- **New service**: Use `setup-project` skill. Quick: create stack → add DNS in tfvars → apply platform → apply service.
- **Ingress**: `ingress_factory` module. Auth: `protected = true`. Anti-AI: on by default.

## Shared Variables (never hardcode)
`var.nfs_server` (10.0.10.15), `var.redis_host`, `var.postgresql_host`, `var.mysql_host`, `var.ollama_host`, `var.mail_host`

## Infrastructure
- Proxmox (192.168.1.127) — see `reference/proxmox-inventory.md`
- Pull-through cache at `10.0.20.10` — docker.io (:5000) and ghcr.io (:5010) only
- GPU: `node_selector = { "gpu": "true" }` + `toleration { key = "nvidia.com/gpu", value = "true", effect = "NoSchedule" }`
- Node rebuild: see `reference/patterns.md`

## Tier System
`0-core` (ingress, DNS, VPN, auth) | `1-cluster` (Redis, metrics) | `2-gpu` | `3-edge` (user-facing) | `4-aux` (optional)
- Auto-generated into `tiers.tf` — use `local.tiers.core`, `local.tiers.cluster`, etc.
- Kyverno governance: LimitRange defaults + ResourceQuota per namespace (see `reference/patterns.md`)
- **OOMKilled?** → Container without explicit resources gets 256Mi (edge/aux). Set explicit `resources {}`.
- **Won't schedule?** → Check `kubectl describe resourcequota tier-quota -n <ns>`
- **Opt-out**: labels `resource-governance/custom-quota=true` and/or `resource-governance/custom-limitrange=true`

## MySQL InnoDB Cluster (dbaas namespace)
- 3 instances on `iscsi-truenas`, anti-affinity excludes k8s-node2 (SIGBUS in init containers)
- `mysql` service selector includes `mysql.oracle.com/cluster-role: PRIMARY`
- GR bootstrap: `SET GLOBAL group_replication_bootstrap_group=ON; START GROUP_REPLICATION;`
- Service users NOT managed by Terraform — recreate manually after cluster rebuild
- `manualStartOnBoot: true` — GR doesn't auto-start, needs bootstrap after full restart

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
