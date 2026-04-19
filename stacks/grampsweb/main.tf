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
      name      = "grampsweb-secrets"
      namespace = "grampsweb"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grampsweb-secrets"
      }
      dataFrom = [{
        extract = {
          key = "grampsweb"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.grampsweb]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "grampsweb-secrets"
    namespace = kubernetes_namespace.grampsweb.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  mailserver_accounts = jsondecode(data.kubernetes_secret.eso_secrets.data["mailserver_accounts"])
}
variable "redis_host" { type = string }
variable "mail_host" { type = string }


resource "kubernetes_namespace" "grampsweb" {
  metadata {
    name = "grampsweb"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.grampsweb.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "grampsweb-data-encrypted"
    namespace = kubernetes_namespace.grampsweb.metadata[0].name
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

resource "random_password" "secret_key" {
  length  = 64
  special = false
}

locals {
  common_env = [
    {
      name  = "GRAMPSWEB_TREE"
      value = "Gramps Web"
    },
    {
      name  = "GRAMPSWEB_SECRET_KEY"
      value = random_password.secret_key.result
    },
    {
      name  = "GRAMPSWEB_CELERY_CONFIG__broker_url"
      value = "redis://${var.redis_host}:6379/2"
    },
    {
      name  = "GRAMPSWEB_CELERY_CONFIG__result_backend"
      value = "redis://${var.redis_host}:6379/2"
    },
    {
      name  = "GRAMPSWEB_RATELIMIT_STORAGE_URI"
      value = "redis://${var.redis_host}:6379/3"
    },
    {
      name  = "GRAMPSWEB_BASE_URL"
      value = "https://family.viktorbarzin.me"
    },
    {
      name  = "GRAMPSWEB_REGISTRATION_DISABLED"
      value = "True"
    },
    {
      name  = "GRAMPSWEB_EMAIL_HOST"
      value = var.mail_host
    },
    {
      name  = "GRAMPSWEB_EMAIL_PORT"
      value = "587"
    },
    {
      name  = "GRAMPSWEB_EMAIL_HOST_USER"
      value = "info@viktorbarzin.me"
    },
    {
      name  = "GRAMPSWEB_EMAIL_HOST_PASSWORD"
      value = local.mailserver_accounts["info@viktorbarzin.me"]
    },
    {
      name  = "GRAMPSWEB_EMAIL_USE_SSL"
      value = "False"
    },
    {
      name  = "GRAMPSWEB_EMAIL_USE_STARTTLS"
      value = "True"
    },
    {
      name  = "GRAMPSWEB_DEFAULT_FROM_EMAIL"
      value = "info@viktorbarzin.me"
    },
  ]
}

resource "kubernetes_deployment" "grampsweb" {
  metadata {
    name      = "grampsweb"
    namespace = kubernetes_namespace.grampsweb.metadata[0].name
    labels = {
      app  = "grampsweb"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: grampsweb uses ~1.8GB actual memory with 3GB limit per replica.
    # Not actively used — disabled to reduce cluster memory pressure (2026-03-14 node2 OOM incident).
    replicas = 0
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "grampsweb"
      }
    }
    template {
      metadata {
        labels = {
          app = "grampsweb"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "redis-master.redis:6379"
        }
      }
      spec {
        container {
          name  = "grampsweb"
          image = "ghcr.io/gramps-project/grampsweb:latest"

          port {
            container_port = 5000
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
            mount_path = "/app/users"
            sub_path   = "users"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/indexdir"
            sub_path   = "indexdir"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/thumbnail_cache"
            sub_path   = "thumbnail_cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/cache"
            sub_path   = "cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/secret"
            sub_path   = "secret"
          }
          volume_mount {
            name       = "data"
            mount_path = "/root/.gramps/grampsdb"
            sub_path   = "grampsdb"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/media"
            sub_path   = "media"
          }
          volume_mount {
            name       = "data"
            mount_path = "/tmp"
            sub_path   = "tmp"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        container {
          name    = "grampsweb-celery"
          image   = "ghcr.io/gramps-project/grampsweb:latest"
          command = ["celery", "-A", "gramps_webapi.celery", "worker", "--loglevel=INFO", "--concurrency=2"]

          dynamic "env" {
            for_each = local.common_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/users"
            sub_path   = "users"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/indexdir"
            sub_path   = "indexdir"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/thumbnail_cache"
            sub_path   = "thumbnail_cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/cache"
            sub_path   = "cache"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/secret"
            sub_path   = "secret"
          }
          volume_mount {
            name       = "data"
            mount_path = "/root/.gramps/grampsdb"
            sub_path   = "grampsdb"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/media"
            sub_path   = "media"
          }
          volume_mount {
            name       = "data"
            mount_path = "/tmp"
            sub_path   = "tmp"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "grampsweb" {
  metadata {
    name      = "grampsweb"
    namespace = kubernetes_namespace.grampsweb.metadata[0].name
    labels = {
      app = "grampsweb"
    }
  }

  spec {
    selector = {
      app = "grampsweb"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.grampsweb.metadata[0].name
  name            = "family"
  service_name    = "grampsweb"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "500m"
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "GrampsWeb"
    "gethomepage.dev/description"  = "Family tree"
    "gethomepage.dev/icon"         = "gramps-web.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
