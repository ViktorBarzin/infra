# Contents for cloudflare tunnel

variable "tls_secret_name" {}
variable "cloudflare_tunnel_token" {}
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
    replicas = 3
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
          # image = "wisdomsky/cloudflared-web:latest"
          image   = "cloudflare/cloudflared"
          name    = "cloudflared"
          command = ["cloudflared", "tunnel", "run"]
          env {
            name  = "TUNNEL_TOKEN"
            value = var.cloudflare_tunnel_token
          }

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

