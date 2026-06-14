variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }

resource "kubernetes_namespace" "health" {
  metadata {
    name = "health"
    labels = {
      tier               = local.tiers.aux
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
  namespace       = kubernetes_namespace.health.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "uploads_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "health-uploads-encrypted"
    namespace = kubernetes_namespace.health.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app  = "health"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "health"
      }
    }
    template {
      metadata {
        labels = {
          app = "health"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          name  = "health"
          image = "viktorbarzin/health:latest"

          port {
            container_port = 3000
          }

          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = "health-db-secrets"
                key  = "DATABASE_URL"
              }
            }
          }
          env {
            name = "SECRET_KEY"
            value_from {
              secret_key_ref {
                name = "health-kv-secrets"
                key  = "secret_key"
              }
            }
          }
          env {
            name  = "UPLOAD_DIR"
            value = "/data/uploads"
          }
          env {
            name  = "WEBAUTHN_RP_ID"
            value = "health.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_ORIGIN"
            value = "https://health.viktorbarzin.me"
          }
          env {
            name  = "COOKIE_SECURE"
            value = "true"
          }
          env {
            # ADR-0008 (health repo): identity for the internal LAN test host.
            # Only reached when no X-authentik-email header is present — i.e. via
            # the auth="none" test ingress below. The public host's forward-auth
            # fails closed, so requests arriving there always carry the real
            # header and never fall back to this value.
            name  = "DEV_AUTH_EMAIL"
            value = "vbarzin@gmail.com"
          }

          volume_mount {
            name       = "uploads"
            mount_path = "/data/uploads"
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "15m"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads_encrypted.metadata[0].name
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

resource "kubernetes_service" "health" {
  metadata {
    name      = "health"
    namespace = kubernetes_namespace.health.metadata[0].name
    labels = {
      app = "health"
    }
  }

  spec {
    selector = {
      app = "health"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.health.metadata[0].name
  name            = "health"
  tls_secret_name = var.tls_secret_name
  max_body_size   = "100m"
  # The redesigned SPA bursts well past the default 10/50 limiter on each page
  # load (shell + fonts + a 5-8 call API burst). Swap the shared limiter for a
  # health-specific one (100/1000), mirroring tripit/immich/actualbudget.
  skip_default_rate_limit = true
  extra_middlewares       = ["health-rate-limit@kubernetescrd"]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Health"
    "gethomepage.dev/description"  = "Health dashboard"
    "gethomepage.dev/icon"         = "healthchecks.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://health-test.viktorbarzin.lan — internal LAN-only test host for
# automated/E2E testing + manual screenshots without the Authentik SSO dance
# (ADR-0008). Same `health` deployment; acts as DEV_AUTH_EMAIL=vbarzin@gmail.com.
module "ingress_test" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": LAN-only (allow_local_access_only) test host — no public
  # exposure; the public health.viktorbarzin.me ingress above stays
  # auth="required". No user data gate here by design — it serves the real app
  # as DEV_AUTH_EMAIL since no X-authentik-email is injected (ADR-0008).
  auth                    = "none"
  namespace               = kubernetes_namespace.health.metadata[0].name
  name                    = "health-test"
  root_domain             = "viktorbarzin.lan"
  service_name            = kubernetes_service.health.metadata[0].name
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  max_body_size           = "100m"
  anti_ai_scraping        = false
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

resource "kubernetes_manifest" "external_secret_db" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "health-db-secrets"
      namespace = "health"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "health-db-secrets"
        template = {
          data = {
            DATABASE_URL = "postgresql+asyncpg://health:{{ .db_password }}@postgresql.dbaas.svc.cluster.local:5432/health"
          }
        }
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/pg-health"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.health]
}

resource "kubernetes_manifest" "external_secret_kv" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "health-kv-secrets"
      namespace = "health"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "health-kv-secrets"
      }
      data = [{
        secretKey = "secret_key"
        remoteRef = {
          key      = "health"
          property = "secret_key"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.health]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
