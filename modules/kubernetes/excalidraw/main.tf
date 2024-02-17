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

resource "kubernetes_service" "finance_app" {
  metadata {
    name      = "excalidraw"
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


resource "kubernetes_ingress_v1" "finance_app" {
  metadata {
    name      = "excalidraw"
    namespace = "excalidraw"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["excalidraw.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "excalidraw.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "excalidraw"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    rule {
      host = "draw.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "excalidraw"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
