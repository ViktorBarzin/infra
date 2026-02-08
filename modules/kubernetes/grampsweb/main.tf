variable "tls_secret_name" {}
variable "tier" { type = string }
variable "smtp_password" { type = string }

resource "kubernetes_namespace" "grampsweb" {
  metadata {
    name = "grampsweb"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.grampsweb.metadata[0].name
  tls_secret_name = var.tls_secret_name
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
      value = "redis://redis.redis.svc.cluster.local:6379/2"
    },
    {
      name  = "GRAMPSWEB_CELERY_CONFIG__result_backend"
      value = "redis://redis.redis.svc.cluster.local:6379/2"
    },
    {
      name  = "GRAMPSWEB_RATELIMIT_STORAGE_URI"
      value = "redis://redis.redis.svc.cluster.local:6379/3"
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
      value = "mail.viktorbarzin.me"
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
      value = var.smtp_password
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
    {
      name  = "GRAMPSWEB_LLM_BASE_URL"
      value = "http://ollama.ollama.svc.cluster.local:11434/v1"
    },
    {
      name  = "GRAMPSWEB_LLM_MODEL"
      value = "llama3.1"
    },
  ]
}

resource "kubernetes_deployment" "grampsweb" {
  metadata {
    name      = "grampsweb"
    namespace = kubernetes_namespace.grampsweb.metadata[0].name
    labels = {
      app  = "grampsweb"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
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
        }

        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/grampsweb"
          }
        }
      }
    }
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.grampsweb.metadata[0].name
  name            = "family"
  service_name    = "grampsweb"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "500m"
}
