variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "affine-secrets"
      namespace = "affine"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "affine-secrets"
      }
      dataFrom = [{
        extract = {
          key = "affine"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.affine]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "affine-secrets"
    namespace = kubernetes_namespace.affine.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

# DB credentials from Vault database engine (rotated automatically)
# Provides DATABASE_URL that auto-updates when password rotates
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "affine-db-creds"
      namespace = "affine"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "affine-db-creds"
        template = {
          data = {
            DATABASE_URL = "postgresql://affine:{{ .password }}@${var.postgresql_host}:5432/affine"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-affine"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.affine]
}

locals {
  mailserver_accounts = jsondecode(data.kubernetes_secret.eso_secrets.data["mailserver_accounts"])
}
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
      value = local.mailserver_accounts["info@viktorbarzin.me"]
    },
    {
      name  = "MAILER_SENDER"
      value = "AFFiNE <info@viktorbarzin.me>"
    },
  ]
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "affine-data-encrypted"
    namespace = kubernetes_namespace.affine.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "affine" {
  metadata {
    name      = "affine"
    namespace = kubernetes_namespace.affine.metadata[0].name
    labels = {
      app  = "affine"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432,redis.redis:6379"
        }
      }
      spec {
        # Init container to run database migrations
        init_container {
          name    = "migration"
          image   = "ghcr.io/toeverything/affine:0.26.6"
          command = ["sh", "-c", "npx prisma migrate deploy && SERVER_FLAVOR=script node ./dist/main.js run"]

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "affine-db-creds"
                key  = "DATABASE_URL"
              }
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
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "affine"
          image = "ghcr.io/toeverything/affine:0.26.6"

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
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "affine-db-creds"
                key  = "DATABASE_URL"
              }
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
              memory = "128Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
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
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
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
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.affine.metadata[0].name
  name            = "affine"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "500m"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Affine"
    "gethomepage.dev/description"  = "Knowledge base"
    "gethomepage.dev/icon"         = "affine.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
