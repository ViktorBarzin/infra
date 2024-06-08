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

resource "helm_release" "ollama" {
  namespace = "ollama"
  name      = "ollama"

  repository = "https://otwld.github.io/ollama-helm/"
  chart      = "ollama"

  values = [templatefile("${path.module}/values.yaml", {})]
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
            value = "http://ollama:11434"
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


resource "kubernetes_ingress_v1" "ollama-ui" {
  metadata {
    name      = "ollama"
    namespace = "ollama"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["ollama.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "ollama.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "ollama-ui"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}
