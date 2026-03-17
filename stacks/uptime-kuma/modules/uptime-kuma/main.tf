variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "uptime-kuma" {
  metadata {
    name = "uptime-kuma"
    labels = {
      tier = var.tier
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "uptime-kuma-data"
  namespace  = kubernetes_namespace.uptime-kuma.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/uptime-kuma"
}

resource "kubernetes_deployment" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
    labels = {
      app  = "uptime-kuma"
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
        app = "uptime-kuma"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "latest"
        }
        labels = {
          app = "uptime-kuma"
        }
      }
      spec {
        container {
          image = "louislam/uptime-kuma:2"
          name  = "uptime-kuma"

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          port {
            container_port = 3001
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3001
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3001
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
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
resource "kubernetes_service" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
    labels = {
      "app" = "uptime-kuma"
    }
  }

  spec {
    selector = {
      app = "uptime-kuma"
    }
    port {
      port        = "80"
      target_port = "3001"
    }
  }
}
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  name            = "uptime"
  tls_secret_name = var.tls_secret_name
  service_name    = "uptime-kuma"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Uptime monitor"
    "gethomepage.dev/group"       = "Core Platform"
    "gethomepage.dev/icon" : "uptime-kuma.png"
    "gethomepage.dev/name"         = "Uptime Kuma"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "uptimekuma"
    "gethomepage.dev/widget.url"   = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
    "gethomepage.dev/widget.slug"  = "infra"
  }
  rybbit_site_id = "8fef77b1f7fe"
}

# CronJob for daily SQLite backups # no longer needed as we're using the mysql
# resource "kubernetes_cron_job_v1" "sqlite-backup" {
#   metadata {
#     name      = "backup"
#    namespace = kubernetes_namespace.uptime-kuma.metadata[0].name
#   }
#   spec {
#     concurrency_policy        = "Replace"
#     failed_jobs_history_limit = 5
#     schedule                  = "0 0 * * *"
#     # schedule                      = "* * * * *"
#     starting_deadline_seconds     = 10
#     successful_jobs_history_limit = 3
#     job_template {
#       metadata {}
#       spec {
#         active_deadline_seconds    = 600 # should finish in 10 minutes
#         backoff_limit              = 3
#         ttl_seconds_after_finished = 10
#         template {
#           metadata {}
#           spec {
#             container {
#               name  = "backup"
#               image = "alpine/sqlite:latest"
#               command = ["/bin/sh", "-c", <<-EOT
#                 set -e
#                 export now=$(date +"%Y_%m_%d_%H_%M")
#                 echo "Backing up SQLite database to /app/data/backup/backup_$now.sqlite"
#                 sqlite3 /app/data/kuma.db ".backup /app/data/backup/backup_$now.sqlite"
#                 echo "Backup completed. Deleting old backups..."

#                 # Rotate - delete last log file
#                 cd /app/data/backup
#                 find . -name "*.sqlite" -type f -mtime +7 -delete # 7 day retention of backups
#                 echo "Old backups deleted."
#               EOT
#               ]
#               volume_mount {
#                 name       = "data"
#                 mount_path = "/app/data"
#               }
#             }
#             volume {
#               name = "data"
#               nfs {
#                 server = var.nfs_server
#                 path   = "/mnt/main/uptime-kuma"
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }
