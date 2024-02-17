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
  namespace       = "echo"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "echo" {
  metadata {
    name      = "echo"
    namespace = "echo"
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
    namespace = "echo"
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

resource "kubernetes_ingress_v1" "echo" {
  metadata {
    name      = "echo"
    namespace = "echo"

    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["echo.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "echo.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "echo"
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
