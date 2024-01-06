variable "tls_secret_name" {}
resource "kubernetes_namespace" "cloudflared" {
  metadata {
    name = "cloudflared"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "cloudflared"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = "cloudflared"
    labels = {
      app = "cloudflared"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "cloudflared"
      }
    }
    template {
      metadata {
        labels = {
          app = "cloudflared"
        }
      }
      spec {
        container {
          image = "wisdomsky/cloudflared-web:latest"
          name  = "cloudflared"

          port {
            container_port = 14333
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = "cloudflared"
    labels = {
      "app" = "cloudflared"
    }
  }

  spec {
    selector = {
      app = "cloudflared"
    }
    port {
      name        = "http"
      target_port = 14333
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = "cloudflared"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["cloudflared.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "cloudflared.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "cloudflared"
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

