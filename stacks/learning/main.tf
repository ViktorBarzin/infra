variable "image_tag" {
  type    = string
  default = "latest"
}
# Injected into every stack by the root config; unused here (SQLite in v1).
variable "postgresql_host" { type = string }
variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "learning"
  image     = "ghcr.io/viktorbarzin/learning:${var.image_tag}"
  labels    = { app = "learning" }
}

resource "kubernetes_namespace" "learning" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.aux
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: the goldilocks-vpa ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Progress DB: SQLite on a persistent volume. This is a single-user, single-
# writer app (1 replica, Recreate), so SQLite is sufficient for v1. The shared
# CNPG cluster (ADR-0003) is the v2 upgrade — swap DB_CONNECTION_STRING and wire
# the dbaas/vault static-role recipe; nothing else changes.
resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "learning-data"
    namespace = kubernetes_namespace.learning.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "1Gi" }
    }
  }
}

resource "kubernetes_deployment" "learning" {
  metadata {
    name      = "learning"
    namespace = kubernetes_namespace.learning.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # single SQLite writer on an RWO volume
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # root: the image has no USER; SQLite writes to the root-owned
        # PVC. Explicit so a future USER line can not silently CrashLoop.
        security_context {
          run_as_user = 0
        }
        image_pull_secrets {
          name = "registry-credentials"
        }
        # ghcr-credentials is synced into this namespace by the kyverno
        # sync-ghcr-credentials allowlist policy ("learning" added).
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        container {
          name  = "learning"
          image = local.image
          port {
            container_port = 8080
          }
          env {
            name  = "AUTH_MODE"
            value = "prod"
          }
          env {
            name  = "DB_CONNECTION_STRING"
            value = "sqlite+aiosqlite:////data/learn.db"
          }
          # CONTENT_DIR + SERVE_FRONTEND_DIR are baked into the image.
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          readiness_probe {
            http_get {
              path = "/api/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/api/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,    # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"], # KEEL_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — CI set-image wins
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
  depends_on = [kubernetes_persistent_volume_claim.data]
}

resource "kubernetes_service" "learning" {
  metadata {
    name      = "learning"
    namespace = kubernetes_namespace.learning.metadata[0].name
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.labels
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Takes over learn.viktorbarzin.me from the old static Viewer pod (stacks/learn —
# its "learn" ingress + @learn_owner Caddyfile handler were removed in the same
# push; pages.* / plans.* stay on that pod). Authentik forward-auth gates the
# host; the app trusts X-Authentik-Email for owner-only access.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.learning.metadata[0].name
  name            = "learn"
  service_name    = "learning"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Learn"
    "gethomepage.dev/description" = "Self-paced learning PWA — lessons, challenges, progress"
    "gethomepage.dev/icon"        = "mdi-school"
    "gethomepage.dev/group"       = "Productivity"
  }
}
