variable "tls_secret_name" {}

resource "kubernetes_namespace" "jsoncrack" {
  metadata {
    name = "jsoncrack"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}
module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "jsoncrack"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "jsoncrack" {
  metadata {
    name      = "jsoncrack"
    namespace = "jsoncrack"
    labels = {
      app = "jsoncrack"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "jsoncrack"
      }
    }
    template {
      metadata {
        labels = {
          app = "jsoncrack"
        }
      }
      spec {
        container {
          image = "viktorbarzin/jsoncrack:latest"
          name  = "jsoncrack"
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "jsoncrack" {
  metadata {
    name      = "json"
    namespace = "jsoncrack"
    labels = {
      "app" = "jsoncrack"
    }
  }

  spec {
    selector = {
      app = "jsoncrack"
    }
    port {
      name        = "http"
      target_port = 8080
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "jsoncrack"
  name            = "json"
  tls_secret_name = var.tls_secret_name
}
