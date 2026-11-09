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
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: the goldilocks-vpa ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Database credentials from the Vault static role pg-learning
# (stacks/vault app_db_roles.tf), rotated weekly in its Tuesday slot. The
# db-rotation-watcher force-syncs this ExternalSecret and Reloader restarts
# the pod.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "learning-db-creds"
      namespace = kubernetes_namespace.learning.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "learning-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://learning:{{ .password }}@${var.postgresql_host}:5432/learning"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-learning"
          property = "password"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "learning" {
  metadata {
    name      = "learning"
    namespace = kubernetes_namespace.learning.metadata[0].name
    labels    = merge(local.labels, { tier = local.tiers.aux })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # one writer; data in the shared Postgres since 2026-11-09
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # root: the image has no USER. Explicit so a future USER line is a
        # visible change.
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
            name = "DB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "learning-db-creds"
                key  = "DB_CONNECTION_STRING"
              }
            }
          }
          # Authentik email -> content directory, learning repo ADR-0004.
          # Content lives in content/<user>/<topic>/ and each person reads their
          # own directory and nobody else's, admins included. An identity absent
          # from this map owns nothing and gets an empty catalog, which is the
          # right answer for someone with no workspace rather than an error.
          #
          # This has to be applied BEFORE the image carrying ADR-0004 rolls out.
          # On the older image the variable is ignored (pydantic extra="ignore");
          # on the newer image an empty map means the owner sees no topics.
          #
          # Adding a person is a directory in the learning repo plus a line here.
          # Giving two identities the same directory is how a workspace would be
          # shared, deliberately and visibly, and nothing else grants access.
          env {
            name  = "USER_DIRS"
            value = jsonencode({ "vbarzin@gmail.com" = "wizard" })
          }
          # Product events and errors (telemetry.tf, infra ADR-0041). Without
          # TELEMETRY_WRITE_KEY the app sends nothing; optional so the pod
          # starts before the Secret exists.
          env {
            name  = "TELEMETRY_HOST"
            value = "http://event-pipeline.rybbit.svc.cluster.local"
          }
          env {
            name  = "TELEMETRY_ENVIRONMENT"
            value = "production"
          }
          env {
            name = "TELEMETRY_WRITE_KEY"
            value_from {
              secret_key_ref {
                name     = kubernetes_secret.telemetry.metadata[0].name
                key      = "write_key"
                optional = true
              }
            }
          }
          env {
            name = "SENTRY_DSN"
            value_from {
              secret_key_ref {
                name     = kubernetes_secret.telemetry.metadata[0].name
                key      = "sentry_dsn"
                optional = true
              }
            }
          }
          # CONTENT_DIR + SERVE_FRONTEND_DIR are baked into the image.
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

      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,         # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image, # CI_SETS_IMAGE: first-party image, deployed by its own CI
      metadata[0].annotations["deployment.kubernetes.io/revision"],
    ]
  }
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
