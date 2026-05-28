variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "resume_database_url" {
  type    = string
  default = ""
}
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
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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

module "nfs_data_host" {
  source       = "../../modules/kubernetes/nfs_volume"
  name         = "resume-data-host"
  namespace    = kubernetes_namespace.resume.metadata[0].name
  nfs_server   = var.nfs_server
  nfs_path     = "/srv/nfs/resume"
  storage      = "1Gi"
  access_modes = ["ReadWriteOnce"]
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
            claim_name = module.nfs_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
  source = "../../modules/kubernetes/ingress_factory"
  # Public-facing resume page for HR/recruiters — they don't have Authentik
  # accounts. `auth = "public"` auto-binds to guest, so the page renders
  # invisibly while still being audited in Authentik's event log.
  auth            = "public"
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
