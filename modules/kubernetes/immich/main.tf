variable "tls_secret_name" {}
variable "postgresql_password" {}
variable "homepage_token" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "immich"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "immich"
    # Container comms are broken - seems due to tls
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

resource "kubernetes_persistent_volume" "immich-postgresql" {
  metadata {
    name = "immich-postgresql"
  }
  spec {
    capacity = {
      "storage" = "10Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/data-immich-postgresql"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "immich" {
  metadata {
    name = "immich"
  }
  spec {
    capacity = {
      "storage" = "100Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/immich"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "immich-typesense-tsdata" {
  metadata {
    name = "immich-typesense-tsdata"
  }
  spec {
    capacity = {
      "storage" = "5Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/typesense-tsdata"
        server = "10.0.10.15"
      }
    }
  }
}
resource "kubernetes_persistent_volume_claim" "immich" {
  metadata {
    name      = "immich"
    namespace = "immich"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        "storage" = "20Gi"
      }
    }
    volume_name = "immich"
  }
}
resource "kubernetes_deployment" "immich-postgres" {
  metadata {
    name      = "immich-postgresql"
    namespace = "immich"
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
            name  = "POSTGRES_PASSWORD"
            value = var.postgresql_password
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
            value = "HDD"
          }
          volume_mount {
            name       = "postgresql-persistent-storage"
            mount_path = "/var/lib/postgresql/data"
          }
        }
        volume {
          name = "postgresql-persistent-storage"
          nfs {
            path   = "/mnt/main/immich/data-immich-postgresql"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "immich-postgresql" {
  metadata {
    name      = "immich-postgresql"
    namespace = "immich"
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
resource "helm_release" "immich" {
  namespace = "immich"
  name      = "immich"

  repository = "https://immich-app.github.io/immich-charts"
  chart      = "immich"
  atomic     = true
  version    = "0.9.3"
  timeout    = 6000

  values = [templatefile("${path.module}/chart_values.tpl", { postgresql_password = var.postgresql_password })]
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "immich"
  name            = "immich"
  tls_secret_name = var.tls_secret_name
  port            = 2283
  service_name    = "immich-server"
  extra_annotations = {
    "kubernetes.io/ingress.class" = "nginx"
    # WARNING: When changing any of the below settings, ensure that large file uploads continue working
    "nginx.ingress.kubernetes.io/proxy-read-timeout" : "6000",
    "nginx.ingress.kubernetes.io/proxy-send-timeout" : "6000",
    "nginx.ingress.kubernetes.io/proxy-connect-timeout" : "6000"
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    # "nginx.ingress.kubernetes.io/proxy-body-size" : "5G",
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
    # "nginx.ingress.kubernetes.io/proxy-buffering" : "on"
    # "nginx.ingress.kubernetes.io/proxy-max-temp-file-size" : "4096m"
    # "nginx.ingress.kubernetes.io/proxy-request-buffering" : "off"
    # "nginx.ingress.kubernetes.io/client-body-buffer-size" : "5G"
    # "nginx.ingress.kubernetes.io/proxy-buffer-size" : "16k"
    # "nginx.ingress.kubernetes.io/proxy-buffers-number" : "8"


    # "nginx.ingress.kubernetes.io/client-body-buffer-size" : "5000m"
    # "nginx.ingress.kubernetes.io/proxy-buffers-number" : "8"
    # "nginx.ingress.kubernetes.io/proxy-buffer-size" : "16k"
    # "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
    # "nginx.ingress.kubernetes.io/affinity" : "cookie"
    # "nginx.ingress.kubernetes.io/affinity-mode" : "persistent"
    # "nginx.ingress.kubernetes.io/session-cookie-change-on-failure" : true
    # "nginx.ingress.kubernetes.io/session-cookie-expires" : 172800
    # "nginx.ingress.kubernetes.io/session-cookie-max-age" : 172800
    # "nginx.ingress.kubernetes.io/session-cookie-name" : "STICKY_SESSION"
    # "nginx.ingress.kubernetes.io/use-regex" : false
    "nginx.org/websocket-services" : "immich-server"

    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/description"  = "Photos library"
    "gethomepage.dev/icon"         = "immich.png"
    "gethomepage.dev/name"         = "Immich"
    "gethomepage.dev/widget.type"  = "immich"
    "gethomepage.dev/widget.url"   = "https://immich.viktorbarzin.me"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.key"   = var.homepage_token

    # location ~* \.(png|jpg|jpeg|gif|webp|svg)$ {
    #   expires 1M;
    #   add_header Cache-Control "public, max-age=31536000, immutable";
    # }
    "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOF
        proxy_cache static-cache;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_404 http_500 http_502 http_503 http_504;
        proxy_cache_bypass $http_x_purge;
        add_header X-Cache-Status $upstream_cache_status;
        EOF
    "nginx.ingress.kubernetes.io/limit-connections" : 0
    "nginx.ingress.kubernetes.io/limit-rps" : 0
    "nginx.ingress.kubernetes.io/limit-rpm" : 0
  }
}


resource "kubernetes_cron_job_v1" "postgresql-backup" {
  metadata {
    name      = "postgresql-backup"
    namespace = "immich"
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
                export now=$(date +"%Y_%m_%d_%H_%M")
                PGPASSWORD=${var.postgresql_password} pg_dumpall  -h immich-postgresql -U immich > /backup/dump_$now.sql

                # Rotate - delete last log file
                cd /backup
                find . -name "dump_*.sql" -type f -mtime +14 -delete # 14 day retention of backups
              EOT
              ]
              volume_mount {
                name       = "postgresql-backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "postgresql-backup"
              nfs {
                path   = "/mnt/main/immich/data-immich-postgresql"
                server = "10.0.10.15"
              }
            }
          }
        }
      }
    }
  }
}

# POWER TOOLS

# resource "kubernetes_deployment" "powertools" {
#   metadata {
#     name      = "immich-powertools"
#     namespace = "immich"
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
#             value = var.postgresql_password
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
#     namespace = "immich"
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
#   source          = "../ingress_factory"
#   namespace       = "immich"
#   name            = "immich-powertools"
#   tls_secret_name = var.tls_secret_name
#   protected       = true
# }

