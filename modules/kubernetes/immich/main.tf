variable "tls_secret_name" {}
variable "postgresql_password" {}
variable "homepage_token" {}
variable "immich_version" {
  type = string
  # Change me to upgrade
  default = "v2.3.1"
}


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
        # path   = "/mnt/main/immich/data-immich-postgresql"
        path   = "/mnt/ssd/immich/data-immich-postgresql"
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

  values = [templatefile("${path.module}/chart_values.tpl", { postgresql_password = var.postgresql_password, version = var.immich_version })]
}

# The helm one cannot be customized to use affinity settings to use the gpu node
resource "kubernetes_deployment" "immich-machine-learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = "immich"
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-machine-learning"
      }
    }
    strategy {
      type = "RollingUpdate"
    }
    template {
      metadata {
        labels = {
          app = "immich-machine-learning"
        }
      }
      spec {
        node_selector = {
          "gpu" : "true"
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
          env {
            name  = "MACHINE_LEARNING_PRELOAD__CLIP"
            value = "ViT-B-16-SigLIP2__webli"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1" # Used for inference
            }
          }
        }
        volume {
          name = "cache"
          nfs {
            path   = "/mnt/main/immich/machine-learning"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "immich-machine-learning" {
  metadata {
    name      = "immich-machine-learning"
    namespace = "immich"
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

resource "kubernetes_ingress_v1" "ingress" {
  metadata {
    namespace = "immich"
    name      = "immich"
    annotations = {
      # NOTE: when changing - test video playback from mobile and web!
      # Easy to break!

      "kubernetes.io/ingress.class"                  = "nginx"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"

      # As per https://immich.app/docs/administration/reverse-proxy
      "nginx.org/websocket-services" : "immich-server"
      # Websockets
      "nginx.ingress.kubernetes.io/proxy-set-header" : "Upgrade $http_upgrade"
      "nginx.ingress.kubernetes.io/proxy-set-header" : "Connection $connection_upgrade" # this makes a difference for web!!!
      "nginx.ingress.kubernetes.io/proxy-redirect-from" : "off"
      # Timeouts
      "nginx.ingress.kubernetes.io/proxy-read-timeout" : "6000s",
      "nginx.ingress.kubernetes.io/proxy-send-timeout" : "6000s",

      "nginx.ingress.kubernetes.io/proxy-connect-timeout" : "60s"

      # Allow big uploads
      "nginx.ingress.kubernetes.io/proxy-body-size" : "0"
      "nginx.ingress.kubernetes.io/proxy-buffering" : "off"
      "nginx.ingress.kubernetes.io/proxy-request-buffering" : "off"
      "nginx.ingress.kubernetes.io/proxy-http-version" : "1.1"
      # "nginx.ingress.kubernetes.io/client-body-buffer-size" : "512m"
      # "nginx.ingress.kubernetes.io/proxy-buffers-number" : "4"

      # More lenient DDOS protection as to not confuse with image loading
      "nginx.ingress.kubernetes.io/limit-connections" : 5000
      "nginx.ingress.kubernetes.io/limit-rps" : 100
      "nginx.ingress.kubernetes.io/limit-rpm" : 6000
      "nginx.ingress.kubernetes.io/limit-burst-multiplier" : 10

      # good for downloading big files - https://www.pdxdev.com/nginx-content-delivery/configuring-nginx-for-large-file-transfers/
      "nginx.ingress.kubernetes.io/configuration-snippet" : <<EOF
        directio 4m;
        sendfile off;
        aio on;

        limit_req_status 429;
        limit_conn_status 429;

        # Rybbit Analytics
        # Only modify HTML
        sub_filter_types text/html;
        sub_filter_once off;

        # Disable compression so sub_filter works
        proxy_set_header Accept-Encoding "";

        # Inject analytics before </head>
        sub_filter '</head>' '
        <script src="https://rybbit.viktorbarzin.me/api/script.js"
              data-site-id="35eedb7a3d2b"
              defer></script> 
        </head>';
      EOF

      "nginx.ingress.kubernetes.io/enable-modsecurity" : "false" # this is important!!!; setting it to true enables buffering and can lead to ooms when ploading big files
      "nginx.ingress.kubernetes.io/enable-owasp-modsecurity-crs" : "false"


      "gethomepage.dev/enabled"      = "true"
      "gethomepage.dev/description"  = "Photos library"
      "gethomepage.dev/icon"         = "immich.png"
      "gethomepage.dev/name"         = "Immich"
      "gethomepage.dev/widget.type"  = "immich"
      "gethomepage.dev/widget.url"   = "https://immich.viktorbarzin.me"
      "gethomepage.dev/pod-selector" = ""
      "gethomepage.dev/widget.key"   = var.homepage_token
    }
  }

  spec {
    tls {
      hosts       = ["immich.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "immich.viktorbarzin.me"
      http {
        path {
          backend {
            service {
              name = "immich-server"
              port {
                number = 2283

              }
            }
          }
        }
      }
    }
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

