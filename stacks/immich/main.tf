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
}


variable "immich_version" {
  type = string
  # Change me to upgrade
  default = "v2.7.5"
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
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-backups-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/backups"
}

module "nfs_encoded_video_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-encoded-video-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/encoded-video"
}

module "nfs_library_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-library-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/library"
}

module "nfs_profile_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-profile-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/profile"
}

module "nfs_thumbs_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-thumbs-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs-ssd/immich/thumbs"
}

module "nfs_upload_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-upload-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/immich/upload"
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
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-ml-cache-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs-ssd/immich/machine-learning"
}

# Read-only source for one-shot bulk imports into individual users' accounts
# (currently: Anca's WD Elements dump, mirrored to /srv/nfs/anca-elements from
# her Synology). Consumed only by the import Job below — NOT mounted into the
# immich-server Deployment. PVC stays after the Job is removed so videos can
# follow in batch 2.
module "nfs_anca_elements_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "immich-anca-elements-host"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.proxmox_host
  nfs_path   = "/srv/nfs/anca-elements"
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
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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

resource "kubernetes_deployment" "immich_server" {
  metadata {
    name      = "immich-server"
    namespace = kubernetes_namespace.immich.metadata[0].name

    labels = {
      app  = "immich-server"
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
        app = "immich-server"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "immich-server"
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
          name  = "immich-server"
          image = "ghcr.io/immich-app/immich-server:${var.immich_version}"

          port {
            name           = "http"
            container_port = 2283
            protocol       = "TCP"
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
            # Bumped 30 → 360 (5min → 1h): after a PG restart, immich-server
            # reindexes the clip_index + face_index vector tables before binding
            # the API port. Hundreds of thousands of rows take longer than 5min
            # on a cold cache, so the old threshold trapped us in a startup
            # crashloop after every PG restart (2026-05-24 incident).
            failure_threshold = 360
            success_threshold = 1
          }

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
              cpu    = "100m"
              memory = "8Gi"
            }
            limits = {
              memory           = "8Gi"
              "nvidia.com/gpu" = "1"
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
      app = "immich-server"
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
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].spec[0].container[0].image,  # KEEL_IGNORE_IMAGE
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
          image = "ghcr.io/immich-app/postgres:15-vectorchord0.3.0-pgvectors0.2.0"
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
              cpu    = "100m"
              memory = "5Gi"
            }
            limits = {
              memory = "5Gi"
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
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
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
          env {
            name  = "MACHINE_LEARNING_MODEL_TTL"
            value = "0"
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
              memory           = "3584Mi"
              "nvidia.com/gpu" = "1"
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

# One-shot bulk import of Anca's Synology Elements photo archive into her
# Immich account. Reads /srv/nfs/anca-elements via the RO PVC above and posts
# assets to immich-server in-cluster (bypasses ingress + CrowdSec entirely).
#
# Auth: Anca's personal Immich API key. Add to Vault `secret/immich` under key
# `anca_api_key`, then force-refresh the existing `immich-secrets` ExternalSecret:
#   kubectl annotate externalsecret immich-secrets -n immich \
#     force-sync=$(date +%s) --overwrite
#
# After successful completion: REMOVE this resource block + apply again. The
# PVC stays for a videos batch later. Filters target a photo-only subset of
# the dump (videos / installers / docs / courses banned); EXIF is preserved
# end-to-end since immich-go uploads originals byte-for-byte.
resource "kubernetes_job_v1" "anca_elements_import" {
  metadata {
    name      = "anca-elements-import"
    namespace = kubernetes_namespace.immich.metadata[0].name
    labels = {
      app  = "anca-elements-import"
      tier = local.tiers.gpu
    }
  }

  # Don't block `terragrunt apply` on the multi-hour upload — TF returns once
  # the Job is created; monitor via `kubectl logs -n immich -f job/...`.
  wait_for_completion = false

  spec {
    backoff_limit              = 20
    ttl_seconds_after_finished = 604800
    template {
      metadata {
        labels = {
          app = "anca-elements-import"
        }
      }
      spec {
        restart_policy = "OnFailure"
        container {
          name  = "immich-go"
          image = "alpine:3.20"
          command = [
            "/bin/sh",
            "-c",
            <<-EOT
              set -eu
              apk add --no-cache curl tar ca-certificates >/dev/null

              IMMICH_GO_VERSION="v0.31.0"
              cd /tmp
              echo "Downloading immich-go $${IMMICH_GO_VERSION}…"
              curl -sL "https://github.com/simulot/immich-go/releases/download/$${IMMICH_GO_VERSION}/immich-go_Linux_x86_64.tar.gz" \
                | tar -xz
              chmod +x ./immich-go

              echo "Starting upload from /data → http://immich-server.immich.svc.cluster.local:2283 …"
              exec ./immich-go upload from-folder /data \
                --server http://immich-server.immich.svc.cluster.local:2283 \
                --api-key "$${IMMICH_API_KEY}" \
                --include-extensions .jpg,.jpeg,.png,.heic,.heif,.gif,.tif,.tiff,.webp,.nef,.cr2,.dng,.raw \
                --into-album "Poze (Elements)" \
                --ban-file "filme/" --ban-file "Music/" --ban-file "carti/" \
                --ban-file "cursuri/" --ban-file "Adobe.*/" \
                --ban-file "Fullstack Web Development*/" \
                --ban-file "Contracte and CV/" --ban-file "Cv/" \
                --ban-file "docum/" --ban-file "finance/" \
                --ban-file "download/" --ban-file "kit/" \
                --ban-file "csp/" --ban-file "KOREAN/" \
                --ban-file "System Volume Information/" \
                --pause-immich-jobs=false \
                --concurrent-tasks 20 \
                --client-timeout 1h \
                --no-ui \
                --on-errors continue
            EOT
          ]
          env {
            name = "IMMICH_API_KEY"
            value_from {
              secret_key_ref {
                name = "immich-secrets"
                key  = "anca_api_key"
              }
            }
          }
          volume_mount {
            name       = "anca-elements"
            mount_path = "/data"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
        volume {
          name = "anca-elements"
          persistent_volume_claim {
            claim_name = module.nfs_anca_elements_host.claim_name
            read_only  = true
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
  depends_on = [kubernetes_manifest.external_secret]
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
