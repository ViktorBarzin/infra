# Drone Logbook (Open DroneLog) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Open DroneLog (DJI flight-log analyzer) at https://dronelog.viktorbarzin.me — new Tier-1 stack `stacks/drone-logbook/`, upstream image, Authentik-gated, with a DuckDB data PVC and an NFS auto-import drop folder.

**Architecture:** Single Deployment running `ghcr.io/arpanghosh8453/open-dronelog:latest` (nginx + Axum + DuckDB, port 80) in namespace `drone-logbook`; data on a `proxmox-lvm-encrypted` PVC (GPS logs = sensitive data), `/sync-logs` drop folder on static NFS, daily backup CronJob to `/srv/nfs/drone-logbook-backup` (vaultwarden pattern), `ingress_factory` with `auth = "required"`, Keel auto-upgrades via namespace enrollment. Modeled line-by-line on `stacks/freshrss/`. Design: `2026-07-04-drone-logbook-design.md`.

**Tech Stack:** Terraform/Terragrunt (Tier-1 PG state), Vault KV + ESO, ingress_factory, nfs_volume module, Keel/Kyverno.

Terraform is exempt from TDD (execution.md); each task ends with a concrete verification instead.

---

### Task 1: Vault secret

**Files:** none (Vault KV only)

- [ ] **Step 1.1: Create `secret/drone-logbook` with a generated profile-creation password**

```bash
vault kv put secret/drone-logbook profile_creation_pass="$(openssl rand -base64 24)"
```

- [ ] **Step 1.2: Verify**

```bash
vault kv get -field=profile_creation_pass secret/drone-logbook | wc -c
```

Expected: `33` (32 chars + newline). Never echo the value itself.

### Task 2: NFS drop folder on 192.168.1.127

**Files:**
- Modify: `secrets/nfs_directories.txt` (git-crypt'd — **edit from the MAIN checkout only**, never the worktree; sorted list, add `drone-logbook/sync-logs`)

- [ ] **Step 2.1: Create the directories** — world-writable + setgid like `vaultwarden-backup` (the `/srv/nfs` export root-squashes, so pod-root writes land as `nobody`):

```bash
ssh root@192.168.1.127 'mkdir -p /srv/nfs/drone-logbook/sync-logs /srv/nfs/drone-logbook-backup && chown -R root:www-data /srv/nfs/drone-logbook /srv/nfs/drone-logbook-backup && chmod 2777 /srv/nfs/drone-logbook/sync-logs /srv/nfs/drone-logbook-backup && ls -ld /srv/nfs/drone-logbook/sync-logs /srv/nfs/drone-logbook-backup'
```

Expected: `drwxrwsrwx ... root www-data ...` for both.
No `/etc/exports` (`scripts/pve-nfs-exports`) change — `/srv/nfs` is exported whole-tree.

- [ ] **Step 2.2: Record them in the declarative list (MAIN checkout, plaintext there)** — insert `drone-logbook-backup` and `drone-logbook/sync-logs` (after `diun`, before `etcd-backup`) in `~/code/infra/secrets/nfs_directories.txt`, then commit that single file to master:

```bash
git -C ~/code/infra add secrets/nfs_directories.txt
git -C ~/code/infra commit -m "nfs_directories: add drone-logbook/sync-logs

Drop folder for the new drone-logbook stack's auto-import (SYNC_LOGS_PATH).
Directory created on 192.168.1.127 root:www-data 2775."
git -C ~/code/infra push forgejo master
```

(Trivial single-file exception per execution.md; encrypted files cannot be edited from the worktree.)

### Task 3: Stack files (in the `wizard/drone-logbook` worktree)

**Files:**
- Create: `stacks/drone-logbook/main.tf` (content below)
- Create: `stacks/drone-logbook/terragrunt.hcl` (content below)
- Create: `stacks/drone-logbook/secrets` → symlink to `../../secrets`
- (`backend.tf`, `tiers.tf`, `cloudflare_provider.tf`, `providers.tf`, `.terraform.lock.hcl` are terragrunt-generated and **gitignored** — do NOT create or commit them; the tracked copies in old stacks like freshrss predate the ignore rule)

- [ ] **Step 3.1: `terragrunt.hcl`**

```hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}
```

- [ ] **Step 3.2: `main.tf`** — exact content:

```hcl
variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

# Open DroneLog (https://github.com/arpanghosh8453/open-dronelog) — self-hosted
# DJI flight-log analyzer for the DJI Mini 4 Pro. Runs the UPSTREAM image (the
# ViktorBarzin/drone-logbook fork has no custom commits); Keel tracks :latest.
# Design: docs/plans/2026-07-04-drone-logbook-design.md
resource "kubernetes_namespace" "drone_logbook" {
  metadata {
    name = "drone-logbook"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "drone-logbook-secrets"
      namespace = "drone-logbook"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "drone-logbook-secrets"
      }
      dataFrom = [{
        extract = {
          key = "drone-logbook"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.drone_logbook]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.drone_logbook.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# DuckDB database + cached DJI decryption keys + uploaded originals.
# Embedded DB -> block storage, not NFS (same rationale as freshrss data).
# Encrypted class: flight logs are GPS traces of home/travel (sensitive data
# -> proxmox-lvm-encrypted per the storage decision rule in .claude/CLAUDE.md).
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "drone-logbook-data-encrypted"
    namespace = kubernetes_namespace.drone_logbook.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and PVCs
    # can't shrink; without this every apply tries to revert the size.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Drop folder: any producer (Nextcloud sync, scp, future phone pipeline) lands
# DJI .txt logs here over NFS; the app auto-imports on SYNC_INTERVAL.
module "nfs_sync_logs" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "drone-logbook-sync-logs"
  namespace  = kubernetes_namespace.drone_logbook.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/drone-logbook/sync-logs"
  storage    = "5Gi"
}

resource "kubernetes_deployment" "drone_logbook" {
  metadata {
    name      = "drone-logbook"
    namespace = kubernetes_namespace.drone_logbook.metadata[0].name
    labels = {
      app                             = "drone-logbook"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      # DuckDB is single-writer; never overlap two pods on the same volume
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "drone-logbook"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "drone-logbook"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          name  = "drone-logbook"
          image = "ghcr.io/arpanghosh8453/open-dronelog:latest"
          env {
            name  = "RUST_LOG"
            value = "info"
          }
          env {
            # keep re-importable originals under /data/drone-logbook/uploaded
            name  = "KEEP_UPLOADED_FILES"
            value = "true"
          }
          env {
            name  = "SYNC_LOGS_PATH"
            value = "/sync-logs"
          }
          env {
            # 6-field cron (sec min hour dom mon dow): scan drop folder every 8h
            name  = "SYNC_INTERVAL"
            value = "0 0 */8 * * *"
          }
          env {
            name = "PROFILE_CREATION_PASS"
            value_from {
              secret_key_ref {
                name = "drone-logbook-secrets"
                key  = "profile_creation_pass"
              }
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data/drone-logbook"
          }
          volume_mount {
            name       = "sync-logs"
            mount_path = "/sync-logs"
            read_only  = true
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
        volume {
          name = "sync-logs"
          persistent_volume_claim {
            claim_name = module.nfs_sync_logs.claim_name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.external_secret]
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "drone_logbook" {
  metadata {
    name      = "drone-logbook"
    namespace = kubernetes_namespace.drone_logbook.metadata[0].name
    labels = {
      "app" = "drone-logbook"
    }
  }

  spec {
    selector = {
      app = "drone-logbook"
    }
    port {
      port        = "80"
      target_port = "80"
    }
  }
}

# -----------------------------------------------------------------------------
# Backup — required for every proxmox-lvm(-encrypted) app: daily copy of the
# data volume to NFS /srv/nfs/drone-logbook-backup (picked up by nfs-mirror ->
# sda -> Synology offsite). 01:30 = outside the 00:00/08:00/16:00 sync-import
# windows, so the DuckDB file is quiescent; uploaded originals make even a
# mid-write copy recoverable by re-import. Pod-affinity co-schedules with the
# app pod (RWO volume mounts twice only on the same node). Vaultwarden pattern.
# -----------------------------------------------------------------------------

module "nfs_backup" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "drone-logbook-backup-host"
  namespace  = kubernetes_namespace.drone_logbook.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/drone-logbook-backup"
}

resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = "drone-logbook-backup"
    namespace = kubernetes_namespace.drone_logbook.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "30 1 * * *"
    starting_deadline_seconds     = 300
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "drone-logbook"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "drone-logbook-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                _t0=$(date +%s)
                now=$(date +"%Y_%m_%d_%H_%M")
                mkdir -p /backup/$now
                cp -a /data/. /backup/$now/
                # Rotate — 30 day retention
                find /backup -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +
                _dur=$(($(date +%s) - _t0))
                _out_bytes=$(du -sb /backup/$now | awk '{print $1}')
                wget -qO- --post-data "backup_duration_seconds $${_dur}
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/drone-logbook-backup" || true
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_backup.claim_name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# https://dronelog.viktorbarzin.me
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required" # Authentik forward-auth — flight logs are GPS traces of home/travel
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.drone_logbook.metadata[0].name
  name            = "dronelog"
  service_name    = "drone-logbook"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Drone Logbook"
    "gethomepage.dev/description"  = "DJI flight log analyzer"
    "gethomepage.dev/icon"         = "mdi-quadcopter"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
```

- [ ] **Step 3.3: Boilerplate**

```bash
ln -s ../../secrets ~/code/infra/.worktrees/drone-logbook/stacks/drone-logbook/secrets
```

- [ ] **Step 3.4: Format check**

```bash
terraform fmt -check -diff $WT/stacks/drone-logbook/ || terraform fmt $WT/stacks/drone-logbook/
```

Expected: no diff (or auto-fixed).

- [ ] **Step 3.5: Commit on the branch (files by name, git-crypt filter flags per execution.md)**

```bash
git -C $WT -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false \
  add docs/plans/2026-07-04-drone-logbook-design.md docs/plans/2026-07-04-drone-logbook-plan.md \
      stacks/drone-logbook/main.tf stacks/drone-logbook/terragrunt.hcl stacks/drone-logbook/secrets \
      .claude/reference/service-catalog.md
git -C $WT -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false \
  commit -m "drone-logbook: new stack — self-hosted Open DroneLog at dronelog.viktorbarzin.me

Viktor asked to self-host the DJI flight-log analyzer for his DJI Mini 4 Pro
(fork ViktorBarzin/drone-logbook -> upstream arpanghosh8453/open-dronelog).
Upstream ghcr image with Keel auto-upgrade, DuckDB data on proxmox-lvm PVC,
NFS /sync-logs drop folder auto-imported every 8h, Authentik-gated ingress,
PROFILE_CREATION_PASS from Vault via ESO. Design + plan in docs/plans/."
```

### Task 4: Land and apply

- [ ] **Step 4.1: Presence claim** (CI apply mutates shared infra)

```bash
~/code/scripts/presence claim infra:drone-logbook --purpose "deploy new drone-logbook stack (Open DroneLog) via CI apply"
```

- [ ] **Step 4.2: Merge latest master into the branch, push to master**

```bash
git -C $WT -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false fetch forgejo
git -C $WT -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false merge forgejo/master
git -C $WT -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false push forgejo HEAD:master
```

Non-fast-forward → another agent landed first: fetch, merge, push again. Branch-protection rejection → fall back to PR via Forgejo API (token = password in `~/.git-credentials`).

- [ ] **Step 4.3: Watch the CI apply to completion** — Woodpecker pipeline on the infra repo (`ci.viktorbarzin.me`), then confirm live:

```bash
kubectl get ns drone-logbook && kubectl -n drone-logbook get deploy,pvc,pods,externalsecret,cronjob
kubectl -n drone-logbook rollout status deploy/drone-logbook --timeout=300s
```

Expected: namespace present, ExternalSecret `SecretSynced`, data PVC `Bound` (the NFS PVCs bind on first pod/job use), CronJob `drone-logbook-backup` scheduled `30 1 * * *`, pod `Running 1/1`.

- [ ] **Step 4.4: Cleanup worktree + branch; release presence**

```bash
git -C ~/code/infra worktree remove .worktrees/drone-logbook
git -C ~/code/infra branch -d wizard/drone-logbook
git -C ~/code/infra pull --ff-only   # only if main checkout clean/quiescent
~/code/scripts/presence release infra:drone-logbook
```

### Task 5: End-to-end verification

- [ ] **Step 5.1: Ingress + Authentik gate**

```bash
curl -sI https://dronelog.viktorbarzin.me | head -5
```

Expected: `302` redirect into Authentik (NOT `200`, NOT `404`).

- [ ] **Step 5.2: App alive behind the gate** (bypass ingress via port-forward, read-only debug)

```bash
kubectl -n drone-logbook port-forward svc/drone-logbook 18080:80 &
sleep 2 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/ && kill %1
```

Expected: `200`.

- [ ] **Step 5.3: Sync folder visible in-pod**

```bash
kubectl -n drone-logbook exec deploy/drone-logbook -- ls -ld /sync-logs /data/drone-logbook
```

Expected: both directories listed; `/sync-logs` read-only mount.

- [ ] **Step 5.4: Monitor + homepage** — Uptime Kuma external monitor for `dronelog.viktorbarzin.me` auto-created (ingress annotation); homepage tile under "Media & Entertainment".

- [ ] **Step 5.5: Functional import** — Viktor uploads a real Mini 4 Pro `.txt` log via the web UI (or drops it in `/srv/nfs/drone-logbook/sync-logs`); confirms flight appears with charts/map. Requires pod egress to DJI once per new log (decryption key). If an upstream sample log is available, the agent may pre-verify import via the REST API through the port-forward.
