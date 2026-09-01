variable "tls_secret_name" {
  type      = string
  sensitive = true
}
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "immich"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])

  # Immich owner ids. Used by the thumbnail reconciler, which has to route each
  # repair to its owner's API key: POST /api/assets/jobs checks asset.update per
  # asset and admin does not inherit that across users.
  immich_owner_viktor = "2a2ab475-dc9b-48d5-9f47-9f60931a8bcf"
  immich_owner_anca   = "c10358bf-1412-4358-94f6-e5950f259912"
}


variable "immich_version" {
  type = string
  # Record only — live image is Keel-managed (ignore_changes on the deployments).
  # Keel auto-applies PATCH **and MINOR** releases hourly since 2026-08-12
  # (keel.sh/policy = "minor" on immich-api / immich-worker /
  # immich-machine-learning); this var just records the current floor. Only a
  # MAJOR bump (v3.x -> v4.x) now needs a hand-landing: change this +
  # `kubectl set image` live.
  default = "v3.1.0"
}
variable "proxmox_host" { type = string }
variable "redis_host" { type = string }


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.immich.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# NFS volumes on Proxmox host (migrated from TrueNAS 2026-04-13)

module "nfs_backups_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-backups-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/immich/backups"
  storage_class_name = "nfs-pve"
}

module "nfs_encoded_video_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-encoded-video-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/immich/encoded-video"
  storage_class_name = "nfs-pve"
}

module "nfs_library_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-library-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/immich/library"
  storage_class_name = "nfs-pve"
}

module "nfs_profile_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-profile-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/immich/profile"
  storage_class_name = "nfs-pve"
}

module "nfs_thumbs_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-thumbs-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs-ssd/immich/thumbs"
  storage_class_name = "nfs-pve"
}

module "nfs_upload_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-upload-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs/immich/upload"
  storage_class_name = "nfs-pve"
}

module "nfs_postgresql_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-postgresql-data-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/postgresql"
}

# Migrated 2026-04-25: PG live data moved off NFS to LUKS-encrypted block.
# WAL fsync per commit on NFS contributed to the 2026-04-22 NFS writeback storm
# (see post-mortems/2026-04-22-vault-raft-leader-deadlock.md).
# Backup CronJob still writes to module.nfs_postgresql_host (NFS append-only).
resource "kubernetes_persistent_volume_claim" "immich_postgresql_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "immich-postgresql-data-encrypted"
    namespace = kubernetes_namespace.immich.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "10Gi" }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

module "nfs_ml_cache_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "immich-ml-cache-host"
  namespace          = kubernetes_namespace.immich.metadata[0].name
  nfs_server         = var.proxmox_host
  nfs_path           = "/srv/nfs-ssd/immich/machine-learning"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "immich"
    labels = {
      # Opts immich out of kyverno's `quota-tier-2-gpu` generation rule
      # so this stack can own the tier-quota with a higher memory cap.
      "resource-governance/custom-quota" = "true"
      tier                               = local.tiers.gpu
      "keel.sh/enrolled"                 = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Override the kyverno-generated tier-2-gpu quota (12Gi requests.memory).
# Immich-server needs 8Gi to absorb face-detection burst spikes (OOM 2026-04-26)
# without OOM. Plus immich-machine-learning (3.5Gi) + immich-postgresql (3Gi) +
# backup CronJobs ≈ 15.5Gi. 24Gi gives ~8Gi headroom (raised 2026-05-26 — was at
# 88% with VPA bumps creeping up on immich-server burst behaviour).
resource "kubernetes_resource_quota" "immich" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "8"
      "requests.memory" = "24Gi"
      "limits.memory"   = "40Gi"
      pods              = "40"
    }
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
      name      = "immich-secrets"
      namespace = "immich"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "immich-secrets"
      }
      dataFrom = [{
        extract = {
          key = "immich"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.immich]
}

# Job tier of the worker split (docs/plans/2026-07-12-immich-horizontal-scaling-design.md):
# runs EVERY background job (thumbnails, metadata, ML fan-out, transcoding —
# job-based AND real-time HLS ffmpeg) via IMMICH_WORKERS_EXCLUDE=api. Exactly
# 1 replica: BullMQ concurrency is per-worker-process (upstream #28051), so a
# second worker would double every queue and race face-clustering. Client
# traffic is served by immich-api; this pod has no HTTP surface.
resource "kubernetes_deployment" "immich_server" {
  metadata {
    name      = "immich-worker"
    namespace = kubernetes_namespace.immich.metadata[0].name

    labels = {
      app  = "immich-worker"
      tier = local.tiers.gpu
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      # Must track the same immich version as immich-api (see the note there);
      # "minor" set explicitly + kept OUT of ignore_changes so it survives
      # applies/recreates instead of falling back to Kyverno's "patch" default.
      "keel.sh/policy" = "minor"
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }

  spec {
    replicas                  = 1
    progress_deadline_seconds = 600

    selector {
      match_labels = {
        app = "immich-worker"
      }
    }

    strategy {
      # Never two job workers concurrently (#28051) — Recreate swaps the single
      # worker with a ~1 min job pause; the queue buffers in Redis meanwhile.
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "immich-worker"
        }
        annotations = {
          "diun.enable"                = "true"
          "diun.include_tags"          = "^\\d+\\.\\d+\\.\\d+$"
          "reloader.stakater.com/auto" = "true"
        }
      }

      spec {
        # Pinned to the GPU node for NVENC hardware video transcoding (Tesla T4,
        # time-sliced). The immich-server image's ffmpeg ships h264/hevc_nvenc;
        # activation is via system-config ffmpeg.accel=nvenc.
        priority_class_name = "gpu-workload"
        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          name  = "immich-worker"
          image = "ghcr.io/immich-app/immich-server:${var.immich_version}"

          env {
            # Everything except the api worker = the microservices role.
            # docs.immich.app/administration/jobs-workers
            name  = "IMMICH_WORKERS_EXCLUDE"
            value = "api"
          }
          env {
            name  = "DB_DATABASE_NAME"
            value = "immich"
          }
          env {
            name  = "DB_HOSTNAME"
            value = "immich-postgresql.immich.svc.cluster.local"
          }
          env {
            name  = "DB_USERNAME"
            value = "immich"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IMMICH_MACHINE_LEARNING_URL"
            value = "http://immich-machine-learning:3003"
          }
          env {
            name  = "REDIS_HOSTNAME"
            value = var.redis_host
          }

          # NO HTTP probes and NO port: the microservices worker binds an
          # EPHEMERAL port (app.listen(0) in workers/microservices.ts @ v3.0.2)
          # and serves no HTTP, so any httpGet probe would crash-loop it.
          # Upstream's own immich-healthcheck exits 0 unconditionally when the
          # api worker is excluded — the health contract is "process alive"
          # (k8s restarts on exit) plus the Loki alert on the api pods'
          # checkWorkers() warning ("No microservices worker is connected").
          # The 2026-05-24 startup-probe lesson (1h vector reindex after a PG
          # restart) moved to immich-api, which kept the HTTP probes.

          # volume_mount {
          #   name       = "library-old"
          #   mount_path = "/usr/src/app/upload"
          # }

          # Mount them 1 by 1 to enable thumbs in ssd
          volume_mount {
            name       = "backups"
            mount_path = "/usr/src/app/upload/backups"
          }
          volume_mount {
            name       = "encoded-video"
            mount_path = "/usr/src/app/upload/encoded-video"
          }
          volume_mount {
            name       = "library"
            mount_path = "/usr/src/app/upload/library"
          }
          volume_mount {
            name       = "profile"
            mount_path = "/usr/src/app/upload/profile"
          }
          volume_mount {
            name       = "thumbs"
            mount_path = "/usr/src/app/upload/thumbs"
          }
          volume_mount {
            name       = "upload"
            mount_path = "/usr/src/app/upload/upload"
          }
          resources {
            requests = {
              cpu = "100m"
              # 14d median ~2.9Gi / peak ~8.6Gi. Request lowered 7Gi->3584Mi 2026-07-26 —
              # REVERSES the 2026-07-06 reserve-peak call: reserving peak on every worker
              # over-sums the N-1 total and fired ClusterCannotTolerateNonGpuNodeLoss (+ the
              # code-j3tx node1-reboot starvation). Spikes ride the 10Gi limit below
              # (Burstable); node-OOM risk unchanged (limit untouched).
              memory = "3584Mi"
            }
            limits = {
              # 30d peak is 8.1Gi and the 7Gi req=lim cut OOMKilled it 2026-07-12;
              # limit decoupled from request so ingest/job spikes fit without
              # raising the scheduler reservation. docs/research/immich-front-cache.md
              memory           = "10Gi"
              "nvidia.com/gpu" = "1"
              # GPU VRAM budget (ADR-0016): NVENC transcode footprint. 7-day
              # measured peak 1251 MiB (2026-08-31), so 1500 carries ~20%
              # margin. Was 3000, which reserved ~1.5 GiB this never used.
              "viktorbarzin.me/gpumem" = "1500"
            }
          }
        }

        # volume {
        #   name = "library-old"
        #   nfs {
        #     server = var.nfs_server
        #     path   = "/mnt/main/immich/immich/"
        #   }
        # }

        volume {
          name = "backups"
          persistent_volume_claim {
            claim_name = module.nfs_backups_host.claim_name
          }
        }
        volume {
          name = "encoded-video"
          persistent_volume_claim {
            claim_name = module.nfs_encoded_video_host.claim_name
          }
        }
        volume {
          name = "library"
          persistent_volume_claim {
            claim_name = module.nfs_library_host.claim_name
          }
        }
        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = module.nfs_profile_host.claim_name
          }
        }
        volume {
          name = "thumbs"
          persistent_volume_claim {
            claim_name = module.nfs_thumbs_host.claim_name
          }
        }
        volume {
          name = "upload"
          persistent_volume_claim {
            claim_name = module.nfs_upload_host.claim_name
          }
        }
      }
    }
  }
}

# API tier of the worker split (docs/plans/2026-07-12-immich-horizontal-scaling-design.md):
# serves ALL client traffic (HTTP + websockets — multi-node native via Immich's
# socket.io Redis adapter, no sticky sessions). Runs NO background jobs and
# needs NO GPU, so replicas spread across nodes for node-loss HA. Background
# jobs + NVENC live in the single immich-worker (upstream #28051 caps that
# tier at 1 replica).
resource "kubernetes_deployment" "immich_api" {
  metadata {
    name      = "immich-api"
    namespace = kubernetes_namespace.immich.metadata[0].name

    labels = {
      app  = "immich-api"
      tier = local.tiers.gpu
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      # Keel keeps this tier on the same immich version as immich-worker
      # (identical-digest requirement across replicas, plan §3.8).
      #
      # "minor" (was "patch", 2026-08-12): patch never crosses a minor, so the
      # stack sat on v3.0.3 while v3.1.0 was out for two weeks. Set EXPLICITLY
      # here and deliberately NOT in ignore_changes below, so it survives
      # applies/recreates — Kyverno's inject-keel-annotations uses an
      # add-if-absent anchor on policy, so an explicit value wins (same recipe
      # as vaultwarden, commit 5d785b5a). trigger/pollSchedule stay
      # Kyverno-injected and stay ignored.
      "keel.sh/policy"       = "minor"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@every 1h"
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }

  spec {
    replicas                  = 3
    progress_deadline_seconds = 600

    selector {
      match_labels = {
        app = "immich-api"
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        # maxSurge MUST stay 0: a surge pod's 1.5Gi request would push the
        # namespace past its 24Gi request quota and wedge the roll (plan §5).
        # 2 of 3 replicas always serve.
        max_surge       = "0"
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = {
          app = "immich-api"
        }
        annotations = {
          "diun.enable"                = "true"
          "diun.include_tags"          = "^\\d+\\.\\d+\\.\\d+$"
          "reloader.stakater.com/auto" = "true"
        }
      }

      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "immich-api"
            }
          }
        }
        container {
          name  = "immich-api"
          image = "ghcr.io/immich-app/immich-server:${var.immich_version}"

          port {
            name           = "http"
            container_port = 2283
            protocol       = "TCP"
          }

          env {
            # api worker only: HTTP/websocket serving + job enqueue; every
            # background job (thumbs, transcode, ML fan-out) runs in
            # immich-worker. docs.immich.app/administration/jobs-workers
            name  = "IMMICH_WORKERS_INCLUDE"
            value = "api"
          }
          env {
            name  = "DB_DATABASE_NAME"
            value = "immich"
          }
          env {
            name  = "DB_HOSTNAME"
            value = "immich-postgresql.immich.svc.cluster.local"
          }
          env {
            name  = "DB_USERNAME"
            value = "immich"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IMMICH_MACHINE_LEARNING_URL"
            value = "http://immich-machine-learning:3003"
          }
          env {
            name  = "REDIS_HOSTNAME"
            value = var.redis_host
          }

          liveness_probe {
            http_get {
              path = "/api/server/ping"
              port = "http"
            }
            initial_delay_seconds = 0
            period_seconds        = 10
            timeout_seconds       = 1
            failure_threshold     = 3
            success_threshold     = 1
          }

          readiness_probe {
            http_get {
              path = "/api/server/ping"
              port = "http"
            }
            period_seconds    = 10
            timeout_seconds   = 1
            failure_threshold = 3
            success_threshold = 1
          }

          startup_probe {
            http_get {
              path = "/api/server/ping"
              port = "http"
            }
            period_seconds  = 10
            timeout_seconds = 1
            # Same 1h ceiling as the old combined pod: after a PG restart the
            # startup path can wait on vector-table reindexing (2026-05-24).
            failure_threshold = 360
            success_threshold = 1
          }

          volume_mount {
            name       = "backups"
            mount_path = "/usr/src/app/upload/backups"
          }
          volume_mount {
            name       = "encoded-video"
            mount_path = "/usr/src/app/upload/encoded-video"
          }
          volume_mount {
            name       = "library"
            mount_path = "/usr/src/app/upload/library"
          }
          volume_mount {
            name       = "profile"
            mount_path = "/usr/src/app/upload/profile"
          }
          volume_mount {
            name       = "thumbs"
            mount_path = "/usr/src/app/upload/thumbs"
          }
          volume_mount {
            name       = "upload"
            mount_path = "/usr/src/app/upload/upload"
          }
          resources {
            requests = {
              cpu = "100m"
              # API-only profile — the old 6.9Gi peaks belong to jobs (now in
              # immich-worker). Lean so 3 replicas + cronjobs fit the 24Gi ns
              # quota; re-measure after a week (plan §7).
              memory = "1536Mi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "backups"
          persistent_volume_claim {
            claim_name = module.nfs_backups_host.claim_name
          }
        }
        volume {
          name = "encoded-video"
          persistent_volume_claim {
            claim_name = module.nfs_encoded_video_host.claim_name
          }
        }
        volume {
          name = "library"
          persistent_volume_claim {
            claim_name = module.nfs_library_host.claim_name
          }
        }
        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = module.nfs_profile_host.claim_name
          }
        }
        volume {
          name = "thumbs"
          persistent_volume_claim {
            claim_name = module.nfs_thumbs_host.claim_name
          }
        }
        volume {
          name = "upload"
          persistent_volume_claim {
            claim_name = module.nfs_upload_host.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "immich_api" {
  metadata {
    name      = "immich-api"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    min_available = "2"
    selector {
      match_labels = { app = "immich-api" }
    }
  }
}

resource "kubernetes_service" "immich-server" {
  metadata {
    name      = "immich-server"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      "app" = "immich-server"
    }
  }

  spec {
    selector = {
      # Serves from the api tier since the 2026-07-12 worker split; the name
      # stays "immich-server" so the ingress and ImmichFrame kiosks are
      # untouched. immich-worker has no HTTP to serve.
      app = "immich-api"
    }
    port {
      port = 2283
    }
  }
}

resource "kubernetes_deployment" "immich-postgres" {
  metadata {
    name      = "immich-postgresql"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      tier = local.tiers.gpu
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],                    # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-postgresql"
      }
    }
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "immich-postgresql"
        }
      }
      spec {
        container {
          image = "ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0"
          name  = "immich-postgresql"
          port {
            container_port = 5432
            protocol       = "TCP"
            name           = "postgresql"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "POSTGRES_USER"
            value = "immich"
          }
          env {
            name  = "POSTGRES_DB"
            value = "immich"
          }
          env {
            name  = "DB_STORAGE_TYPE"
            value = "SSD"
          }
          volume_mount {
            name       = "postgresql-persistent-storage"
            mount_path = "/var/lib/postgresql/data"
          }
          lifecycle {
            post_start {
              exec {
                command = ["/bin/sh", "-c", <<-EOT
                  # Wait for PG to accept connections, then prewarm vector search tables
                  for i in $(seq 1 60); do
                    if pg_isready -U postgres > /dev/null 2>&1; then
                      psql -U postgres -d immich -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm; SELECT pg_prewarm('smart_search'); SELECT pg_prewarm('clip_index');" > /dev/null 2>&1
                      break
                    fi
                    sleep 1
                  done
                EOT
                ]
              }
            }
          }
          resources {
            requests = {
              cpu = "100m"
              # 14d median ~2.3Gi / peak ~3.6Gi. Request lowered 4Gi->3Gi 2026-07-26
              # (reverses the 2026-07-06 reserve-peak call) to free N-1 scheduler headroom;
              # 3Gi req stays above observed peak, spikes ride the 4Gi limit (Burstable).
              memory = "3Gi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }
        init_container {
          name  = "write-pg-override-conf"
          image = "busybox:1.36"
          command = ["sh", "-c", <<-EOT
            # Skip write on uninitialised PGDATA — initdb refuses non-empty dirs.
            # On first boot the override is absent; trigger a pod restart after
            # initdb completes so the override is applied before extension load.
            if [ ! -f /data/PG_VERSION ]; then
              echo "PGDATA uninitialised, skipping override conf (will write on next pod start)"
              exit 0
            fi
            cat > /data/postgresql.override.conf <<'PGCONF'
            # Immich vector search performance tuning
            shared_buffers = 2048MB
            effective_cache_size = 2560MB
            work_mem = 64MB
            shared_preload_libraries = 'vchord.so, vectors.so, pg_prewarm'
            pg_prewarm.autoprewarm = on
            pg_prewarm.autoprewarm_interval = 300
            PGCONF
          EOT
          ]
          volume_mount {
            name       = "postgresql-persistent-storage"
            mount_path = "/data"
          }
        }
        volume {
          name = "postgresql-persistent-storage"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.immich_postgresql_encrypted.metadata[0].name
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "immich-postgresql" {
  metadata {
    name      = "immich-postgresql"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      "app" = "immich-postgresql"
    }
  }

  spec {
    selector = {
      app = "immich-postgresql"
    }
    port {
      port = 5432
    }
  }
}


# If you're having issuewith typesens container exiting prematurely, increase liveliness check
# resource "helm_release" "immich" {
#  namespace = kubernetes_namespace.immich.metadata[0].name
#   name      = "immich"

#   repository = "https://immich-app.github.io/immich-charts"
#   chart      = "immich"
#   atomic     = true
#   version    = "0.9.3"
#   timeout    = 6000

#   values = [templatefile("${path.module}/chart_values.tpl", { postgresql_password = data.vault_kv_secret_v2.secrets.data["db_password"], version = var.immich_version })]
# }

# The helm one cannot be customized to use affinity settings to use the gpu node
resource "kubernetes_deployment" "immich-machine-learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      tier = local.tiers.gpu
    }
    annotations = {
      # Must track the same immich version as immich-api (see the note there);
      # "minor" set explicitly + kept OUT of ignore_changes so it survives
      # applies/recreates instead of falling back to Kyverno's "patch" default.
      #
      # CAVEAT (2026-08-12): Keel's hourly tag-list poll for THIS repo currently
      # fails every run with a ghcr 429 (the repo carries thousands of
      # per-commit / per-accelerator / PR tags and the walk trips the registry
      # rate limit mid-pagination), so a new release can land on immich-api and
      # be missed here. Check `kubectl -n immich get deploy -o wide` after any
      # immich bump and `kubectl set image` this one if it lagged.
      "keel.sh/policy" = "minor"
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-machine-learning"
      }
    }
    strategy {
      type = "Recreate"
    }
    template {
      metadata {
        labels = {
          app = "immich-machine-learning"
        }
      }
      spec {
        priority_class_name = "gpu-workload"
        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        container {
          # image = "ghcr.io/immich-app/immich-machine-learning:${var.immich_version}"
          image = "ghcr.io/immich-app/immich-machine-learning:${var.immich_version}-cuda"
          name  = "immich-machine-learning"
          port {
            container_port = 3003
            protocol       = "TCP"
            name           = "immich-ml"
          }
          # Idle models unload after 600s, returning VRAM to the shared T4.
          # MUST stay > 0: at 0 nothing ever unloads and onnxruntime's CUDA
          # arena (OCR's dynamic input shapes balloon it to ~10GB) is held
          # forever, starving llama-swap (qwen3-8b) on the same time-sliced
          # GPU and silently breaking recruiter-responder triage.
          env {
            name  = "MACHINE_LEARNING_MODEL_TTL"
            value = "600"
          }
          env {
            name  = "TRANSFORMERS_CACHE"
            value = "/cache"
          }
          env {
            name  = "HF_XET_CACHE"
            value = "/cache/huggingface-xet"
          }
          env {
            name  = "MPLCONFIGDIR"
            value = "/cache/matplotlib-config"
          }
          # Preload CLIP models (for smart search)
          env {
            name  = "MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL"
            value = "ViT-B-16-SigLIP2__webli"
          }
          env {
            name  = "MACHINE_LEARNING_PRELOAD__CLIP__VISUAL"
            value = "ViT-B-16-SigLIP2__webli"
          }
          # Preload facial recognition models
          env {
            name  = "MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION__DETECTION"
            value = "buffalo_l"
          }
          env {
            name  = "MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION__RECOGNITION"
            value = "buffalo_l"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "3584Mi"
            }
            limits = {
              # Sat pinned at 3571/3584Mi with 6 OOMKills in 2.5d (2026-07-12);
              # limit-only raise — request unchanged to avoid over-reserving.
              memory           = "4608Mi"
              "nvidia.com/gpu" = "1"
              # GPU VRAM budget (ADR-0016): schedule-time reservation + the
              # gpu-vram-watchdog recycle threshold. Set from the FRESH
              # footprint (1958 MiB with all four preloads resident, measured
              # 2026-08-31), not the plateau: onnxruntime's BFC arena grows to
              # serve each peak and never releases, so a pod days old reads
              # 5900+ MiB and one 1.94 GiB allocation took it to 12044. Budget
              # at fresh + margin and let the watchdog reclaim the ratchet under
              # contention. Bounds the runaway that starved llama-swap on
              # 2026-06-02 and again on 2026-08-31.
              "viktorbarzin.me/gpumem" = "2500"
            }
          }
          liveness_probe {
            http_get {
              path = "/ping"
              port = 3003
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/ping"
              port = 3003
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }
        volume {
          name = "cache"
          persistent_volume_claim {
            claim_name = module.nfs_ml_cache_host.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "immich-machine-learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      "app" = "immich-machine-learning"
    }
  }

  spec {
    selector = {
      app = "immich-machine-learning"
    }
    port {
      port = 3003
    }
  }
}

# Smart-search maintenance + probe. Does all three jobs that keep context
# search fast, in ONE pod per tick.
#
# Consolidated 2026-08-16 from three separate */5 CronJobs — clip-index-prewarm,
# clip-keepalive and immich-search-probe — which fired on the same tick against
# the same two services and between them cost 864 pod creations a day for one
# namespace. Each pod create/destroy writes containerd overlay layers, a kubelet
# pod dir, /var/log/pods and a systemd transient scope plus the ext4 journal
# metadata for all of it: small random writes, which is exactly what the shared
# sdc spindle is short of. Merging them costs nothing in cadence or latency and
# takes that to 288/day.
#
# The name is kept (rather than something more descriptive) because the
# Pushgateway job label, the ImmichSmartSearchSlow / ImmichClipIndexColdCache
# alerts and cluster-health check #46 all key on it; renaming would move metrics
# for no benefit.
#
# Per tick:
#   init  measure  (postgres image — has psql)
#         · re-prewarms clip_index + smart_search, but only on :00/:30 ticks
#         · times a representative random-vector ANN query
#         · reads clip_index residency from pg_buffercache
#         · writes Prometheus exposition text to a shared emptyDir
#   then, in parallel:
#     push    (curl image) — POSTs those metrics to the Pushgateway
#     warmup  (curl image) — pings the CLIP textual encoder so it stays resident
#
# A random probe vector each run samples different vchord lists, so the metric
# reflects true cache warmth rather than one hot list. Stock images only — never
# apt/pip install at runtime (see the status-page-pusher disk-write incident).
#
# Failure coupling, accepted deliberately: a failing keepalive now fails the
# whole Job, where before it failed its own. That is arguably an improvement —
# a standalone clip-keepalive failing was easy to miss — and the probe's own
# health is reported by immich_smart_search_probe_success in the metrics, not by
# the Job's exit code, so alerting is unaffected either way.
resource "kubernetes_cron_job_v1" "immich-search-probe" {
  metadata {
    name      = "immich-search-probe"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "*/5 * * * *"
    starting_deadline_seconds     = 60
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        # 180s, up from 120: the pod now also runs pg_prewarm over a ~665MB
        # index on the :00/:30 ticks, on top of the ANN probe.
        active_deadline_seconds    = 180
        ttl_seconds_after_finished = 120
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            volume {
              name = "shared"
              empty_dir {}
            }
            init_container {
              name  = "measure"
              image = "ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0"
              command = ["/bin/bash", "-c", <<-EOT
                set -uo pipefail
                OUT=/shared/metrics.prom

                # Re-prewarm the ~665MB vchord clip_index (was its own
                # clip-index-prewarm CronJob on */5 until 2026-08-16). The index
                # decays out of PG shared_buffers over DAYS under buffer
                # pressure from thumbnail/OCR/library jobs — the postgres
                # postStart hook prewarms once at pod start and
                # pg_prewarm.autoprewarm only reloads at startup, so nothing
                # else re-warms it during runtime. 288 re-warms a day was far
                # more than that decay rate needs, so this now fires on the
                # :00 and :30 ticks only (48/day). ImmichClipIndexColdCache
                # watches the actual residency percentage and is the backstop
                # if that assumption is ever wrong.
                #
                # 10# forces base 10 — bash reads a bare "05" as octal and errors.
                if [ $(( 10#$(date +%M) % 30 )) -eq 0 ]; then
                  if psql -v ON_ERROR_STOP=1 -c "SELECT pg_prewarm('clip_index'); SELECT pg_prewarm('smart_search');" >/dev/null 2>&1; then
                    echo "prewarm ok"
                  else
                    echo "prewarm FAILED" >&2
                  fi
                fi

                success=1
                start=$(date +%s%3N)
                if ! psql -v ON_ERROR_STOP=1 -tA -c "SELECT count(*) FROM (SELECT \"assetId\" FROM smart_search ORDER BY embedding <=> (SELECT embedding FROM smart_search ORDER BY random() LIMIT 1) LIMIT 100) s" >/dev/null 2>/tmp/err; then
                  success=0
                  cat /tmp/err >&2
                fi
                end=$(date +%s%3N)
                dur_ms=$((end - start))
                dur=$(printf '%d.%03d' $((dur_ms/1000)) $((dur_ms%1000)))
                pct=$(psql -tA -c "SELECT COALESCE(round(100.0*count(*)*8192/greatest(pg_relation_size('clip_index'::regclass),1),1),0) FROM pg_buffercache b JOIN pg_class c ON b.relfilenode=pg_relation_filenode(c.oid) WHERE c.relname='clip_index'" 2>/dev/null)
                if [ -z "$pct" ]; then pct=-1; fi
                {
                  echo "# HELP immich_smart_search_db_seconds Wall-clock latency of a representative smart-search ANN query."
                  echo "# TYPE immich_smart_search_db_seconds gauge"
                  echo "immich_smart_search_db_seconds $dur"
                  echo "# HELP immich_clip_index_cached_pct Percent of clip_index vchord index resident in PG shared_buffers."
                  echo "# TYPE immich_clip_index_cached_pct gauge"
                  echo "immich_clip_index_cached_pct $pct"
                  echo "# HELP immich_smart_search_probe_success 1 if the probe ANN query succeeded."
                  echo "# TYPE immich_smart_search_probe_success gauge"
                  echo "immich_smart_search_probe_success $success"
                  echo "# HELP immich_smart_search_probe_last_run_timestamp Unix time of last probe run."
                  echo "# TYPE immich_smart_search_probe_last_run_timestamp gauge"
                  echo "immich_smart_search_probe_last_run_timestamp $(date +%s)"
                } > "$OUT"
                echo "probe dur=$dur pct=$pct success=$success"
                exit 0
              EOT
              ]
              env {
                name  = "PGHOST"
                value = "immich-postgresql.immich.svc.cluster.local"
              }
              env {
                name  = "PGUSER"
                value = "immich"
              }
              env {
                name  = "PGDATABASE"
                value = "immich"
              }
              env {
                name  = "PGCONNECT_TIMEOUT"
                value = "10"
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "db_password"
                  }
                }
              }
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
            container {
              name  = "push"
              image = "docker.io/curlimages/curl:8.11.1"
              command = [
                "curl", "-sf", "-m", "20", "--data-binary", "@/shared/metrics.prom",
                "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/immich-search-probe",
              ]
              volume_mount {
                name       = "shared"
                mount_path = "/shared"
              }
              resources {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
              }
            }
            # Keeps the CLIP *textual* (smart-search) model resident on the
            # shared T4. Was its own clip-keepalive CronJob on */5 until
            # 2026-08-16; folded in here because it was firing on the same tick
            # against the same app, and a pod that is already being created
            # costs nothing extra to carry it.
            #
            # MACHINE_LEARNING_MODEL_TTL=600 is a single GLOBAL knob — without
            # traffic CLIP unloads after 600s idle exactly like OCR/face (immich
            # has no per-model pin). Pinging every 5 min keeps a search query
            # off the cold-load path while idle OCR/face still free their VRAM.
            # Textual only: smart search is text->embedding->pgvector, and the
            # visual encoder is import-time and intentionally left to unload.
            # The modelName MUST match MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL
            # on the deployment above.
            #
            # Deliberately a SEPARATE container rather than another line in a
            # shell: exec form (no shell) is what lets the JSON quotes pass
            # through verbatim, and sibling containers start in parallel, so
            # this does not delay the push above.
            container {
              name = "warmup"
              # curl baked into the image — never apt/apk/pip install at
              # runtime in a CronJob (writes to the node container layer on
              # every run; see status-page-pusher disk-write incident).
              image = "docker.io/curlimages/curl:8.11.1"
              command = [
                "curl", "-sf", "-m", "30",
                "-F", "entries={\"clip\":{\"textual\":{\"modelName\":\"ViT-B-16-SigLIP2__webli\"}}}",
                "-F", "text=keepalive",
                "http://immich-machine-learning:3003/predict",
              ]
              resources {
                requests = { cpu = "10m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
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

module "ingress-immich" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": Immich has its own user auth + bearer-token API. Authentik
  # forward-auth on `/api/*` was 302-ing the iOS/Android Immich app and any
  # external API consumer. App-level auth is the gate now.
  auth                    = "app"
  dns_type                = "non-proxied"
  namespace               = kubernetes_namespace.immich.metadata[0].name
  name                    = "immich"
  service_name            = "immich-server"
  port                    = 2283
  tls_secret_name         = var.tls_secret_name
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-immich-rate-limit@kubernetescrd"]
  anti_ai_scraping        = false
  extra_annotations = {
    "gethomepage.dev/enabled"        = "true"
    "gethomepage.dev/description"    = "Photos library"
    "gethomepage.dev/icon"           = "immich.png"
    "gethomepage.dev/name"           = "Immich"
    "gethomepage.dev/group"          = "Media & Entertainment"
    "gethomepage.dev/widget.type"    = "immich"
    "gethomepage.dev/widget.url"     = "http://immich-server.immich.svc.cluster.local:2283"
    "gethomepage.dev/widget.version" = "2"
    "gethomepage.dev/pod-selector"   = ""
    "gethomepage.dev/widget.key"     = local.homepage_credentials["immich"]["token"]
  }
}


resource "kubernetes_cron_job_v1" "postgresql-backup" {
  metadata {
    name      = "postgresql-backup"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "0 0 * * *"
    # schedule                      = "* * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "postgresql-backup"
              image = "postgres:16.4-bullseye"
              command = ["/bin/sh", "-c", <<-EOT
                apt-get update -qq && apt-get install -yqq curl >/dev/null 2>&1 || true
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                export now=$(date +"%Y_%m_%d_%H_%M")
                pg_dumpall  -h immich-postgresql -U immich > /backup/dump_$now.sql

                # Rotate - delete last log file
                cd /backup
                find . -name "dump_*.sql" -type f -mtime +14 -delete # 14 day retention of backups

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(ls -lh /backup/dump_$now.sql | awk '{print $5}')"

                _out_bytes=$(stat -c%s /backup/dump_$now.sql)
                curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/immich-postgresql-backup" <<PGEOF || true
                backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                PGEOF
              EOT
              ]
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "immich-secrets"
                    key  = "db_password"
                  }
                }
              }
              volume_mount {
                name       = "postgresql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "postgresql-backup"
              persistent_volume_claim {
                claim_name = module.nfs_postgresql_host.claim_name
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

# POWER TOOLS

# resource "kubernetes_deployment" "powertools" {
#   metadata {
#     name      = "immich-powertools"
#    namespace = kubernetes_namespace.immich.metadata[0].name
#     labels = {
#       app = "immich-powertools"
#     }
#     annotations = {
#       "reloader.stakater.com/search" = "true"
#     }
#   }
#   spec {
#     replicas = 1
#     strategy {
#       type = "Recreate"
#     }
#     selector {
#       match_labels = {
#         app = "immich-powertools"
#       }
#     }
#     template {
#       metadata {
#         labels = {
#           app = "immich-powertools"
#         }
#         annotations = {
#           "diun.enable"       = "true"
#           "diun.include_tags" = "latest"
#         }
#       }
#       spec {

#         container {
#           image = "ghcr.io/varun-raj/immich-power-tools:latest"
#           name  = "owntracks"
#           port {
#             name           = "http"
#             container_port = 3000
#           }
#           env {
#             name  = "IMMICH_API_KEY"
#             value = "<change me>"
#           }
#           env {
#             name = "IMMICH_URL"
#             value = "http://immich-server.immich.svc.cluster.local"
#           }
#           env {
#             name  = "EXTERNAL_IMMICH_URL"
#             value = "https://immich.viktorbarzin.me"
#           }
#           env {
#             name  = "DB_USERNAME"
#             value = "immich"
#           }
#           env {
#             name  = "DB_PASSWORD"
#             value = data.vault_kv_secret_v2.secrets.data["db_password"]
#           }
#           env {
#             name = "DB_HOST"
#             value = "immich-postgresql.immich.svc.cluster.local"
#           }
#           # env {
#           #   name  = "DB_PORT"
#           #   value = "5432"
#           # }
#           env {
#             name  = "DB_DATABASE_NAME"
#             value = "immich"
#           }
#           env {
#             name  = "NODE_ENV"
#             value = "development"
#           }

#         }
#       }
#     }
#   }
# }


# resource "kubernetes_service" "powertools" {
#   metadata {
#     name      = "immich-powertools"
#    namespace = kubernetes_namespace.immich.metadata[0].name
#     labels = {
#       "app" = "immich-powertools"
#     }
#   }

#   spec {
#     selector = {
#       app = "immich-powertools"
#     }
#     port {
#       name        = "http"
#       port        = 80
#       target_port = 3000
#       protocol    = "TCP"
#     }
#   }
# }

# module "ingress-powertools" {
#   source          = "../../modules/kubernetes/ingress_factory"
#  namespace = kubernetes_namespace.immich.metadata[0].name
#   name            = "immich-powertools"
#   tls_secret_name = var.tls_secret_name
#   auth = "required"
# }
