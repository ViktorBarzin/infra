variable "tls_secret_name" {}
variable "tier" { type = string }
variable "postgresql_password" {}
variable "cookie_secret" {}
variable "captcha_salt" {}

locals {
  domain = "mcaptcha.viktorbarzin.me"
  port   = 7000
}

resource "kubernetes_namespace" "mcaptcha" {
  metadata {
    name = "mcaptcha"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.mcaptcha.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# mCaptcha requires a special Redis with the mcaptcha/cache module loaded
resource "kubernetes_deployment" "mcaptcha_redis" {
  metadata {
    name      = "mcaptcha-redis"
    namespace = kubernetes_namespace.mcaptcha.metadata[0].name
    labels = {
      app  = "mcaptcha-redis"
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "mcaptcha-redis"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "mcaptcha-redis"
        }
      }

      spec {
        container {
          image = "mcaptcha/cache:latest"
          name  = "redis"

          port {
            container_port = 6379
          }

          resources {
            requests = {
              memory = "64Mi"
              cpu    = "25m"
            }
            limits = {
              memory = "128Mi"
              cpu    = "200m"
            }
          }

          liveness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            tcp_socket {
              port = 6379
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mcaptcha_redis" {
  metadata {
    name      = "mcaptcha-redis"
    namespace = kubernetes_namespace.mcaptcha.metadata[0].name
    labels = {
      app = "mcaptcha-redis"
    }
  }

  spec {
    selector = {
      app = "mcaptcha-redis"
    }
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

resource "kubernetes_deployment" "mcaptcha" {
  metadata {
    name      = "mcaptcha"
    namespace = kubernetes_namespace.mcaptcha.metadata[0].name
    labels = {
      app  = "mcaptcha"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "mcaptcha"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "mcaptcha"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }

      spec {
        container {
          image = "mcaptcha/mcaptcha:latest"
          name  = "mcaptcha"

          port {
            container_port = local.port
          }

          # Required configuration
          env {
            name  = "MCAPTCHA_server_DOMAIN"
            value = local.domain
          }

          env {
            name  = "MCAPTCHA_server_COOKIE_SECRET"
            value = var.cookie_secret
          }

          env {
            name  = "MCAPTCHA_captcha_SALT"
            value = var.captcha_salt
          }

          # Server configuration
          env {
            name  = "PORT"
            value = tostring(local.port)
          }

          env {
            name  = "MCAPTCHA_server_IP"
            value = "0.0.0.0"
          }

          env {
            name  = "MCAPTCHA_server_PROXY_HAS_TLS"
            value = "true"
          }

          # Database configuration (PostgreSQL)
          env {
            name  = "DATABASE_URL"
            value = "postgres://mcaptcha:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/mcaptcha"
          }

          # Redis configuration (using mcaptcha/cache module)
          env {
            name  = "MCAPTCHA_redis_URL"
            value = "redis://mcaptcha-redis.mcaptcha.svc.cluster.local:6379"
          }

          # Feature flags
          env {
            name = "MCAPTCHA_allow_registration"
            # value = "true"
            value = "false"
          }

          env {
            name  = "MCAPTCHA_allow_demo"
            value = "false"
          }

          env {
            name  = "MCAPTCHA_commercial"
            value = "false"
          }

          env {
            name  = "MCAPTCHA_captcha_ENABLE_STATS"
            value = "true"
          }

          env {
            name  = "MCAPTCHA_captcha_GC"
            value = "30"
          }

          env {
            name  = "MCAPTCHA_debug"
            value = "false"
          }
          env {
            name  = "RUST_BACKTRACE"
            value = "1"
          }

          resources {
            requests = {
              memory = "64Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "256Mi"
              cpu    = "500m"
            }
          }

          # Health checks
          liveness_probe {
            http_get {
              path = "/"
              port = local.port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.port
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mcaptcha" {
  metadata {
    name      = "mcaptcha"
    namespace = kubernetes_namespace.mcaptcha.metadata[0].name
    labels = {
      "app" = "mcaptcha"
    }
  }

  spec {
    selector = {
      app = "mcaptcha"
    }
    port {
      name        = "http"
      port        = 80
      target_port = local.port
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.mcaptcha.metadata[0].name
  name            = "mcaptcha"
  tls_secret_name = var.tls_secret_name
}
