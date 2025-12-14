variable "tls_secret_name" {}

resource "kubernetes_namespace" "ollama" {
  metadata {
    name = "ollama"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "ollama"
  tls_secret_name = var.tls_secret_name
}
resource "kubernetes_persistent_volume_claim" "ollama-pvc" {
  metadata {
    name      = "ollama-pvc"
    namespace = "ollama"
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
#   namespace = "ollama"
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
    namespace = "ollama"
    labels = {
      app = "ollama"
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
            path   = "/mnt/main/ollama"
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
    namespace = "ollama"
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

# Allow ollama to be connected to from external apps
module "ollama-ingress" {
  source                  = "../ingress_factory"
  namespace               = "ollama"
  name                    = "ollama-server"
  service_name            = "ollama"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 11434
}

# Web UI
resource "kubernetes_deployment" "ollama-ui" {
  metadata {
    name      = "ollama-ui"
    namespace = "ollama"
    labels = {
      app = "ollama-ui"
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
          image = "ghcr.io/open-webui/open-webui:main"
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
    namespace = "ollama"
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
  namespace       = "ollama"
  name            = "ollama"
  service_name    = "ollama-ui"
  tls_secret_name = var.tls_secret_name
  port            = 80
}
