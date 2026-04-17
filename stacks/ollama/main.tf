variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "ollama_host" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ollama-secrets"
      namespace = "ollama"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "ollama-secrets"
      }
      dataFrom = [{
        extract = {
          key = "ollama"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ollama]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "ollama-secrets"
    namespace = kubernetes_namespace.ollama.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  api_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["api_credentials"])
}


resource "kubernetes_namespace" "ollama" {
  metadata {
    name = "ollama"
    labels = {
      tier = local.tiers.gpu
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_ollama_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ollama-data-host"
  namespace  = kubernetes_namespace.ollama.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs-ssd/ollama"
}

resource "kubernetes_persistent_volume_claim" "ollama_ui_data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "ollama-ui-data-proxmox"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
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
      tier = local.tiers.gpu
    }
  }
  spec {
    replicas = 0 # Scaled down — low usage, saves resources + clears ExternalAccessDivergence alert
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        node_selector = {
          "gpu" = "true"
        }
        toleration {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NoSchedule"
        }
        container {
          image = "ollama/ollama:0.6.8"
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
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory           = "256Mi"
              "nvidia.com/gpu" = "1"
            }
          }
        }
        volume {
          name = "ollama-data"
          persistent_volume_claim {
            claim_name = module.nfs_ollama_data_host.claim_name
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
  source                  = "../../modules/kubernetes/ingress_factory"
  namespace               = kubernetes_namespace.ollama.metadata[0].name
  name                    = "ollama-server"
  service_name            = "ollama"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 11434
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# Ollama API ingress for external access (basicAuth protected)
locals {
  ollama_api_htpasswd = join("\n", [for name, pass in local.api_credentials : "${name}:${bcrypt(pass, 10)}"])
}

resource "kubernetes_secret" "ollama_api_basic_auth" {
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
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ollama-api-basic-auth"
      namespace = kubernetes_namespace.ollama.metadata[0].name
    }
    spec = {
      basicAuth = {
        secret = kubernetes_secret.ollama_api_basic_auth.metadata[0].name
      }
    }
  }
}

module "ollama-api-ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  name            = "ollama-api"
  service_name    = "ollama"
  root_domain     = "viktorbarzin.me"
  tls_secret_name = var.tls_secret_name
  ssl_redirect    = true
  port            = 11434
  extra_annotations = {
    "traefik.ingress.kubernetes.io/router.middlewares" = "ollama-ollama-api-basic-auth@kubernetescrd,traefik-rate-limit@kubernetescrd,traefik-crowdsec@kubernetescrd"
    "gethomepage.dev/enabled"                          = "false"
  }
}

# Web UI
resource "kubernetes_deployment" "ollama-ui" {
  metadata {
    name      = "ollama-ui"
    namespace = kubernetes_namespace.ollama.metadata[0].name
    labels = {
      app  = "ollama-ui"
      tier = local.tiers.gpu
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "dependency.kyverno.io/wait-for" = "ollama.ollama:11434"
        }
      }
      spec {
        container {
          # image = "ghcr.io/open-webui/open-webui:main"
          image = "ghcr.io/open-webui/open-webui:v0.8.12"
          name  = "ollama-ui"
          env {
            name  = "OLLAMA_BASE_URL"
            value = "http://${var.ollama_host}:11434"
          }

          port {
            container_port = 8080
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/backend/data"
          }
          resources {
            requests = {
              cpu    = "25m"
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
            claim_name = kubernetes_persistent_volume_claim.ollama_ui_data_proxmox.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ollama.metadata[0].name
  name            = "ollama"
  service_name    = "ollama-ui"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Ollama"
    "gethomepage.dev/description"  = "Local LLM inference"
    "gethomepage.dev/icon"         = "ollama.png"
    "gethomepage.dev/group"        = "AI & Data"
    "gethomepage.dev/pod-selector" = ""
  }
}
