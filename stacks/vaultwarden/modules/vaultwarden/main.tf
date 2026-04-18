variable "tls_secret_name" {}
variable "tier" { type = string }
variable "smtp_password" {}
variable "mail_host" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "vaultwarden" {
  metadata {
    name = "vaultwarden"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "vaultwarden_data_encrypted" {
  metadata {
    name      = "vaultwarden-data-encrypted"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
    labels = {
      app  = "vaultwarden"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "vaultwarden"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          "app" = "vaultwarden"
        }
      }
      spec {
        container {
          image = "vaultwarden/server:1.35.7"
          name  = "vaultwarden"

          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          env {
            name  = "DOMAIN"
            value = "https://vaultwarden.viktorbarzin.me"
          }
          # env {
          #   name  = "ADMIN_TOKEN"
          #   value = ""
          # }
          env {
            name  = "SMTP_HOST"
            value = var.mail_host
          }
          env {
            name  = "SMTP_FROM"
            value = "vaultwarden@viktorbarzin.me"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_SECURITY"
            value = "starttls"
          }
          env {
            name  = "SMTP_USERNAME"
            value = "vaultwarden@viktorbarzin.me"
          }
          env {
            name  = "SMTP_PASSWORD"
            value = var.smtp_password
          }

          port {
            container_port = 80
          }
          liveness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.vaultwarden_data_encrypted.metadata[0].name
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

resource "kubernetes_service" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
    labels = {
      "app" = "vaultwarden"
    }
  }

  spec {
    selector = {
      app = "vaultwarden"
    }
    port {
      name     = "http"
      port     = "80"
      protocol = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  name            = "vaultwarden"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Vaultwarden"
    "gethomepage.dev/description"  = "Password manager"
    "gethomepage.dev/icon"         = "vaultwarden.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# -----------------------------------------------------------------------------
# Backup — Every 6h SQLite + data files to NFS
# -----------------------------------------------------------------------------

module "nfs_vaultwarden_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "vaultwarden-backup-host"
  namespace  = kubernetes_namespace.vaultwarden.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/vaultwarden-backup"
}

resource "kubernetes_cron_job_v1" "vaultwarden-backup" {
  metadata {
    name      = "vaultwarden-backup"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 */6 * * *"
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
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "vaultwarden"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "vaultwarden-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache sqlite
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                now=$(date +"%Y_%m_%d_%H_%M")
                # Pre-flight: verify source DB is healthy before backing up
                if ! sqlite3 /data/db.sqlite3 "PRAGMA integrity_check;" | grep -q "^ok$"; then
                  echo "ERROR: source database failed integrity check, skipping backup"
                  exit 1
                fi
                mkdir -p /backup/$now
                # Safe SQLite backup (handles WAL/locks)
                sqlite3 /data/db.sqlite3 ".backup /backup/$now/db.sqlite3"
                # Verify the backup copy is also healthy
                if ! sqlite3 /backup/$now/db.sqlite3 "PRAGMA integrity_check;" | grep -q "^ok$"; then
                  echo "ERROR: backup copy failed integrity check, removing"
                  rm -rf /backup/$now
                  exit 1
                fi
                # Copy RSA keys, attachments, sends, config
                cp -a /data/rsa_key.pem /data/rsa_key.pub.pem /backup/$now/ 2>/dev/null || true
                cp -a /data/attachments /backup/$now/ 2>/dev/null || true
                cp -a /data/sends /backup/$now/ 2>/dev/null || true
                cp -a /data/config.json /backup/$now/ 2>/dev/null || true
                # Rotate — 30 day retention
                find /backup -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(du -sh /backup/$$now | awk '{print $$1}')"

                _out_bytes=$(du -sb /backup/$now | awk '{print $1}')
                wget -qO- --post-data "backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/vaultwarden-backup" || true
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
                claim_name = kubernetes_persistent_volume_claim.vaultwarden_data_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_vaultwarden_backup_host.claim_name
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
}

# -----------------------------------------------------------------------------
# Integrity Check — Hourly SQLite PRAGMA check, pushes metric to Prometheus
# -----------------------------------------------------------------------------

resource "kubernetes_cron_job_v1" "vaultwarden-integrity-check" {
  metadata {
    name      = "vaultwarden-integrity-check"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "30 * * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "vaultwarden"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "integrity-check"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euo pipefail
                apk add --no-cache sqlite curl >/dev/null 2>&1
                PUSHGW="http://prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
                result=$(sqlite3 /data/db.sqlite3 "PRAGMA integrity_check;" 2>&1)
                if echo "$$result" | grep -q "^ok$$"; then
                  echo "SQLite integrity check passed"
                  cat <<METRICS | curl -s --data-binary @- "$$PUSHGW/metrics/job/vaultwarden-integrity/instance/vaultwarden"
vaultwarden_sqlite_integrity_ok 1
vaultwarden_sqlite_integrity_check_timestamp $(date +%s)
METRICS
                else
                  echo "ERROR: SQLite integrity check FAILED: $$result"
                  cat <<METRICS | curl -s --data-binary @- "$$PUSHGW/metrics/job/vaultwarden-integrity/instance/vaultwarden"
vaultwarden_sqlite_integrity_ok 0
vaultwarden_sqlite_integrity_check_timestamp $(date +%s)
METRICS
                  exit 1
                fi
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.vaultwarden_data_encrypted.metadata[0].name
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
}
