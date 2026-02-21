variable "tls_secret_name" {}
variable "tier" { type = string }
variable "postgresql_password" {}
variable "secret_key" { type = string }

resource "kubernetes_namespace" "health" {
  metadata {
    name = "health"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.health.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app  = "health"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "health"
      }
    }
    template {
      metadata {
        labels = {
          app = "health"
        }
      }
      spec {
        container {
          name  = "health"
          image = "viktorbarzin/health:latest"

          port {
            container_port = 3000
          }

          env {
            name  = "DATABASE_URL"
            value = "postgresql+asyncpg://health:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/health"
          }
          env {
            name  = "SECRET_KEY"
            value = var.secret_key
          }
          env {
            name  = "UPLOAD_DIR"
            value = "/data/uploads"
          }
          env {
            name  = "WEBAUTHN_RP_ID"
            value = "health.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_ORIGIN"
            value = "https://health.viktorbarzin.me"
          }
          env {
            name  = "COOKIE_SECURE"
            value = "true"
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/data/uploads"
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "1Gi"
              cpu    = "1"
            }
          }
        }
        volume {
          name = "uploads"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/health"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app = "health"
    }
  }

  spec {
    selector = {
      app = "health"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.health.metadata[0].name
  name            = "health"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "100m"
}
