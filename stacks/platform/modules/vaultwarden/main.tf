variable "tls_secret_name" {}
variable "tier" { type = string }
variable "smtp_password" {}
variable "nfs_server" { type = string }
variable "mail_host" { type = string }

resource "kubernetes_namespace" "vaultwarden" {
  metadata {
    name = "vaultwarden"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "vaultwarden-data"
  namespace  = kubernetes_namespace.vaultwarden.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/vaultwarden"
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
          image = "vaultwarden/server:1.35.2"
          name  = "vaultwarden"

          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

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
            value = var.mail_host
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
          liveness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/alive"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
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
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.vaultwarden.metadata[0].name
  name            = "vaultwarden"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "b8fc85e18683"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Vaultwarden"
    "gethomepage.dev/description"  = "Password manager"
    "gethomepage.dev/icon"         = "vaultwarden.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
