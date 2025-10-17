variable "tls_secret_name" {}

resource "kubernetes_namespace" "networking-toolbox" {
  metadata {
    name = "networking-toolbox"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "networking-toolbox"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = "networking-toolbox"
    labels = {
      app = "networking-toolbox"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "networking-toolbox"
      }
    }
    template {
      metadata {
        labels = {
          app = "networking-toolbox"
        }
      }
      spec {
        container {
          image = "lissy93/networking-toolbox"
          name  = "networking-toolbox"
          port {
            container_port = 3000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = "networking-toolbox"
    labels = {
      "app" = "networking-toolbox"
    }
  }

  spec {
    selector = {
      app = "networking-toolbox"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "3000"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "networking-toolbox"
  name            = "networking-toolbox"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
