variable "tls_secret_name" { type = string }
variable "health_postgresql_password" { type = string }
variable "health_secret_key" { type = string }
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }


resource "kubernetes_namespace" "health" {
  metadata {
    name = "health"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.health.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_uploads" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "health-uploads"
  namespace  = kubernetes_namespace.health.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/health"
}

resource "kubernetes_deployment" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app  = "health"
      tier = local.tiers.aux
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
            value = "postgresql+asyncpg://health:${var.health_postgresql_password}@${var.postgresql_host}:5432/health"
          }
          env {
            name  = "SECRET_KEY"
            value = var.health_secret_key
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
              memory = "64Mi"
              cpu    = "15m"
            }
            limits = {
              memory = "256Mi"
              cpu    = "250m"
            }
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = module.nfs_uploads.claim_name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.health.metadata[0].name
  name            = "health"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "100m"
}
