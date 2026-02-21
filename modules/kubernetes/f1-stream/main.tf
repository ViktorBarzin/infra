variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "f1-stream" {
  metadata {
    name = "f1-stream"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "kubernetes_deployment" "f1-stream" {
  metadata {
    name      = "f1-stream"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream"
      tier = var.tier
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "f1-stream"
      }
    }
    template {
      metadata {
        labels = {
          app = "f1-stream"
        }
      }
      spec {
        container {
          image = "viktorbarzin/f1-stream:latest"
          name  = "f1-stream"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "512Mi"
            }
          }
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port        = "80"
      target_port = "8080"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.f1-stream.metadata[0].name
  name            = "f1"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "7e69786f66d5"
}
