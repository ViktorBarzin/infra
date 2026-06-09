# NFS CSI Driver Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace all inline NFS volumes with CSI-backed PV/PVC using soft mount options to eliminate stale mount hangs.

**Architecture:** Deploy the NFS CSI driver as a platform Helm module, create a shared Terraform module for PV/PVC boilerplate, then mechanically migrate all 56 NFS-dependent services from inline `nfs {}` to `persistent_volume_claim {}` referencing the shared module.

**Tech Stack:** csi-driver-nfs (Helm), Terraform/Terragrunt, Kubernetes PV/PVC/StorageClass

**Design doc:** `docs/plans/2026-03-01-nfs-csi-migration-design.md`

---

## Task 1: Create the NFS CSI Driver Platform Module

**Files:**
- Create: `stacks/platform/modules/nfs-csi/main.tf`
- Modify: `stacks/platform/main.tf` (add module block)

**Step 1: Create the module directory**

```bash
mkdir -p stacks/platform/modules/nfs-csi
```

**Step 2: Write the NFS CSI module**

Create `stacks/platform/modules/nfs-csi/main.tf`:

```hcl
variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "nfs_csi" {
  metadata {
    name = "nfs-csi"
    labels = {
      tier = var.tier
    }
  }
}

resource "helm_release" "nfs_csi_driver" {
  namespace        = kubernetes_namespace.nfs_csi.metadata[0].name
  create_namespace = false
  name             = "csi-driver-nfs"
  atomic           = true
  timeout          = 300

  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"

  values = [yamlencode({
    controller = {
      replicas = 1
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
    node = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
    storageClass = {
      create = false  # We create it ourselves below for full control
    }
  })]
}

resource "kubernetes_storage_class" "nfs_truenas" {
  metadata {
    name = "nfs-truenas"
  }
  storage_provisioner = "nfs.csi.k8s.io"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  mount_options = [
    "soft",
    "timeo=30",
    "retrans=3",
    "actimeo=5",
  ]

  parameters = {
    server = var.nfs_server
    share  = "/mnt/main"
  }
}
```

**Step 3: Wire the module into `stacks/platform/main.tf`**

Add after the `cnpg` module block (around line 318):

```hcl
module "nfs-csi" {
  source     = "./modules/nfs-csi"
  tier       = local.tiers.cluster
  nfs_server = var.nfs_server
}
```

**Step 4: Verify with plan**

```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | head -80
```

Expected: Plan shows 3 new resources (`kubernetes_namespace`, `helm_release`, `kubernetes_storage_class`). No changes to existing resources.

**Step 5: Apply**

```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 6: Verify CSI driver is running**

```bash
kubectl --kubeconfig $(pwd)/config get pods -n nfs-csi
kubectl --kubeconfig $(pwd)/config get storageclass nfs-truenas
```

Expected: Controller pod + node DaemonSet pods (5 total) all Running. StorageClass `nfs-truenas` exists with provisioner `nfs.csi.k8s.io`.

**Step 7: Commit**

```bash
git add stacks/platform/modules/nfs-csi/ stacks/platform/main.tf
git commit -m "[ci skip] add NFS CSI driver platform module with nfs-truenas StorageClass"
```

---

## Task 2: Create the Shared `nfs_volume` Module

**Files:**
- Create: `modules/kubernetes/nfs_volume/main.tf`

**Step 1: Write the module**

Create `modules/kubernetes/nfs_volume/main.tf`:

```hcl
variable "name" {
  description = "Unique name for PV and PVC (convention: <service>-<purpose>)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the PVC"
  type        = string
}

variable "nfs_server" {
  description = "NFS server address"
  type        = string
}

variable "nfs_path" {
  description = "NFS export path (e.g. /mnt/main/myservice)"
  type        = string
}

variable "storage" {
  description = "Storage capacity (informational for NFS)"
  type        = string
  default     = "10Gi"
}

variable "access_modes" {
  description = "PV/PVC access modes"
  type        = list(string)
  default     = ["ReadWriteMany"]
}

resource "kubernetes_persistent_volume" "this" {
  metadata {
    name = var.name
  }
  spec {
    capacity = {
      storage = var.storage
    }
    access_modes                     = var.access_modes
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "nfs-truenas"
    volume_mode                      = "Filesystem"

    persistent_volume_source {
      csi {
        driver        = "nfs.csi.k8s.io"
        volume_handle = var.name
        volume_attributes = {
          server = var.nfs_server
          share  = var.nfs_path
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }
  spec {
    access_modes       = var.access_modes
    storage_class_name = "nfs-truenas"
    volume_name        = kubernetes_persistent_volume.this.metadata[0].name

    resources {
      requests = {
        storage = var.storage
      }
    }
  }
}

output "claim_name" {
  description = "PVC name to use in pod spec persistent_volume_claim blocks"
  value       = kubernetes_persistent_volume_claim.this.metadata[0].name
}
```

**Step 2: Format**

```bash
terraform fmt modules/kubernetes/nfs_volume/main.tf
```

**Step 3: Commit**

```bash
git add modules/kubernetes/nfs_volume/
git commit -m "[ci skip] add shared nfs_volume module for CSI-backed PV/PVC creation"
```

---

## Task 3: Pilot Migration — `privatebin`

**Files:**
- Modify: `stacks/privatebin/main.tf`

This is the first real migration. Validates the pattern end-to-end.

**Step 1: Read current state**

Current NFS volume in `stacks/privatebin/main.tf`:

```hcl
# Lines 71-77 — volume block in pod spec
volume {
  name = "data"
  nfs {
    path   = "/mnt/main/privatebin"
    server = var.nfs_server
  }
}
```

Volume mount (lines 54-58, UNCHANGED):
```hcl
volume_mount {
  name       = "data"
  mount_path = "/srv/data"
  sub_path   = "data"
}
```

**Step 2: Add module call**

Add before the `kubernetes_deployment` resource (e.g., after the ingress_factory module, before the deployment):

```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "privatebin-data"
  namespace  = kubernetes_namespace.privatebin.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/privatebin"
}
```

**Step 3: Replace inline NFS volume with PVC reference**

Replace the volume block (lines 71-77):

```hcl
# OLD:
volume {
  name = "data"
  nfs {
    path   = "/mnt/main/privatebin"
    server = var.nfs_server
  }
}

# NEW:
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = module.nfs_data.claim_name
  }
}
```

Do NOT touch the `volume_mount` block — it stays identical.

**Step 4: Plan and verify**

```bash
cd stacks/privatebin && terragrunt plan --non-interactive
```

Expected: 2 resources added (PV + PVC), deployment updated in-place (volume source changed). No resources destroyed (inline volumes aren't tracked as separate TF resources).

**Step 5: Apply**

```bash
cd stacks/privatebin && terragrunt apply --non-interactive
```

**Step 6: Verify the pod is running with CSI mount**

```bash
kubectl --kubeconfig $(pwd)/config get pods -n privatebin
kubectl --kubeconfig $(pwd)/config describe pod -n privatebin -l app=privatebin | grep -A5 "Volumes:"
```

Expected: Pod running. Volume shows `Type: PersistentVolumeClaim` with `ClaimName: privatebin-data`, NOT `Type: NFS`.

**Step 7: Verify the app works**

```bash
curl -sI https://privatebin.viktorbarzin.me | head -5
```

Expected: HTTP 200 (or 302 redirect to the paste page).

**Step 8: Verify mount options**

```bash
# SSH to the node running the pod and check mount options
NODE=$(kubectl --kubeconfig $(pwd)/config get pod -n privatebin -l app=privatebin -o jsonpath='{.items[0].spec.nodeName}')
ssh wizard@$(kubectl --kubeconfig $(pwd)/config get node $NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}') "mount | grep privatebin"
```

Expected: Mount shows `soft,timeo=30,retrans=3,actimeo=5` (NOT the old `hard` default).

**Step 9: Commit**

```bash
cd /Users/viktorbarzin/code/infra
git add stacks/privatebin/main.tf
git commit -m "[ci skip] privatebin: migrate NFS volume to CSI-backed PV/PVC with soft mount"
```

---

## Task 4: Pilot Migration — `resume`

**Files:**
- Modify: `stacks/resume/main.tf`

Same pattern as privatebin. Single NFS volume.

**Step 1: Add module call**

Add before the `kubernetes_deployment.resume` resource:

```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "resume-data"
  namespace  = kubernetes_namespace.resume.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/resume"
}
```

**Step 2: Replace inline NFS volume with PVC reference**

In the `resume` deployment's pod spec, replace:

```hcl
# OLD:
volume {
  name = "data"
  nfs {
    server = var.nfs_server
    path   = "/mnt/main/resume"
  }
}

# NEW:
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = module.nfs_data.claim_name
  }
}
```

**Step 3: Plan, apply, verify**

```bash
cd stacks/resume && terragrunt plan --non-interactive
cd stacks/resume && terragrunt apply --non-interactive
kubectl --kubeconfig $(pwd)/config get pods -n resume
curl -sI https://resume.viktorbarzin.me | head -5
```

**Step 4: Commit**

```bash
cd /Users/viktorbarzin/code/infra
git add stacks/resume/main.tf
git commit -m "[ci skip] resume: migrate NFS volume to CSI-backed PV/PVC with soft mount"
```

---

## Task 5: Pilot Migration — `speedtest`

**Files:**
- Modify: `stacks/speedtest/main.tf`

**Step 1: Add module call**

```hcl
module "nfs_config" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "speedtest-config"
  namespace  = kubernetes_namespace.speedtest.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/speedtest"
}
```

**Step 2: Replace inline NFS volume**

```hcl
# OLD:
volume {
  name = "config"
  nfs {
    server = var.nfs_server
    path   = "/mnt/main/speedtest"
  }
}

# NEW:
volume {
  name = "config"
  persistent_volume_claim {
    claim_name = module.nfs_config.claim_name
  }
}
```

**Step 3: Plan, apply, verify**

```bash
cd stacks/speedtest && terragrunt plan --non-interactive
cd stacks/speedtest && terragrunt apply --non-interactive
kubectl --kubeconfig $(pwd)/config get pods -n speedtest
curl -sI https://speedtest.viktorbarzin.me | head -5
```

**Step 4: Commit**

```bash
cd /Users/viktorbarzin/code/infra
git add stacks/speedtest/main.tf
git commit -m "[ci skip] speedtest: migrate NFS volume to CSI-backed PV/PVC with soft mount"
```

---

## Task 6: Batch Migration — Simple Single-Volume Stacks

After pilots are verified, migrate the remaining single-volume stacks. These all follow the exact same mechanical pattern.

**Files to modify** (one `main.tf` each — apply and verify each individually):

| Stack | Volume Name | PV Name | NFS Path |
|-------|------------|---------|----------|
| `audiobookshelf` | `data` | `audiobookshelf-data` | `/mnt/main/audiobookshelf` |
| `calibre` | `data` | `calibre-data` | `/mnt/main/calibre-web-automated` |
| `changedetection` | `data` | `changedetection-data` | `/mnt/main/changedetection` |
| `diun` | `data` | `diun-data` | `/mnt/main/diun` |
| `excalidraw` | `data` | `excalidraw-data` | `/mnt/main/excalidraw` |
| `forgejo` | `data` | `forgejo-data` | `/mnt/main/forgejo` |
| `freshrss` | `data` | `freshrss-data` | `/mnt/main/freshrss` |
| `hackmd` | `data` | `hackmd-data` | `/mnt/main/hackmd` |
| `health` | `data` | `health-data` | `/mnt/main/health` |
| `isponsorblocktv` | `data` | `isponsorblocktv-data` | `/mnt/main/isponsorblocktv` |
| `meshcentral` | `data` | `meshcentral-data` | `/mnt/main/meshcentral` |
| `n8n` | `data` | `n8n-data` | `/mnt/main/n8n` |
| `navidrome` | `data` | `navidrome-data` | `/mnt/main/navidrome` |
| `netbox` | `data` | `netbox-data` | `/mnt/main/netbox` |
| `ntfy` | `data` | `ntfy-data` | `/mnt/main/ntfy` |
| `onlyoffice` | `data` | `onlyoffice-data` | `/mnt/main/onlyoffice` |
| `owntracks` | `data` | `owntracks-data` | `/mnt/main/owntracks` |
| `privatebin` | _(done in Task 3)_ | | |
| `resume` | _(done in Task 4)_ | | |
| `send` | `data` | `send-data` | `/mnt/main/send` |
| `speedtest` | _(done in Task 5)_ | | |
| `tandoor` | `data` | `tandoor-data` | `/mnt/main/tandoor` |
| `wealthfolio` | `data` | `wealthfolio-data` | `/mnt/main/wealthfolio` |
| `whisper` | `data` | `whisper-data` | `/mnt/main/whisper` |
| `atuin` | `data` | `atuin-data` | `/mnt/main/atuin` |
| `matrix` | `data` | `matrix-data` | `/mnt/main/matrix` |
| `ollama` | `data` | `ollama-data` | `/mnt/main/ollama` |
| `poison-fountain` | `data` | `poison-fountain-data` | `/mnt/main/poison-fountain` |
| `woodpecker` | `data` | `woodpecker-data` | `/mnt/main/woodpecker` |
| `ytdlp` | `data` | `ytdlp-data` | `/mnt/main/ytdlp` |
| `stirling-pdf` | `data` | `stirling-pdf-data` | `/mnt/main/stirling-pdf` |
| `paperless-ngx` | `data` | `paperless-ngx-data` | `/mnt/main/paperless-ngx` |
| `grampsweb` | `data` | `grampsweb-data` | `/mnt/main/grampsweb` |
| `trading-bot` | `data` | `trading-bot-data` | `/mnt/main/trading-bot` |

**For each stack, the pattern is identical:**

1. Read `stacks/<service>/main.tf` to find the exact NFS volume block and its volume name
2. Add `module "nfs_<volume_name>"` call with the correct PV name, namespace, and NFS path
3. Replace `nfs {}` block with `persistent_volume_claim { claim_name = module.nfs_<volume_name>.claim_name }`
4. `cd stacks/<service> && terragrunt apply --non-interactive`
5. Verify pod is running: `kubectl --kubeconfig $(pwd)/config get pods -n <service>`
6. Verify app is accessible: `curl -sI https://<service>.viktorbarzin.me | head -5`

**Important**: Read each `main.tf` first — volume names, NFS paths, and namespace references vary. The table above is a guide, not a source of truth. Some stacks may have different volume names or multiple NFS paths under a parent directory.

**Commit after every 3-5 stacks:**

```bash
git add stacks/audiobookshelf/main.tf stacks/calibre/main.tf stacks/changedetection/main.tf
git commit -m "[ci skip] migrate audiobookshelf, calibre, changedetection NFS volumes to CSI PV/PVC"
```

---

## Task 7: Multi-Volume Stack Migration

These stacks have 2+ NFS volumes. Each needs multiple module calls.

**Files to modify** (read each `main.tf` first to get exact volume names and paths):

| Stack | Expected NFS Volumes | Notes |
|-------|---------------------|-------|
| `openclaw` | 4: tools, home, workspace, data | 3 containers share volumes |
| `immich` | Multiple: library, upload, thumbs, etc. | Check exact paths from nfs_directories.txt |
| `servarr` | Parent + 7 sub-stacks, each with NFS | Factory pattern, check each sub-module |
| `frigate` | Multiple: config, media, recordings | GPU service |
| `dawarich` | Multiple | Check main.tf |
| `ebook2audiobook` | Multiple | GPU service |
| `f1-stream` | Multiple | Check main.tf |
| `real-estate-crawler` | Multiple | Check main.tf |
| `nextcloud` | Multiple | Custom LimitRange, complex stack |
| `rybbit` | Multiple: clickhouse data, etc. | Check main.tf |
| `osm_routing` | Multiple | Check main.tf |
| `affine` | Multiple | Check main.tf |

**Pattern is the same — just more module calls:**

```hcl
# Example for openclaw (4 volumes)
module "nfs_tools" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-tools"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/tools"
}

module "nfs_home" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-home"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/home"
}

module "nfs_workspace" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-workspace"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/workspace"
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-data"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/data"
}

# Then in pod spec:
volume {
  name = "tools"
  persistent_volume_claim { claim_name = module.nfs_tools.claim_name }
}
volume {
  name = "openclaw-home"
  persistent_volume_claim { claim_name = module.nfs_home.claim_name }
}
# ... etc
```

**Step for each**: Read main.tf → identify all `nfs {}` blocks → add module calls → replace volume blocks → plan → apply → verify.

**Commit after each multi-volume stack** (these are more complex, commit individually):

```bash
git add stacks/openclaw/main.tf
git commit -m "[ci skip] openclaw: migrate 4 NFS volumes to CSI PV/PVC with soft mount"
```

---

## Task 8: Platform Module Migration

These modules are under `stacks/platform/modules/` and reference shared modules at `../../../../modules/kubernetes/nfs_volume`.

**Files to modify:**

| Module | Current Storage Pattern | Notes |
|--------|----------------------|-------|
| `monitoring/prometheus.tf` | Existing PV/PVC with native NFS source | Change PV source from `nfs {}` to `csi {}` |
| `monitoring/loki.tf` | Existing PV/PVC with native NFS source | Same |
| `monitoring/grafana.tf` | Existing PV (alertmanager) with native NFS | Same |
| `redis/main.tf` | Inline NFS or PV | Check current pattern |
| `dbaas/` | PV for PostgreSQL, MySQL backup | Check current pattern |
| `technitium/` | Inline NFS | Standard migration |
| `headscale/` | Inline NFS | Standard migration |
| `vaultwarden/` | Inline NFS | Standard migration |
| `uptime-kuma/` | Inline NFS | Standard migration |
| `mailserver/` | Inline NFS | Standard migration |
| `infra-maintenance/` | Inline NFS | Standard migration |

**For existing PV/PVC resources** (monitoring stack), the change is different — replace the `persistent_volume_source` block:

```hcl
# OLD (in prometheus.tf):
persistent_volume_source {
  nfs {
    path   = "/mnt/main/prometheus"
    server = var.nfs_server
  }
}

# NEW:
persistent_volume_source {
  csi {
    driver        = "nfs.csi.k8s.io"
    volume_handle = "prometheus-data"
    volume_attributes = {
      server = var.nfs_server
      share  = "/mnt/main/prometheus"
    }
  }
}
```

Also add `storage_class_name = "nfs-truenas"` to the PV spec to inherit mount options.

**For inline NFS volumes** in platform modules, use the shared module with the longer path:

```hcl
module "nfs_data" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "technitium-data"
  namespace  = kubernetes_namespace.technitium.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/technitium"
}
```

**Apply as one platform apply:**

```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Verify all platform services:**

```bash
kubectl --kubeconfig $(pwd)/config get pods -n monitoring
kubectl --kubeconfig $(pwd)/config get pods -n redis
kubectl --kubeconfig $(pwd)/config get pods -n dbaas
kubectl --kubeconfig $(pwd)/config get pods -n technitium
# ... etc
```

**Commit:**

```bash
git add stacks/platform/
git commit -m "[ci skip] platform: migrate all NFS volumes to CSI PV/PVC with soft mount"
```

---

## Task 9: Update Documentation and Skills

**Files:**
- Modify: `.claude/CLAUDE.md` (update NFS Volume Pattern section)
- Modify: `.claude/skills/setup-project/SKILL.md` (update new service template to use module)

**Step 1: Update CLAUDE.md NFS Volume Pattern**

Replace the existing NFS Volume Pattern section with:

```markdown
### NFS Volume Pattern
**Use the `nfs_volume` shared module** for all NFS volumes. This creates CSI-backed PV/PVC with soft mount options (no stale mount hangs):
\```hcl
module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "<service>-data"       # Must be globally unique
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
\```
For platform modules, use `source = "../../../../modules/kubernetes/nfs_volume"`.

**Legacy pattern (DO NOT use for new services):** Inline `nfs {}` blocks mount with `hard,timeo=600` defaults which hang forever on stale mounts.
```

**Step 2: Update setup-project skill**

Update the new service template in `.claude/skills/setup-project/SKILL.md` to use the module pattern instead of inline NFS.

**Step 3: Commit**

```bash
git add .claude/
git commit -m "[ci skip] update NFS volume documentation to use CSI-backed nfs_volume module"
```

---

## Task 10: Validation — Simulate NFS Outage

**This is a manual verification step. Do NOT automate.**

After all services are migrated, simulate an NFS blip to confirm the stale mount fix works:

1. Pick a low-risk service (e.g., `privatebin`)
2. On TrueNAS, temporarily block NFS to the K8s network (iptables rule or pause NFS for 30 seconds)
3. Observe: pod should get I/O errors within ~9 seconds (not hang)
4. If the pod has a liveness probe that touches the filesystem, it should restart automatically
5. After NFS recovers, verify the pod re-mounts cleanly

**Do NOT run this on production without a maintenance window.** This is a "when you're ready" validation, not part of the automated migration.
