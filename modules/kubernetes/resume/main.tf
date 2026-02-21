variable "tls_secret_name" {}
variable "tier" { type = string }
variable "database_url" { type = string }
variable "auth_secret" { type = string }
variable "smtp_password" { type = string }

locals {
  namespace = "resume"
  app_url   = "https://resume.viktorbarzin.me"
}

resource "kubernetes_namespace" "resume" {
  metadata {
    name = local.namespace
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Printer service (browserless chromium for PDF generation)
resource "kubernetes_deployment" "printer" {
  metadata {
    name      = "printer"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      app  = "printer"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "printer"
      }
    }
    template {
      metadata {
        labels = {
          app = "printer"
        }
      }
      spec {
        container {
          name  = "printer"
          image = "ghcr.io/browserless/chromium:latest"

          port {
            container_port = 3000
          }

          env {
            name  = "HEALTH"
            value = "true"
          }
          env {
            name  = "CONCURRENT"
            value = "20"
          }
          env {
            name  = "QUEUED"
            value = "10"
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "2Gi"
              cpu    = "2"
            }
          }

          liveness_probe {
            http_get {
              path = "/pressure"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }
          readiness_probe {
            http_get {
              path = "/pressure"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "printer" {
  metadata {
    name      = "printer"
    namespace = kubernetes_namespace.resume.metadata[0].name
  }
  spec {
    selector = {
      app = "printer"
    }
    port {
      port        = 3000
      target_port = 3000
    }
  }
}

# Reactive Resume app
resource "kubernetes_deployment" "resume" {
  metadata {
    name      = "resume"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      app  = "resume"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "resume"
      }
    }
    template {
      metadata {
        labels = {
          app = "resume"
        }
      }
      spec {
        container {
          name  = "resume"
          image = "amruthpillai/reactive-resume:v5.0.3"

          port {
            container_port = 3000
          }

          # Required env vars
          env {
            name  = "APP_URL"
            value = local.app_url
          }
          env {
            name  = "DATABASE_URL"
            value = var.database_url
          }
          env {
            name  = "PRINTER_ENDPOINT"
            value = "ws://printer.${local.namespace}.svc.cluster.local:3000"
          }
          env {
            name  = "PRINTER_APP_URL"
            value = "http://resume.${local.namespace}.svc.cluster.local"
          }
          env {
            name  = "AUTH_SECRET"
            value = var.auth_secret
          }

          # Server config
          env {
            name  = "TZ"
            value = "Etc/UTC"
          }

          # SMTP config for password reset emails
          env {
            name  = "SMTP_HOST"
            value = "mail.viktorbarzin.me"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_USER"
            value = "info@viktorbarzin.me"
          }
          env {
            name  = "SMTP_PASS"
            value = var.smtp_password
          }
          env {
            name  = "SMTP_FROM"
            value = "Reactive Resume <info@viktorbarzin.me>"
          }
          env {
            name  = "SMTP_SECURE"
            value = "false"
          }

          # Feature flags
          env {
            name  = "FLAG_DISABLE_SIGNUPS"
            value = "false" # toggle me
          }

          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "1Gi"
              cpu    = "1"
            }
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }
          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/resume"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "resume" {
  metadata {
    name      = "resume"
    namespace = kubernetes_namespace.resume.metadata[0].name
  }
  spec {
    selector = {
      app = "resume"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  name            = "resume"
  tls_secret_name = var.tls_secret_name
}
