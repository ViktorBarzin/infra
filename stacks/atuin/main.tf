variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "atuin_postgresql_password" { type = string }

resource "kubernetes_namespace" "atuin" {
  metadata {
    name = "atuin"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.atuin.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "atuin" {
  wait_for_rollout = false
  metadata {
    name      = "atuin"
    namespace = kubernetes_namespace.atuin.metadata[0].name
    labels = {
      app  = "atuin"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "atuin"
      }
    }
    template {
      metadata {
        labels = {
          app = "atuin"
        }
      }
      spec {
        container {
          name  = "atuin"
          image = "ghcr.io/atuinsh/atuin:3f775df"

          args = ["start"]

          port {
            container_port = 8888
          }

          env {
            name  = "ATUIN_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "ATUIN_PORT"
            value = "8888"
          }
          env {
            name  = "ATUIN_OPEN_REGISTRATION"
            value = "false"
          }
          env {
            name  = "ATUIN_DB_URI"
            value = "postgres://atuin:${var.atuin_postgresql_password}@${var.postgresql_host}:5432/atuin"
          }
          env {
            name  = "RUST_LOG"
            value = "info"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }

          resources {
            requests = {
              memory = "16Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "128Mi"
              cpu    = "100m"
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8888
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8888
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          nfs {
            server = var.nfs_server
            path   = "/mnt/main/atuin"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "atuin" {
  metadata {
    name      = "atuin"
    namespace = kubernetes_namespace.atuin.metadata[0].name
    labels = {
      app = "atuin"
    }
  }
  spec {
    selector = {
      app = "atuin"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8888
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.atuin.metadata[0].name
  name            = "atuin"
  tls_secret_name = var.tls_secret_name
}
