variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "jsoncrack" {
  metadata {
    name = "jsoncrack"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}
module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.jsoncrack.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "jsoncrack" {
  metadata {
    name      = "jsoncrack"
    namespace = kubernetes_namespace.jsoncrack.metadata[0].name
    labels = {
      app  = "jsoncrack"
      tier = var.tier
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
    namespace = kubernetes_namespace.jsoncrack.metadata[0].name
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
  namespace       = kubernetes_namespace.jsoncrack.metadata[0].name
  name            = "json"
  tls_secret_name = var.tls_secret_name
}
