variable "image_tag" {
  type        = string
  default     = "latest"
  description = "trip-planner image tag. Use 8-char git SHA in CI."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "trip-planner"
  image     = "forgejo.viktorbarzin.me/viktor/trip-planner:${var.image_tag}"
  labels = {
    app = "trip-planner"
  }
}

resource "kubernetes_namespace" "trip_planner" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
      # Opt into Keel auto-update (inject-keel-annotations ClusterPolicy).
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets — seed these in Vault before applying:
#   secret/trip-planner
#     SLACK_BOT_TOKEN       — Slack bot OAuth token (xoxb-…)
#     SLACK_SIGNING_SECRET  — Slack app signing secret (v0 HMAC) for request verification
#     TREK_API_URL          — TREK instance base URL
#     TREK_API_KEY          — TREK API key
#
# Schema in CNPG: `trip_planner` (alembic creates tables on first migrate).
# DB user: created via Vault database engine — see static-creds/pg-trip-planner.
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "trip-planner-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "trip-planner-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      dataFrom = [{
        extract = {
          key = "trip-planner"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.trip_planner]
}

# DB credentials from Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
# Pre-req in dbaas: CNPG cluster has DB `trip_planner`, role `trip_planner`,
# and Vault role `static-creds/pg-trip-planner`.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "trip-planner-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "trip-planner-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://trip_planner:{{ .password }}@${var.postgresql_host}:5432/trip_planner"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-trip-planner"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.trip_planner]
}

resource "kubernetes_deployment" "trip_planner" {
  metadata {
    name      = "trip-planner"
    namespace = kubernetes_namespace.trip_planner.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    # Single leader: Slack event deduplication and the webhook receiver want
    # one writer. Recreate avoids two pods racing on the same DB session.
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        init_container {
          name    = "migrate"
          image   = local.image
          command = ["python", "-m", "trip_planner", "migrate"]

          env_from {
            secret_ref { name = "trip-planner-secrets" }
          }
          env_from {
            secret_ref { name = "trip-planner-db-creds" }
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        container {
          name  = "trip-planner"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref { name = "trip-planner-secrets" }
          }
          env_from {
            secret_ref { name = "trip-planner-db-creds" }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "256Mi" }
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
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

resource "kubernetes_service" "trip_planner" {
  metadata {
    name      = "trip-planner"
    namespace = kubernetes_namespace.trip_planner.metadata[0].name
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

# Kyverno ClusterPolicy `sync-tls-secret` auto-clones the wildcard TLS
# secret into every namespace, so we don't need a setup_tls_secret module.

# Public ingress for the Slack events webhook. All requests carry a
# Slack v0 HMAC signature (X-Slack-Signature header) that the app verifies
# before processing — Authentik forward-auth would intercept the POST and
# break Slack's delivery retries.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": Slack webhook receiver — gated by Slack v0 signature verification in-app, not Authentik
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.trip_planner.metadata[0].name
  name             = "trip-planner"
  port             = 8080
  tls_secret_name  = var.tls_secret_name
}
