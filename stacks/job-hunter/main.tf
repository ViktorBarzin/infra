variable "image_tag" {
  type        = string
  default     = "latest"
  description = "job-hunter image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

locals {
  namespace = "job-hunter"
  image     = "registry.viktorbarzin.me/job-hunter:${var.image_tag}"
  labels = {
    app = "job-hunter"
  }
}

resource "kubernetes_namespace" "job_hunter" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets — seed these in Vault before applying:
#   secret/job-hunter
#     webhook_bearer_token  — bearer for /webhook/cdio, /digest/generate, /refresh
#     cdio_api_key          — changedetection.io x-api-key (copy from
#                             `jsondecode(secret/changedetection.homepage_credentials).changedetection.api_key`)
#     smtp_username         — SMTP sender account (mailserver)
#     smtp_password         — SMTP password (mailserver)
#     digest_to_address     — where the weekly digest goes
#     digest_from_address   — From: header for the digest
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "job-hunter-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "job-hunter-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        {
          secretKey = "WEBHOOK_BEARER_TOKEN"
          remoteRef = { key = "job-hunter", property = "webhook_bearer_token" }
        },
        {
          secretKey = "CDIO_API_KEY"
          remoteRef = { key = "job-hunter", property = "cdio_api_key" }
        },
        {
          secretKey = "SMTP_USERNAME"
          remoteRef = { key = "job-hunter", property = "smtp_username" }
        },
        {
          secretKey = "SMTP_PASSWORD"
          remoteRef = { key = "job-hunter", property = "smtp_password" }
        },
        {
          secretKey = "DIGEST_TO_ADDRESS"
          remoteRef = { key = "job-hunter", property = "digest_to_address" }
        },
        {
          secretKey = "DIGEST_FROM_ADDRESS"
          remoteRef = { key = "job-hunter", property = "digest_from_address" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.job_hunter]
}

# DB credentials from Vault database engine (7-day rotation).
# Template builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "job-hunter-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "job-hunter-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://job_hunter:{{ .password }}@${var.postgresql_host}:5432/job_hunter"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-job-hunter"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.job_hunter]
}

resource "kubernetes_deployment" "job_hunter" {
  metadata {
    name      = "job-hunter"
    namespace = kubernetes_namespace.job_hunter.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
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
          name    = "alembic-migrate"
          image   = local.image
          command = ["python", "-m", "job_hunter", "migrate"]

          env_from {
            secret_ref {
              name = "job-hunter-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "job-hunter-db-creds"
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "job-hunter"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "job-hunter-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "job-hunter-db-creds"
            }
          }

          env {
            name  = "CDIO_BASE_URL"
            value = "http://changedetection.changedetection.svc.cluster.local"
          }
          env {
            name  = "SMTP_HOST"
            value = "mailserver.mailserver.svc.cluster.local"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "JOB_HUNTER_WEBHOOK_URL"
            value = "http://job-hunter.job-hunter.svc.cluster.local:8080/webhook/cdio"
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
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            # Chromium baseline ~1Gi — matches broker-sync precedent.
            limits = {
              memory = "1280Mi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

# ClusterIP-only — job-hunter has no public UI. Webhook, digest, and refresh
# endpoints are cluster-internal (n8n / CDIO / CronJob triggers).
resource "kubernetes_service" "job_hunter" {
  metadata {
    name      = "job-hunter"
    namespace = kubernetes_namespace.job_hunter.metadata[0].name
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

# Plan-time read of the ESO-created DB creds Secret for Grafana datasource.
# First apply: -target=kubernetes_manifest.db_external_secret first so the Secret exists.
data "kubernetes_secret" "job_hunter_db_creds" {
  metadata {
    name      = "job-hunter-db-creds"
    namespace = kubernetes_namespace.job_hunter.metadata[0].name
  }
  depends_on = [kubernetes_manifest.db_external_secret]
}

# Grafana datasource for the job_hunter Postgres DB. Lives in the monitoring
# namespace so the grafana sidecar (label grafana_datasource=1) picks it up.
resource "kubernetes_config_map" "grafana_job_hunter_datasource" {
  metadata {
    name      = "grafana-job-hunter-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "job-hunter-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "Job Hunter"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "job_hunter"
        uid    = "job-hunter-pg"
        # Grafana 11.2+ Postgres plugin reads the DB name from jsonData.database;
        # the top-level `database` field is silently ignored by the frontend.
        jsonData = {
          database        = "job_hunter"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = data.kubernetes_secret.job_hunter_db_creds.data["DB_PASSWORD"]
        }
        editable = true
      }]
    })
  }
}
