variable "tls_secret_name" {}
variable "database_password" {}
variable "geoapify_api_key" {}

resource "kubernetes_namespace" "dawarich" {
  metadata {
    name = "dawarich"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "dawarich"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "dawarich" {
  metadata {
    name      = "dawarich"
    namespace = "dawarich"
    labels = {
      app = "dawarich"
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
        app = "dawarich"
      }
    }
    template {
      metadata {
        labels = {
          app = "dawarich"
        }
        annotations = {
          # "diun.enable"          = "true"
          # "diun.include_tags"    = "latest"
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = 9394
        }
      }
      spec {

        container {
          image = "freikin/dawarich:0.27.1"
          name  = "dawarich"
          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "prometheus"
            container_port = 9394
          }
          command = ["web-entrypoint.sh"]
          args    = ["bin/dev"]
          env {
            name  = "REDIS_URL"
            value = "redis://redis.redis:6379/0"
          }
          env {
            name  = "DATABASE_HOST"
            value = "postgresql.dbaas"
          }
          env {
            name  = "DATABASE_USERNAME"
            value = "dawarich"
          }
          env {
            name  = "DATABASE_PASSWORD"
            value = var.database_password
          }
          env {
            name  = "DATABASE_NAME"
            value = "dawarich"
          }
          env {
            name  = "MIN_MINUTES_SPENT_IN_CITY"
            value = "60"
          }
          env {
            name  = "TIME_ZONE"
            value = "Europe/London"
          }
          env {
            name  = "DISTANCE_UNIT"
            value = "km"
          }
          env {
            name  = "ENABLE_TELEMETRY"
            value = "true"
          }
          env {
            name  = "APPLICATION_HOSTS"
            value = "dawarich.viktorbarzin.me"
          }
          env {
            name  = "PROMETHEUS_EXPORTER_ENABLED"
            value = "true"
          }
          env {
            name  = "PROMETHEUS_EXPORTER_PORT"
            value = "9394"
          }
          env {
            name  = "PROMETHEUS_EXPORTER_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "SELF_HOSTED"
            value = "true"
          }
          # env {
          #   name  = "PHOTON_API_HOST"
          #   value = "photon.dawarich"
          # }


          #   volume_mount {
          #     name       = "watched"
          #     mount_path = "/var/app/tmp/imports/watched"
          #   }
        }
        container {
          image   = "freikin/dawarich:0.27.1"
          name    = "dawarich-sidekiq"
          command = ["sidekiq-entrypoint.sh"]
          args    = ["sidekiq"]
          env {
            name  = "REDIS_URL"
            value = "redis://redis.redis.svc.cluster.local:6379/0"
          }
          env {
            name  = "DATABASE_HOST"
            value = "postgresql.dbaas"
          }
          env {
            name  = "DATABASE_USERNAME"
            value = "dawarich"
          }
          env {
            name  = "DATABASE_PASSWORD"
            value = var.database_password
          }
          env {
            name  = "DATABASE_NAME"
            value = "dawarich"
          }
          env {
            name  = "MIN_MINUTES_SPENT_IN_CITY"
            value = "60"
          }
          env {
            name  = "BACKGROUND_PROCESSING_CONCURRENCY"
            value = "10"
          }
          env {
            name  = "ENABLE_TELEMETRY"
            value = "true"
          }
          env {
            name  = "APPLICATION_HOST"
            value = "dawarich.viktorbarzin.me"
          }
          env {
            name  = "PROMETHEUS_EXPORTER_ENABLED"
            value = "false"
          }
          env {
            name  = "PROMETHEUS_EXPORTER_HOST"
            value = "dawarich.dawarich"
          }
          # env {
          #   name  = "PHOTON_API_HOST"
          #   value = "photon.dawarich:2322"
          #   # value = "photon.komoot.io"
          # }
          # env {
          #   name  = "PHOTON_API_USE_HTTPS"
          #   value = "false"
          # }
          env {
            name  = "GEOAPIFY_API_KEY"
            value = var.geoapify_api_key
          }
          env {
            name  = "SELF_HOSTED"
            value = "true"
          }

          #   volume_mount {
          #     name       = "watched"
          #     mount_path = "/var/app/tmp/imports/watched"
          #   }
        }
      }
    }
  }
}


# resource "kubernetes_deployment" "photon" {
#   metadata {
#     name      = "photon"
#     namespace = "dawarich"
#     labels = {
#       app = "photon"
#     }
#   }
#   spec {
#     replicas = 1
#     strategy {
#       type = "Recreate"
#     }
#     selector {
#       match_labels = {
#         app = "photon"
#       }
#     }
#     template {
#       metadata {
#         labels = {
#           app = "photon"
#         }
#       }
#       spec {

#         container {
#           image = "rtuszik/photon-docker:latest"
#           name  = "photon"
#           port {
#             name           = "tcp"
#             container_port = 2322
#           }
#           env {
#             name  = "COUNTRY_CODE"
#             value = "bg"
#           }

#           volume_mount {
#             name       = "data"
#             mount_path = "/photon/photon_data"
#           }
#         }
#         volume {
#           name = "data"
#           nfs {
#             path   = "/mnt/main/photon"
#             server = "10.0.10.15"
#           }
#         }
#       }

#     }
#   }
# }



resource "kubernetes_service" "dawarich" {
  metadata {
    name      = "dawarich"
    namespace = "dawarich"
    labels = {
      "app" = "dawarich"
    }
  }

  spec {
    selector = {
      app = "dawarich"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
      protocol    = "TCP"
    }
  }
}

# resource "kubernetes_service" "photon" {
#   metadata {
#     name      = "photon"
#     namespace = "dawarich"
#     labels = {
#       "app" = "photon"
#     }
#   }

#   spec {
#     selector = {
#       app = "photon"
#     }
#     port {
#       name        = "http"
#       port        = 2322
#       target_port = 2322
#       protocol    = "TCP"
#     }
#   }
# }
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "dawarich"
  name            = "dawarich"
  tls_secret_name = var.tls_secret_name
}
