# NFS CSI Driver Migration: Inline Volumes → PV/PVC with Soft Mounts

**Date**: 2026-03-01
**Status**: Draft
**Complements**: `2026-02-28-storage-reliability-design.md` (databases → local disk)
**Goal**: Eliminate stale NFS mount hangs, add mount health checking, and create a storage abstraction layer for all NFS-dependent services

## Problem

56 services use inline NFS volumes (`nfs {}` in pod specs). This pattern has three compounding issues:

1. **Stale mounts hang forever**: Inline NFS defaults to `hard,timeo=600` mount options. When TrueNAS is unreachable (reboot, network blip, NFS export change), the kernel retries indefinitely. Pods show `Running 1/1` but are completely frozen with zero listening sockets. The only fix is force-deleting the pod.

2. **No mount health checking**: kubelet has no visibility into NFS mount health. Liveness probes only check application health, not filesystem access. A stale mount is invisible to the scheduler.

3. **No storage abstraction**: NFS server IP and export paths are hardcoded into every pod spec via `var.nfs_server`. Changing the backend (different NFS server, different protocol) requires editing 56 stacks.

## Constraints

- Zero data migration — same NFS paths, same TrueNAS server, same directories
- Services must keep working during migration (no downtime per service beyond a pod restart)
- Must work with existing Terragrunt architecture (per-stack state isolation)
- Must not break services that will later move to local disk (per storage-reliability design)

## Design

### Architecture

```
BEFORE:
  Pod spec → inline nfs {} block → kubelet mount -t nfs (hard,timeo=600) → TrueNAS
  (no health check, hangs on stale mount, server IP in every stack)

AFTER:
  Terraform module → PV (CSI driver ref) + PVC → Pod spec references PVC
  CSI driver mounts with soft,timeo=30,retrans=3 → TrueNAS
  (health-checked, fails fast on stale mount, server IP in module only)
```

### Component 1: NFS CSI Driver (Helm chart in platform stack)

Deploy `csi-driver-nfs` v4.11+ via Helm in `stacks/platform/modules/nfs-csi/`.

The driver runs as:
- **Controller**: 1 replica (handles PV provisioning)
- **Node DaemonSet**: 1 per node (handles mount/unmount operations)

Resource footprint: ~50MB RAM per node, ~10m CPU idle.

The driver itself does not change NFS behavior — it delegates to the kernel NFS client. The value is:
- Mount options are configurable per-StorageClass (not hardcoded kernel defaults)
- CSI health checking can detect unhealthy volumes
- Standard K8s storage API (PV/PVC/StorageClass) instead of inline volumes

### Component 2: StorageClass

```hcl
resource "kubernetes_storage_class" "nfs_truenas" {
  metadata { name = "nfs-truenas" }
  provisioner       = "nfs.csi.k8s.io"
  reclaim_policy    = "Retain"
  volume_binding_mode = "Immediate"

  mount_options = [
    "soft",       # Return -EIO instead of hanging forever
    "timeo=30",   # 3-second timeout per NFS RPC call
    "retrans=3",  # Retry 3 times before giving up (~9 sec total)
    "actimeo=5",  # 5-second attribute cache (balance freshness vs perf)
  ]

  parameters = {
    server = var.nfs_server
    share  = "/mnt/main"
  }
}
```

Key mount option differences vs current defaults:

| Option | Current (inline) | New (CSI) | Effect |
|--------|-----------------|-----------|--------|
| `hard` vs `soft` | `hard` (default) | `soft` | I/O errors instead of infinite hang |
| `timeo` | 600 (60 sec) | 30 (3 sec) | Faster failure detection |
| `retrans` | 3 | 3 | Same retry count, but 3s per attempt not 60s |
| `actimeo` | 3600 (1 hour, varies) | 5 (5 sec) | Fresher attribute cache |
| Total stale detection | **~3 minutes** | **~9 seconds** | 20x faster |

### Component 3: Shared Terraform Module (`modules/kubernetes/nfs_volume/`)

Creates a PV + PVC pair for each NFS mount point. Hides boilerplate.

**Interface**:
```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "myservice-data"       # PV and PVC name (must be unique cluster-wide)
  namespace  = "myservice"            # PVC namespace
  nfs_server = var.nfs_server         # From terraform.tfvars
  nfs_path   = "/mnt/main/myservice"  # NFS export path
  # Optional:
  # storage      = "10Gi"             # Default: 10Gi (informational for NFS)
  # access_modes = ["ReadWriteMany"]  # Default: RWX
}
```

**Outputs**:
- `claim_name` — PVC name to reference in pod spec

**Module creates**:
1. `kubernetes_persistent_volume` — CSI-backed, references StorageClass mount options
2. `kubernetes_persistent_volume_claim` — bound to the PV, namespaced

PVs are cluster-scoped, so `name` must be globally unique. Convention: `<service>-<purpose>` (e.g., `openclaw-tools`, `privatebin-data`).

### Component 4: Stack Migration (Mechanical Change)

Each stack changes from:
```hcl
# OLD: inline NFS
volume {
  name = "data"
  nfs {
    server = var.nfs_server
    path   = "/mnt/main/myservice"
  }
}
```

To:
```hcl
# NEW: module call (outside pod spec)
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "myservice-data"
  namespace  = "myservice"
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/myservice"
}

# NEW: PVC reference (in pod spec, replaces nfs {} block)
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = module.nfs_data.claim_name
  }
}
```

Volume mount blocks (`volume_mount {}`) are **completely unchanged**.

### Component 5: Platform Module Migration

Platform modules (redis, dbaas, monitoring, etc.) that use NFS follow the same pattern but the module path is `../../../modules/kubernetes/nfs_volume` (one extra level deep). The `nfs_server` variable is already passed through `stacks/platform/main.tf`.

Some platform modules use explicit PV/PVC already (Loki, Prometheus). These get updated to use the CSI driver backend instead of the native NFS PV source.

### What Does NOT Change

- NFS export paths on TrueNAS (no `nfs_directories.txt` changes)
- NFS server configuration
- Volume mount paths inside containers
- Sub-path usage patterns
- Container images or application config
- Services that will move to local disk later (per storage-reliability design) — they get CSI mounts as an interim improvement, then move off NFS entirely

## Migration Order

Services grouped by risk. Each batch: apply → verify pods running → verify app accessible → next batch.

### Phase 0: Infrastructure
1. Deploy NFS CSI driver Helm chart (platform module)
2. Create `nfs-truenas` StorageClass
3. Create `modules/kubernetes/nfs_volume/` shared module

### Phase 1: Low-Risk Pilot (3 services)
Pick 3 simple, single-volume services to validate the pattern:
- `privatebin` (1 volume, low traffic)
- `echo` — actually stateless, skip. Use `resume` instead (1 volume, personal site)
- `speedtest` (1 volume, low traffic)

### Phase 2: Simple Services (single NFS volume each, ~20 services)
Mechanical migration of all single-volume stacks. Can be parallelized.

### Phase 3: Multi-Volume Services (~15 services)
Services with 2-4 NFS volumes (openclaw, servarr, immich, etc.). More module calls but same pattern.

### Phase 4: Platform Modules (~9 modules)
Monitoring stack, Redis, dbaas PVs, etc. These live in `stacks/platform/modules/` and need the module path adjusted.

### Phase 5: Cleanup
- Update CLAUDE.md documentation (new NFS volume pattern)
- Update `setup-project` skill to use module pattern for new services
- Verify all services healthy

## Rollback

Per-service rollback: revert the stack to inline `nfs {}` and `terragrunt apply`. The data never moved — it's the same NFS path. PV/PVC objects get destroyed by Terraform, pod remounts inline. Takes 1 minute per service.

Full rollback: remove CSI driver and StorageClass from platform stack, revert all stacks. No data impact.

## Risks

1. **`soft` mount I/O errors**: Apps that don't handle I/O errors gracefully may crash instead of hanging. This is strictly better — a crash triggers a restart with a fresh mount, vs hanging forever. But some apps may log noisy errors during brief NFS blips.

2. **PV naming conflicts**: PV names are cluster-global. Must ensure uniqueness. Convention `<service>-<purpose>` handles this.

3. **Terraform state churn**: Each service gains 2 new resources (PV + PVC) and loses the inline volume (implicit, not tracked). The `terragrunt apply` will show resource additions but no deletions (inline volumes aren't separate TF resources). Pod will be recreated.

4. **CSI driver resource overhead**: ~50MB RAM + 10m CPU per node (5 nodes = ~250MB cluster-wide). Acceptable.

## Success Criteria

- [ ] NFS CSI driver deployed and healthy on all 5 nodes
- [ ] `nfs-truenas` StorageClass created with soft mount options
- [ ] `modules/kubernetes/nfs_volume/` module created and tested
- [ ] All 56 NFS-dependent services migrated from inline to PV/PVC
- [ ] No service downtime beyond a single pod restart during migration
- [ ] Simulated NFS outage (TrueNAS NFS service pause) results in pod restart (not hang)
- [ ] Documentation and skills updated for new pattern
