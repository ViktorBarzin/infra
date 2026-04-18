variable "image_tag" {
  type        = string
  default     = "latest"
  description = "payslip-ingest image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

locals {
  namespace = "payslip-ingest"
  image     = "registry.viktorbarzin.me/payslip-ingest:${var.image_tag}"
  labels = {
    app = "payslip-ingest"
  }
}

resource "kubernetes_namespace" "payslip_ingest" {
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

# App secrets sourced from multiple Vault KV keys.
# Seed these manually in Vault before applying:
#   secret/paperless-ngx          -> property `api_token`
#   secret/claude-agent-service   -> property `api_bearer_token`
#   secret/payslip-ingest         -> property `webhook_bearer_token`
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "payslip-ingest-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "payslip-ingest-secrets"
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
          secretKey = "PAPERLESS_API_TOKEN"
          remoteRef = {
            key      = "paperless-ngx"
            property = "api_token"
          }
        },
        {
          secretKey = "CLAUDE_AGENT_BEARER_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
        {
          secretKey = "WEBHOOK_BEARER_TOKEN"
          remoteRef = {
            key      = "payslip-ingest"
            property = "webhook_bearer_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.payslip_ingest]
}

# DB credentials from Vault database engine (rotated every 7 days).
# Template builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "payslip-ingest-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "payslip-ingest-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://payslip_ingest:{{ .password }}@${var.postgresql_host}:5432/payslip_ingest"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-payslip-ingest"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.payslip_ingest]
}

resource "kubernetes_deployment" "payslip_ingest" {
  metadata {
    name      = "payslip-ingest"
    namespace = kubernetes_namespace.payslip_ingest.metadata[0].name
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
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        init_container {
          name    = "alembic-migrate"
          image   = local.image
          command = ["python", "-m", "payslip_ingest", "migrate"]

          env_from {
            secret_ref {
              name = "payslip-ingest-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "payslip-ingest-db-creds"
            }
          }

          env {
            name  = "PAPERLESS_URL"
            value = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
          }
          env {
            name  = "CLAUDE_AGENT_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
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
          name  = "payslip-ingest"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "payslip-ingest-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "payslip-ingest-db-creds"
            }
          }

          env {
            name  = "PAPERLESS_URL"
            value = "http://paperless-ngx.paperless-ngx.svc.cluster.local"
          }
          env {
            name  = "CLAUDE_AGENT_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
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
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
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

# ClusterIP-only — webhook is cluster-internal (paperless-ngx -> payslip-ingest).
resource "kubernetes_service" "payslip_ingest" {
  metadata {
    name      = "payslip-ingest"
    namespace = kubernetes_namespace.payslip_ingest.metadata[0].name
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

# Plan-time read of the ESO-created K8s Secret for Grafana datasource password.
# First apply: -target=kubernetes_manifest.db_external_secret first so the Secret exists.
data "kubernetes_secret" "payslip_ingest_db_creds" {
  metadata {
    name      = "payslip-ingest-db-creds"
    namespace = kubernetes_namespace.payslip_ingest.metadata[0].name
  }
  depends_on = [kubernetes_manifest.db_external_secret]
}

# Grafana datasource for payslip_ingest PostgreSQL DB.
# Lives in the monitoring namespace so the grafana sidecar (label grafana_datasource=1) picks it up.
resource "kubernetes_config_map" "grafana_payslips_datasource" {
  metadata {
    name      = "grafana-payslips-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "payslips-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "Payslips"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "payslip_ingest"
        uid    = "payslips-pg"
        # Grafana 11.2+ Postgres plugin reads the DB name from jsonData.database;
        # the top-level `database` field is silently ignored by the frontend and
        # triggers "you do not have default database" on every panel.
        # See github.com/grafana/grafana#112418.
        jsonData = {
          database        = "payslip_ingest"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = data.kubernetes_secret.payslip_ingest_db_creds.data["DB_PASSWORD"]
        }
        editable = true
      }]
    })
  }
}
