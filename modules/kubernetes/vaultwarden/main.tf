variable "tls_secret_name" {}

resource "kubernetes_namespace" "vaultwarden" {
  metadata {
    name = "vaultwarden"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "vaultwarden"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = "vaultwarden"
    labels = {
      app = "vaultwarden"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "vaultwarden"
      }
    }
    template {
      metadata {
        labels = {
          app = "vaultwarden"
        }
      }
      spec {
        container {
          image = "vaultwarden/server:latest"
          name  = "vaultwarden"
          env {
            name  = "DOMAIN"
            value = "https://vaultwarden.viktorbarzin.me"
          }

          port {
            container_port = 80
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/vaultwarden"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = "vaultwarden"
    labels = {
      "app" = "vaultwarden"
    }
  }

  spec {
    selector = {
      app = "vaultwarden"
    }
    port {
      name     = "http"
      port     = "80"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = "vaultwarden"
    annotations = {
      "kubernetes.io/ingress.class"          = "nginx"
      "nginx.ingress.kubernetes.io/affinity" = "cookie"
      # "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      # "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
      #   "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      #   "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["vaultwarden.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "vaultwarden.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "vaultwarden"
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