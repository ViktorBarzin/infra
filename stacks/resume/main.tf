variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "resume_database_url" { type = string }
variable "nfs_server" { type = string }
variable "mail_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "resume"
}

locals {
  namespace           = "resume"
  app_url             = "https://resume.viktorbarzin.me"
  mailserver_accounts = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_accounts"])
}

resource "kubernetes_namespace" "resume" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "resume-secrets"
      namespace = "resume"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "resume-secrets"
      }
      dataFrom = [{
        extract = {
          key = "resume"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.resume]
}

# Printer service (browserless chromium for PDF generation)
resource "kubernetes_deployment" "printer" {
  metadata {
    name      = "printer"
    namespace = kubernetes_namespace.resume.metadata[0].name
    labels = {
      app  = "printer"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 0 # Scaled down — browserless chromium causes node OOM
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
              memory = "128Mi"
              cpu    = "25m"
            }
            limits = {
              memory = "128Mi"
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

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "resume-data-proxmox"
    namespace = kubernetes_namespace.resume.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
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
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 0 # Scaled down with printer — depends on browserless chromium
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "reloader.stakater.com/search" = "true"
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
            value = var.resume_database_url
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
            name = "AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = "resume-secrets"
                key  = "auth_secret"
              }
            }
          }

          # Server config
          env {
            name  = "TZ"
            value = "Etc/UTC"
          }

          # SMTP config for password reset emails
          env {
            name  = "SMTP_HOST"
            value = var.mail_host
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
            value = local.mailserver_accounts["info@viktorbarzin.me"]
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
              memory = "64Mi"
              cpu    = "15m"
            }
            limits = {
              memory = "64Mi"
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
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.resume.metadata[0].name
  name            = "resume"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Resume"
    "gethomepage.dev/description"  = "Online resume"
    "gethomepage.dev/icon"         = "mdi-file-account"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
