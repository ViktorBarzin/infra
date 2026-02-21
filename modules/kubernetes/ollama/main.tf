variable "tls_secret_name" {}
variable "tier" { type = string }
variable "ollama_api_credentials" {
  type    = map(string)
  default = {}
}

resource "kubernetes_namespace" "ollama" {
  metadata {
    name = "ollama"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  tls_secret_name = var.tls_secret_name
}
resource "kubernetes_persistent_volume_claim" "ollama-pvc" {
  metadata {
    name      = "ollama-pvc"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "30Gi"
      }
    }
    volume_name = "ollama-pv"
  }
}

resource "kubernetes_persistent_volume" "ollama-pv" {
  metadata {
    name = "ollama-pv"
  }
  spec {
    capacity = {
      "storage" = "30Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/ollama"
        server = "10.0.10.15"
      }
    }
  }
}

# resource "helm_release" "ollama" {
#  namespace = kubernetes_namespace.ollama.metadata[0].name
#   name      = "ollama"

#   repository = "https://otwld.github.io/ollama-helm/"
#   chart      = "ollama"
#   atomic     = true

#   values  = [templatefile("${path.module}/values.yaml", {})]
#   timeout = 2400
# }


resource "kubernetes_deployment" "ollama" {
  metadata {
    name      = "ollama"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    labels = {
      app  = "ollama"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "ollama"
      }
    }
    template {
      metadata {
        labels = {
          app = "ollama"
        }
      }
      spec {
        container {
          image = "ollama/ollama:latest"
          name  = "ollama"
          env {
            name  = "OLLAMA_HOST"
            value = "0.0.0.0:11434"
          }
          env {
            name  = "PATH"
            value = "/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }
          env {
            name  = "OLLAMA_KEEP_ALIVE"
            value = "1h"
          }

          port {
            container_port = 11434
          }
          volume_mount {
            name       = "ollama-data"
            mount_path = "/root/.ollama"
          }
          resources {
            limits = {
              "nvidia.com/gpu" = "1"
            }
          }
        }
        volume {
          name = "ollama-data"
          nfs {
            # path   = "/mnt/main/ollama"
            path   = "/mnt/ssd/ollama"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ollama" {
  metadata {
    name      = "ollama"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    labels = {
      app = "ollama"
    }
  }

  spec {
    selector = {
      app = "ollama"
    }
    port {
      name = "http"
      port = 11434
    }
  }
}

# Allow ollama to be connected to from external apps (internal LAN only)
module "ollama-ingress" {
  source                  = "../ingress_factory"
  namespace               = kubernetes_namespace.ollama.metadata[0].name
  name                    = "ollama-server"
  service_name            = "ollama"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 11434
}

# Ollama API ingress for external access (basicAuth protected)
locals {
  ollama_api_htpasswd = join("\n", [for name, pass in var.ollama_api_credentials : "${name}:${bcrypt(pass, 10)}"])
}

resource "kubernetes_secret" "ollama_api_basic_auth" {
  count = length(var.ollama_api_credentials) > 0 ? 1 : 0
  metadata {
    name      = "ollama-api-basic-auth-secret"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }

  data = {
    auth = local.ollama_api_htpasswd
  }

  type = "Opaque"
  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_manifest" "ollama_api_basic_auth_middleware" {
  count = length(var.ollama_api_credentials) > 0 ? 1 : 0
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ollama-api-basic-auth"
      namespace = kubernetes_namespace.ollama.metadata[0].name
    }
    spec = {
      basicAuth = {
        secret = kubernetes_secret.ollama_api_basic_auth[0].metadata[0].name
      }
    }
  }
}

module "ollama-api-ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  name            = "ollama-api"
  service_name    = "ollama"
  root_domain     = "viktorbarzin.me"
  tls_secret_name = var.tls_secret_name
  ssl_redirect    = true
  port            = 11434
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.middlewares" = "ollama-ollama-api-basic-auth@kubernetescrd,traefik-rate-limit@kubernetescrd,traefik-crowdsec@kubernetescrd"
  }
}

# Web UI
resource "kubernetes_deployment" "ollama-ui" {
  metadata {
    name      = "ollama-ui"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    labels = {
      app  = "ollama-ui"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "ollama-ui"
      }
    }
    template {
      metadata {
        labels = {
          app = "ollama-ui"
        }
      }
      spec {
        container {
          # image = "ghcr.io/open-webui/open-webui:main"
          image = "ghcr.io/open-webui/open-webui:v0.7.2"
          name  = "ollama-ui"
          env {
            name  = "OLLAMA_BASE_URL"
            value = "http://ollama.ollama.svc.cluster.local:11434"
          }

          port {
            container_port = 8080
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/backend/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/ollama"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ollama-ui" {
  metadata {
    name      = "ollama-ui"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    labels = {
      app = "dashy"
    }
  }

  spec {
    selector = {
      app = "ollama-ui"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  name            = "ollama"
  service_name    = "ollama-ui"
  tls_secret_name = var.tls_secret_name
  port            = 80
  rybbit_site_id  = "e73bebea399f"
}
