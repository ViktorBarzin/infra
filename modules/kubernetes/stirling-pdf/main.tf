variable "tls_secret_name" {}

resource "kubernetes_namespace" "stirling-pdf" {
  metadata {
    name = "stirling-pdf"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "stirling-pdf"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = "stirling-pdf"
    labels = {
      app = "stirling-pdf"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "stirling-pdf"
      }
    }
    template {
      metadata {
        labels = {
          app = "stirling-pdf"
        }
      }
      spec {
        container {
          image = "stirlingtools/stirling-pdf:latest"
          name  = "stirling-pdf"
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "configs"
            mount_path = "/configs"
          }
        }
        volume {
          name = "configs"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/stirling-pdf"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = "stirling-pdf"
    labels = {
      "app" = "stirling-pdf"
    }
  }

  spec {
    selector = {
      app = "stirling-pdf"
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
  namespace       = "stirling-pdf"
  name            = "stirling-pdf"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "a55ac54ec749"
}
