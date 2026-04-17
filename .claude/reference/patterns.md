# Detailed Infrastructure Patterns

Reference file for patterns, procedures, and tables. Read on demand when the specific topic comes up.

## NFS Volume Pattern
Use the `nfs_volume` shared module for all NFS volumes (creates static PVs, CSI-backed, `soft,timeo=30,retrans=3`):
```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"  # ../../../../ for platform modules, ../../../ for sub-stacks
  name       = "<service>-data"       # Must be globally unique (PV is cluster-scoped)
  namespace  = kubernetes_namespace.<service>.metadata[0].name
  nfs_server = var.nfs_server          # 192.168.1.127 (Proxmox host)
  nfs_path   = "/srv/nfs/<service>"    # HDD NFS, or "/srv/nfs-ssd/<service>" for SSD
}
# In pod spec: persistent_volume_claim { claim_name = module.nfs_data.claim_name }
```
**Note**: Some legacy PVs still reference `/mnt/main/<service>` paths (from the TrueNAS era). These work via compatibility on the Proxmox host. New PVs should use `/srv/nfs/` or `/srv/nfs-ssd/`.
**DO NOT use inline `nfs {}` blocks** — they mount with `hard,timeo=600` defaults which hang forever.

## Adding NFS Exports
1. Create dir on Proxmox host: `ssh root@192.168.1.127 "mkdir -p /srv/nfs/<service> && chmod 777 /srv/nfs/<service>"`
2. Edit `/etc/exports` on the Proxmox host — add the export entry
3. Reload exports: `ssh root@192.168.1.127 "exportfs -ra"`
4. Verify: `showmount -e 192.168.1.127`

## ~~iSCSI Storage~~ (REMOVED — replaced by proxmox-lvm)
> iSCSI via democratic-csi and TrueNAS has been fully removed (2026-04). All database storage now uses `StorageClass: proxmox-lvm` (Proxmox CSI, LVM-thin hotplug). TrueNAS has been decommissioned.

## Anti-AI Scraping (3 Active Layers) (Updated 2026-04-17)
Default `anti_ai_scraping = true` in ingress_factory. Disable per-service: `anti_ai_scraping = false`.
1. Bot blocking (ForwardAuth → poison-fountain) 2. X-Robots-Tag noai 3. Tarpit/poison content (standalone at poison.viktorbarzin.me)
Trap links (formerly layer 3) removed April 2026 — rewrite-body plugin broken on Traefik v3.6.12 (Yaegi bugs). `strip-accept-encoding` and `anti-ai-trap-links` middlewares deleted.
Rybbit analytics injection now via Cloudflare Worker (`stacks/rybbit/worker/`, HTMLRewriter, wildcard route `*.viktorbarzin.me/*`, 28 site ID mappings).
Key files: `stacks/poison-fountain/`, `stacks/rybbit/worker/`, `stacks/platform/modules/traefik/middleware.tf`

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
