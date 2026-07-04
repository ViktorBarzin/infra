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
