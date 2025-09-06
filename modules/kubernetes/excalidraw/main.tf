variable "tls_secret_name" {}

resource "kubernetes_namespace" "finance_app" {
  metadata {
    name = "excalidraw"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "excalidraw"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "excalidraw" {
  metadata {
    name      = "excalidraw"
    namespace = "excalidraw"
    labels = {
      app = "excalidraw"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "excalidraw"
      }
    }
    template {
      metadata {
        labels = {
          app = "excalidraw"
        }
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^latest$"
        }
      }
      spec {
        container {
          image = "docker.io/excalidraw/excalidraw:latest"
          name  = "excalidraw"
        }
      }
    }
  }
}

resource "kubernetes_service" "draw" {
  metadata {
    name      = "draw"
    namespace = "excalidraw"
    labels = {
      app = "excalidraw"
    }
  }

  spec {
    selector = {
      app = "excalidraw"
    }
    port {
      name = "http"
      port = "80"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "excalidraw"
  name            = "draw"
  tls_secret_name = var.tls_secret_name
}

