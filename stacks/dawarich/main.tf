variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_version" {
  type    = string
  default = "1.6.1"
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }

resource "kubernetes_namespace" "dawarich" {
  metadata {
    name = "dawarich"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "dawarich-secrets"
      namespace = "dawarich"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "dawarich-secrets"
      }
      dataFrom = [{
        extract = {
          key = "dawarich"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.dawarich]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.dawarich.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "dawarich" {
  metadata {
    name      = "dawarich"
    namespace = kubernetes_namespace.dawarich.metadata[0].name
    labels = {
      app  = "dawarich"
      tier = local.tiers.edge
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
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^v?\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432,redis.redis:6379"
        }
      }
      spec {

        container {
          image = "freikin/dawarich:${var.image_version}"
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
          args    = ["bin/rails", "server", "-p", "3000", "-b", "::"]
          env {
            name  = "REDIS_URL"
            value = "redis://${var.redis_host}:6379"
          }
          env {
            name  = "DATABASE_HOST"
            value = var.postgresql_host
          }
          env {
            name  = "DATABASE_USERNAME"
            value = "dawarich"
          }
          env {
            name = "DATABASE_PASSWORD"
            value_from {
              secret_key_ref {
                name = "dawarich-secrets"
                key  = "db_password"
              }
            }
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
          # env {
          #   name  = "PROMETHEUS_EXPORTER_ENABLED"
          #   value = "true"
          # }
          # env {
          #   name  = "PROMETHEUS_EXPORTER_PORT"
          #   value = "9394"
          # }
          # env {
          #   name  = "PROMETHEUS_EXPORTER_HOST"
          #   value = "0.0.0.0"
          # }
          env {
            name  = "RAILS_ENV"
            value = "production"
          }
          env {
            name = "SECRET_KEY_BASE"
            value_from {
              secret_key_ref {
                name = "dawarich-secrets"
                key  = "secret_key_base"
              }
            }
          }
          env {
            name  = "RAILS_LOG_TO_STDOUT"
            value = "true"
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
          resources {
            requests = {
              cpu    = "15m"
              memory = "896Mi"
            }
            limits = {
              memory = "896Mi"
            }
          }
        }
        # container {
        #   image   = "freikin/dawarich:${var.image_version}"
        #   name    = "dawarich-sidekiq"
        #   command = ["sidekiq-entrypoint.sh"]
        #   args    = ["bundle exec sidekiq"]
        #   env {
        #     name  = "REDIS_URL"
        #     value = "redis://redis.redis.svc.cluster.local:6379"
        #   }
        #   env {
        #     name  = "DATABASE_HOST"
        #     value = "postgresql.dbaas"
        #   }
        #   env {
        #     name  = "DATABASE_USERNAME"
        #     value = "dawarich"
        #   }
        #   env {
        #     name  = "DATABASE_PASSWORD"
        #     value = data.vault_kv_secret_v2.secrets.data["db_password"]
        #   }
        #   env {
        #     name  = "DATABASE_NAME"
        #     value = "dawarich"
        #   }
        #   env {
        #     name  = "MIN_MINUTES_SPENT_IN_CITY"
        #     value = "60"
        #   }
        #   env {
        #     name  = "BACKGROUND_PROCESSING_CONCURRENCY"
        #     value = "10"
        #   }
        #   env {
        #     name  = "ENABLE_TELEMETRY"
        #     value = "true"
        #   }
        #   env {
        #     name  = "APPLICATION_HOST"
        #     value = "dawarich.viktorbarzin.me"
        #   }
        #   # env {
        #   #   name  = "PROMETHEUS_EXPORTER_ENABLED"
        #   #   value = "false"
        #   # }
        #   # env {
        #   #   name  = "PROMETHEUS_EXPORTER_HOST"
        #   #   value = "dawarich.dawarich"
        #   # }
        #   # env {
        #   #   name  = "PHOTON_API_HOST"
        #   #   value = "photon.dawarich:2322"
        #   #   # value = "photon.komoot.io"
        #   # }
        #   # env {
        #   #   name  = "PHOTON_API_USE_HTTPS"
        #   #   value = "false"
        #   # }
        #   env {
        #     name  = "GEOAPIFY_API_KEY"
        #     value = data.vault_kv_secret_v2.secrets.data["geoapify_api_key"]
        #   }
        #   env {
        #     name  = "SELF_HOSTED"
        #     value = "true"
        #   }

        #   #   volume_mount {
        #   #     name       = "watched"
        #   #     mount_path = "/var/app/tmp/imports/watched"
        #   #   }
        # }
      }
    }
  }
}


# resource "kubernetes_deployment" "photon" {
#   metadata {
#     name      = "photon"
#    namespace = kubernetes_namespace.dawarich.metadata[0].name
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
#             server = var.nfs_server
#           }
#         }
#       }

#     }
#   }
# }



resource "kubernetes_service" "dawarich" {
  metadata {
    name      = "dawarich"
    namespace = kubernetes_namespace.dawarich.metadata[0].name
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
#    namespace = kubernetes_namespace.dawarich.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.dawarich.metadata[0].name
  name            = "dawarich"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Dawarich"
    "gethomepage.dev/description"  = "Location history"
    "gethomepage.dev/icon"         = "dawarich.png"
    "gethomepage.dev/group"        = "Smart Home"
    "gethomepage.dev/pod-selector" = ""
  }
}
