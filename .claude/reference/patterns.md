# Detailed Infrastructure Patterns

Reference file for patterns, procedures, and tables. Read on demand when the specific topic comes up.

## NFS Volume Pattern
Use the `nfs_volume` shared module for all NFS volumes (CSI-backed, `soft,timeo=30,retrans=3`):
```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"  # ../../../../ for platform modules, ../../../ for sub-stacks
  name       = "<service>-data"       # Must be globally unique (PV is cluster-scoped)
  namespace  = kubernetes_namespace.<service>.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/<service>"
}
# In pod spec: persistent_volume_claim { claim_name = module.nfs_data.claim_name }
```
**DO NOT use inline `nfs {}` blocks** — they mount with `hard,timeo=600` defaults which hang forever.

## Adding NFS Exports
1. Create dir on TrueNAS: `ssh root@10.0.10.15 "mkdir -p /mnt/main/<service> && chmod 777 /mnt/main/<service>"`
2. Edit `secrets/nfs_directories.txt` — add path, keep sorted
3. Run `secrets/nfs_exports.sh` from `secrets/`
4. If any path doesn't exist on TrueNAS, the API rejects the entire update.

## iSCSI Storage (Databases)
**StorageClass**: `iscsi-truenas` (democratic-csi, `freenas-iscsi` SSH driver — NOT `freenas-api-iscsi`).
Used by: PostgreSQL (CNPG), MySQL (InnoDB Cluster). ZFS: `main/iscsi` (zvols), `main/iscsi-snaps`.
All K8s nodes have `open-iscsi` + `iscsid` running.

## Anti-AI Scraping (5-Layer Defense)
Default `anti_ai_scraping = true` in ingress_factory. Disable per-service: `anti_ai_scraping = false`.
1. Bot blocking (ForwardAuth → poison-fountain) 2. X-Robots-Tag noai 3. Trap links before `</body>`
4. Tarpit (~100 bytes/sec) 5. Poison content (CronJob every 6h, `--http1.1` required)
Key files: `stacks/poison-fountain/`, `stacks/platform/modules/traefik/middleware.tf`

## Terragrunt Architecture
- Root `terragrunt.hcl`: DRY providers, backend, variable loading, `generate "tiers"` block
- Each stack: `stacks/<service>/main.tf`, state at `state/stacks/<service>/terraform.tfstate`
- Platform modules: `stacks/platform/modules/<service>/`, shared: `modules/kubernetes/`
- Syntax: `--non-interactive`, `terragrunt run --all -- <command>` (not `run-all`)
- Tiers auto-generated into `tiers.tf` — never add `locals { tiers = {} }` manually

## Factory Pattern (Multi-User Services)
Structure: `stacks/<service>/main.tf` + `factory/main.tf`. Examples: `actualbudget`, `freedify`.
To add a user: export NFS share, add Cloudflare route in tfvars, add module block calling factory.

## Node Rebuild Procedure
1. Drain: `kubectl drain k8s-nodeX --ignore-daemonsets --delete-emptydir-data`
2. Delete: `kubectl delete node k8s-nodeX`
3. Destroy VM (remove from `stacks/infra/main.tf`)
4. Get fresh join command: `ssh wizard@10.0.20.100 'sudo kubeadm token create --print-join-command'` (tokens expire 24h)
5. Update `k8s_join_command` in `terraform.tfvars`, add VM to `stacks/infra/main.tf`, apply
6. GPU node (k8s-node1): apply platform stack to re-apply GPU label/taint

## Kyverno Resource Governance

### LimitRange Defaults (injected when no explicit `resources {}`)
| Tier | Default Mem | Max Mem | Default CPU | Max CPU |
|------|------------|---------|-------------|---------|
| 0-core | 512Mi | 8Gi | 500m | 4 |
| 1-cluster | 512Mi | 4Gi | 500m | 2 |
| 2-gpu | 2Gi | 16Gi | 1 | 8 |
| 3-edge / 4-aux | 256Mi | 4Gi | 250m | 2 |
| No tier | 256Mi | 2Gi | 250m | 1 |

### ResourceQuota (opt-out: `resource-governance/custom-quota=true`)
| Tier | lim CPU | lim Mem | Pods |
|------|---------|---------|------|
| 0-core | 32 | 64Gi | 100 |
| 1-cluster | 16 | 32Gi | 30 |
| 2-gpu | 48 | 96Gi | 40 |
| 3-edge / 4-aux | 8-16 | 16-32Gi | 20-30 |

Custom quotas: authentik, monitoring (opted out), nvidia (opted out), nextcloud, onlyoffice.
LimitRange opt-out: `resource-governance/custom-limitrange=true` + custom `kubernetes_limit_range` in stack.

### Other Policies
- `inject-priority-class-from-tier` (CREATE only), `inject-ndots` (ndots:2), `sync-tier-label`
- `goldilocks-vpa-auto-mode`: VPA `off` globally — Terraform owns resources, Goldilocks observe-only
- Security policies ALL Audit mode: `deny-privileged-containers`, `deny-host-namespaces`, `restrict-sys-admin`, `require-trusted-registries`

### Debugging Container Failures
1. **OOMKilled?** → `kubectl describe limitrange tier-defaults -n <ns>`. edge/aux default = 256Mi.
2. **Won't schedule?** → `kubectl describe resourcequota tier-quota -n <ns>`.
3. **Evicted?** → aux-tier pods (priority 200K, Never preempt) evicted first.
4. **Unexpected limits?** → LimitRange injects defaults. Always set explicit resources.
5. **Need more?** → Set explicit `resources {}` or add quota/limitrange opt-out labels.

## Authentik (Identity Provider)
- **URL**: `https://authentik.viktorbarzin.me` | **API**: `/api/v3/` | **Token**: `authentik_api_token` in tfvars
- 3 server + 3 worker + 3 PgBouncer + embedded outpost
- Forward auth: `protected = true` in ingress_factory
- OIDC for K8s: issuer `.../application/o/kubernetes/`, client `kubernetes` (public)
- See archived skills for management tasks and OIDC gotchas

## Archived Troubleshooting Runbooks
28 skills in `.claude/skills/archived/` — load when the specific issue arises.
Topics: authentik, bluestacks, clickhouse-nfs, coturn, crowdsec, fastapi-svelte-gpu,
grafana-datasource, helm-stuck, ingress-migration, image-caching, gpu-devices, hpa-storm,
nfs-mount, kubelet-manifest, llm-gpu, loki-helm, librespot, nextcloud-calendar, nfsv4-idmapd,
openclaw-deploy, pfsense-dnsmasq, pfsense-nat, proxmox-disk, python-sanitize, terraform-state,
traefik-helm, traefik-rewrite-body.
