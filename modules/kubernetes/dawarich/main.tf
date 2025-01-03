variable "tls_secret_name" {}
variable "database_password" {}

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
          "diun.enable"          = "true"
          "diun.include_tags"    = "latest"
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = 9394
        }
      }
      spec {

        container {
          image = "freikin/dawarich:latest"
          name  = "dawarich"
          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "prometheus"
            container_port = 9394
          }
          command = ["dev-entrypoint.sh"]
          args    = ["bin/dev"]
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

          #   volume_mount {
          #     name       = "watched"
          #     mount_path = "/var/app/tmp/imports/watched"
          #   }
        }
        container {
          image   = "freikin/dawarich:latest"
          name    = "dawarich-sidekiq"
          command = ["dev-entrypoint.sh"]
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
            name  = "DISTANCE_UNIT"
            value = "km"
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

          #   volume_mount {
          #     name       = "watched"
          #     mount_path = "/var/app/tmp/imports/watched"
          #   }
        }
        volume {
          name = "watched"
          nfs {
            path   = "/mnt/main/dawarich"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}


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

resource "kubernetes_ingress_v1" "dawarich" {
  metadata {
    name      = "dawarich"
    namespace = "dawarich"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      #   "nginx.ingress.kubernetes.io/auth-type"   = "basic" # support only basic auth; can't use authentik
      #   "nginx.ingress.kubernetes.io/auth-secret" = kubernetes_secret.basic_auth.metadata[0].name
      #   "nginx.ingress.kubernetes.io/auth-realm"  = "Authentication Required"
    }
  }

  spec {
    tls {
      hosts       = ["dawarich.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "dawarich.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "dawarich"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
