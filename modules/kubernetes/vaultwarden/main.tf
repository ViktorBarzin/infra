variable "tls_secret_name" {}
variable "smtp_password" {}

resource "kubernetes_namespace" "vaultwarden" {
  metadata {
    name = "vaultwarden"
    labels = {
      "istio-injection" : "disabled"
    }
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
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          "app" = "vaultwarden"
        }
      }
      spec {
        container {
          image = "vaultwarden/server:1.32.7"
          name  = "vaultwarden"
          env {
            name  = "DOMAIN"
            value = "https://vaultwarden.viktorbarzin.me"
          }
          # env {
          #   name  = "ADMIN_TOKEN"
          #   value = ""
          # }
          env {
            name  = "SMTP_HOST"
            value = "mail.viktorbarzin.me"
          }
          env {
            name  = "SMTP_FROM"
            value = "vaultwarden@viktorbarzin.me"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_SECURITY"
            value = "starttls"
          }
          env {
            name  = "SMTP_USERNAME"
            value = "vaultwarden@viktorbarzin.me"
          }
          env {
            name  = "SMTP_PASSWORD"
            value = var.smtp_password
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

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "vaultwarden"
  name            = "vaultwarden"
  tls_secret_name = var.tls_secret_name
}
