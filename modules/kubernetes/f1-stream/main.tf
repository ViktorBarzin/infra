variable "tls_secret_name" {}

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
    namespace = "f1-stream"
    labels = {
      app = "f1-stream"
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
            container_port = 80
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "f1-stream" {
  metadata {
    name      = "f1"
    namespace = "f1-stream"
    labels = {
      "app" = "f1-stream"
    }
  }

  spec {
    selector = {
      app = "f1-stream"
    }
    port {
      port = "80"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "f1-stream"
  tls_secret_name = var.tls_secret_name
}


module "ingress" {
  source          = "../ingress_factory"
  namespace       = "f1-stream"
  name            = "f1"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/force-ssl-redirect" : "false"
    "nginx.ingress.kubernetes.io/ssl-redirect" : "false"
  }
  rybbit_site_id = "7e69786f66d5"
}
