variable "tls_secret_name" { type = string }
variable "affine_postgresql_password" { type = string }
variable "mailserver_accounts" { type = map(any) }
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "mail_host" { type = string }


resource "kubernetes_namespace" "affine" {
  metadata {
    name = "affine"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.affine.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

locals {
  common_env = [
    {
      name  = "DATABASE_URL"
      value = "postgresql://affine:${var.affine_postgresql_password}@${var.postgresql_host}:5432/affine"
    },
    {
      name  = "REDIS_SERVER_HOST"
      value = var.redis_host
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
      value = var.mail_host
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
      value = var.mailserver_accounts["info@viktorbarzin.me"]
    },
    {
      name  = "MAILER_SENDER"
      value = "AFFiNE <info@viktorbarzin.me>"
    },
  ]
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "affine-data"
  namespace  = kubernetes_namespace.affine.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/affine"
}

resource "kubernetes_deployment" "affine" {
  metadata {
    name      = "affine"
    namespace = kubernetes_namespace.affine.metadata[0].name
    labels = {
      app  = "affine"
      tier = local.tiers.aux
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
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.affine.metadata[0].name
  name            = "affine"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "500m"
}
