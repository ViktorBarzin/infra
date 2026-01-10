variable "tls_secret_name" {}
variable "tier" { type = string }
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
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "vaultwarden" {
  metadata {
    name      = "vaultwarden"
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
    labels = {
      app  = "vaultwarden"
      tier = var.tier
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
          image = "vaultwarden/server:1.34.3"
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
    namespace = kubernetes_namespace.vaultwarden.metadata[0].name
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
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  name            = "vaultwarden"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "b8fc85e18683"
}
