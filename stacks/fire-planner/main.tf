variable "image_tag" {
  type        = string
  default     = "latest"
  description = "fire-planner image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

locals {
  namespace = "fire-planner"
  image     = "registry.viktorbarzin.me/fire-planner:${var.image_tag}"
  labels = {
    app = "fire-planner"
  }
}

resource "kubernetes_namespace" "fire_planner" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps
    # this label on every namespace.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets — the recompute-API bearer token (manual seed in Vault).
# Seed before applying:
#   secret/fire-planner -> property `recompute_bearer_token`
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "fire-planner-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "fire-planner-secrets"
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
          secretKey = "RECOMPUTE_BEARER_TOKEN"
          remoteRef = {
            key      = "fire-planner"
            property = "recompute_bearer_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.fire_planner]
}

# DB credentials from Vault database engine (rotated every 7 days).
# Template builds the asyncpg DSN consumed by the FastAPI app + CronJob
# as DB_CONNECTION_STRING.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "fire-planner-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "fire-planner-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://fire_planner:{{ .password }}@${var.postgresql_host}:5432/fire_planner"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-fire-planner"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.fire_planner]
}

resource "kubernetes_deployment" "fire_planner" {
  metadata {
    name      = "fire-planner"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
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
          command = ["python", "-m", "fire_planner", "migrate"]

          env_from {
            secret_ref {
              name = "fire-planner-db-creds"
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
          name  = "fire-planner"
          image = local.image

          command = ["python", "-m", "fire_planner", "serve"]

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "fire-planner-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "fire-planner-db-creds"
            }
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
            limits = {
              memory = "1024Mi"
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

# ClusterIP-only — /recompute is cluster-internal (operator triggers
# via kubectl port-forward or ad-hoc CronJob).
resource "kubernetes_service" "fire_planner" {
  metadata {
    name      = "fire-planner"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
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

# Monthly recompute on the 2nd at 09:00 UTC. Wealthfolio-sync runs on
# the 1st at 08:00, so account_snapshot is fresh by the time the
# planner picks up.
resource "kubernetes_cron_job_v1" "fire_planner_recompute" {
  metadata {
    name      = "fire-planner-recompute"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  spec {
    schedule                      = "0 9 2 * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name    = "recompute"
              image   = local.image
              command = ["python", "-m", "fire_planner", "recompute-all"]

              env_from {
                secret_ref {
                  name = "fire-planner-secrets"
                }
              }
              env_from {
                secret_ref {
                  name = "fire-planner-db-creds"
                }
              }

              resources {
                requests = {
                  cpu    = "200m"
                  memory = "1Gi"
                }
                limits = {
                  memory = "2Gi"
                }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

# Plan-time read of the ESO-created K8s Secret for Grafana datasource
# password. First-apply gotcha: must
# `terragrunt apply -target=kubernetes_manifest.db_external_secret` so
# the Secret exists before this data source plans.
data "kubernetes_secret" "fire_planner_db_creds" {
  metadata {
    name      = "fire-planner-db-creds"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  depends_on = [kubernetes_manifest.db_external_secret]
}

# Grafana datasource for fire_planner PostgreSQL DB.
# Lives in the monitoring namespace so the grafana sidecar
# (label grafana_datasource=1) picks it up.
#
# Grafana 11.2+ Postgres plugin reads the DB name from jsonData.database;
# the top-level `database` field is silently ignored by the frontend and
# triggers "you do not have default database" on every panel.
# See github.com/grafana/grafana#112418 — same fix as the payslip-ingest
# datasource (commit cc56ba29).
resource "kubernetes_config_map" "grafana_fire_planner_datasource" {
  metadata {
    name      = "grafana-fire-planner-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "fire-planner-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name   = "FirePlanner"
        type   = "postgres"
        access = "proxy"
        url    = "${var.postgresql_host}:5432"
        user   = "fire_planner"
        uid    = "fire-planner-pg"
        jsonData = {
          database        = "fire_planner"
          sslmode         = "disable"
          postgresVersion = 1600
          timescaledb     = false
        }
        secureJsonData = {
          password = data.kubernetes_secret.fire_planner_db_creds.data["DB_PASSWORD"]
        }
        editable = true
      }]
    })
  }
}
