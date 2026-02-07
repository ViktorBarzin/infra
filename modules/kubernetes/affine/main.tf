variable "tls_secret_name" {}
variable "tier" { type = string }
variable "postgresql_password" {}
variable "smtp_password" { type = string }

resource "kubernetes_namespace" "affine" {
  metadata {
    name = "affine"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.affine.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

locals {
  common_env = [
    {
      name  = "DATABASE_URL"
      value = "postgresql://affine:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/affine"
    },
    {
      name  = "REDIS_SERVER_HOST"
      value = "redis.redis.svc.cluster.local"
    },
    {
      name  = "AFFINE_INDEXER_ENABLED"
      value = "false"
    },
    {
      name  = "NODE_OPTIONS"
      value = "--max-old-space-size=4096"
    },
    # Server URL configuration
    {
      name  = "AFFINE_SERVER_EXTERNAL_URL"
      value = "https://affine.viktorbarzin.me"
    },
    {
      name  = "AFFINE_SERVER_HTTPS"
      value = "true"
    },
    # Email/SMTP configuration
    {
      name  = "MAILER_HOST"
      value = "mailserver.viktorbarzin.me"
    },
    {
      name  = "MAILER_PORT"
      value = "587"
    },
    {
      name  = "MAILER_USER"
      value = "info@viktorbarzin.me"
    },
    {
      name  = "MAILER_PASSWORD"
      value = var.smtp_password
    },
    {
      name  = "MAILER_SENDER"
      value = "AFFiNE <info@viktorbarzin.me>"
    },
  ]
}

resource "kubernetes_deployment" "affine" {
  metadata {
    name      = "affine"
    namespace = kubernetes_namespace.affine.metadata[0].name
    labels = {
      app  = "affine"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "affine"
      }
    }
    template {
      metadata {
        labels = {
          app = "affine"
        }
      }
      spec {
        # Init container to run database migrations
        init_container {
          name    = "migration"
          image   = "ghcr.io/toeverything/affine:stable"
          command = ["sh", "-c", "npx prisma migrate deploy && SERVER_FLAVOR=script node ./dist/main.js run"]

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/root/.affine/storage"
            sub_path   = "storage"
          }
          volume_mount {
            name       = "data"
            mount_path = "/root/.affine/config"
            sub_path   = "config"
          }
        }

        container {
          name  = "affine"
          image = "ghcr.io/toeverything/affine:stable"

          port {
            container_port = 3010
          }

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/root/.affine/storage"
            sub_path   = "storage"
          }
          volume_mount {
            name       = "data"
            mount_path = "/root/.affine/config"
            sub_path   = "config"
          }

          resources {
            requests = {
              memory = "512Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "4Gi"
              cpu    = "2"
            }
          }

          liveness_probe {
            http_get {
              path = "/info"
              port = 3010
            }
            initial_delay_seconds = 120
            period_seconds        = 30
            timeout_seconds       = 10
          }
          readiness_probe {
            http_get {
              path = "/info"
              port = 3010
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/affine"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "affine" {
  metadata {
    name      = "affine"
    namespace = kubernetes_namespace.affine.metadata[0].name
    labels = {
      app = "affine"
    }
  }

  spec {
    selector = {
      app = "affine"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3010
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.affine.metadata[0].name
  name            = "affine"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "500m"
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "500m"
  }
}
