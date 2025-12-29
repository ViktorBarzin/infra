variable "tls_secret_name" {}

resource "kubernetes_namespace" "echo" {
  metadata {
    name = "echo"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.echo.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace.echo.metadata[0].name
    labels = {
      app = "echo"
    }
  }
  spec {
    replicas = 5
    selector {
      match_labels = {
        app = "echo"
      }
    }
    template {
      metadata {
        labels = {
          app = "echo"
        }
      }
      spec {
        container {
          image = "mendhak/http-https-echo"
          name  = "echo"
          port {
            container_port = 8080
          }
          port {
            container_port = 8443
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "echo" {
  metadata {
    name      = "echo"
    namespace = kubernetes_namespace.echo.metadata[0].name
    labels = {
      "app" = "echo"
    }
  }

  spec {
    selector = {
      app = "echo"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.echo.metadata[0].name
  name            = "echo"
  tls_secret_name = var.tls_secret_name
}
