variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "uptime-kuma" {
  metadata {
    name = "uptime-kuma"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  tls_secret_name = var.tls_secret_name
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

          port {
            container_port = 3001
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/uptime-kuma"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.uptime-kuma.metadata[0].name
  name            = "uptime"
  tls_secret_name = var.tls_secret_name
  service_name    = "uptime-kuma"
  extra_annotations = {
    "nginx.org/websocket-services" = "uptime-kuma"
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/description"  = "Uptime monitor"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "uptime-kuma.png"
    "gethomepage.dev/name"         = "Uptime Kuma"
    "gethomepage.dev/widget.type"  = "uptimekuma"
    "gethomepage.dev/widget.url"   = "https://uptime.viktorbarzin.me"
    "gethomepage.dev/widget.slug"  = "cluster-internal"
    "gethomepage.dev/pod-selector" = ""
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
#                 server = "10.0.10.15"
#                 path   = "/mnt/main/uptime-kuma"
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }
