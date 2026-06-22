variable "image_tag" {
  type        = string
  default     = "latest"
  description = "payslip-ingest image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

locals {
  namespace = "payslip-ingest"
  # Image built OFF-INFRA by GitHub Actions, pushed to GHCR (private) — ADR-0002,
  # 2026-06-13 (issue #24): Forgejo viktor/payslip-ingest push-mirrors -> private
  # ViktorBarzin/payslip-ingest GitHub repo -> GHA builds + pushes
  # ghcr.io/viktorbarzin/payslip-ingest. The running Deployment tag is set via
  # `kubectl set image` by the Woodpecker deploy pipeline (image is
  # KEEL_IGNORE_IMAGE below); the CronJob tracks :latest with pull policy Always.
  # (Re-applied 2026-06-13: infra pipeline 148 — a restart of the auto-killed
  # 146 — diffed in reverse and re-applied this stack from a pre-migration
  # tree, stripping the ghcr config above. This touch re-asserts it.)
  image = "ghcr.io/viktorbarzin/payslip-ingest:${var.image_tag}"
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
      # Opt into Keel auto-update (inject-keel-annotations ClusterPolicy).
      "keel.sh/enrolled" = "true"
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
#   secret/payslip-ingest         -> properties:
#                                     - `webhook_bearer_token`
#                                     - `actualbudget_api_key` (same value as
#                                       actualbudget-http-api-viktor random
#                                       api-key — fetch via `kubectl get pods
#                                       -n actualbudget -l
#                                       app=actualbudget-http-api-viktor -o
#                                       jsonpath={.items[0].spec.containers[0].env}`
#                                       and grep API_KEY)
#                                     - `actualbudget_encryption_password`
#                                       (same as Viktor's budget password in
#                                       secret/actualbudget/credentials[viktor])
#                                     - `actualbudget_budget_sync_id`
#                                       (same as Viktor's sync_id)
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
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
        {
          secretKey = "ACTUALBUDGET_API_KEY"
          remoteRef = {
            key      = "payslip-ingest"
            property = "actualbudget_api_key"
          }
        },
        {
          secretKey = "ACTUALBUDGET_ENCRYPTION_PASSWORD"
          remoteRef = {
            key      = "payslip-ingest"
            property = "actualbudget_encryption_password"
          }
        },
        {
          secretKey = "ACTUALBUDGET_BUDGET_SYNC_ID"
          remoteRef = {
            key      = "payslip-ingest"
            property = "actualbudget_budget_sync_id"
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
    apiVersion = "external-secrets.io/v1"
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
        # Private ghcr image (ADR-0002 off-infra builds) — cloned into this
        # namespace by the kyverno sync-ghcr-credentials allowlist policy.
        image_pull_secrets {
          name = "ghcr-credentials"
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

# Daily sync of Meta payroll deposits from ActualBudget's http-api sidecar.
# Populates payslip_ingest.external_meta_deposits so Panel 14 can overlay bank
# deposits against payslip.net_pay — catches parser drift on net_pay.
resource "kubernetes_cron_job_v1" "actualbudget_payroll_sync" {
  metadata {
    name      = "actualbudget-payroll-sync"
    namespace = kubernetes_namespace.payslip_ingest.metadata[0].name
  }
  spec {
    # Suspended 2026-05-12 — chronic JobFailed with
    # `KeyError: 'ACTUALBUDGET_API_KEY'` / `..._ENCRYPTION_PASSWORD`.
    # Vault `secret/payslip-ingest` now has `actualbudget_api_key` and
    # `actualbudget_budget_sync_id` (copied from `secret/fire-planner`),
    # but `actualbudget_encryption_password` is still missing. Unsuspend
    # by removing this line once the encryption password is in Vault.
    suspend                       = true
    schedule                      = "0 2 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    starting_deadline_seconds     = 300

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
            # Private ghcr image (ADR-0002 off-infra builds) — cloned into this
            # namespace by the kyverno sync-ghcr-credentials allowlist policy.
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name  = "sync"
              image = local.image
              # Fleet convention for owned-app CronJobs (ADR-0002): track
              # :latest and re-pull on every run. Replaces the dead SHA pin
              # (:4f70681d) on the decommissioned Forgejo image path.
              image_pull_policy = "Always"
              command           = ["python", "-m", "payslip_ingest", "sync-meta-deposits"]

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
                name  = "ACTUALBUDGET_HTTP_API_URL"
                value = "http://budget-http-api-viktor.actualbudget.svc.cluster.local"
              }

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "256Mi"
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

# ExternalSecret in the monitoring namespace mirroring the rotating
# payslip-ingest DB password. Grafana mounts this via envFromSecrets in
# monitoring/grafana_chart_values.yaml; the datasource ConfigMap below
# references it as $__env{PAYSLIPS_PG_PASSWORD}. Reloader restarts
# Grafana whenever ESO updates this secret (every 7d on rotation).
resource "kubernetes_manifest" "grafana_payslips_db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-payslips-pg-creds"
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-payslips-pg-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            PAYSLIPS_PG_PASSWORD = "{{ .password }}"
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
}

# Grafana datasource for payslip_ingest PostgreSQL DB.
# Lives in the monitoring namespace so the grafana sidecar (label grafana_datasource=1) picks it up.
# Password is injected via $__env{...} from grafana-payslips-pg-creds (above).
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
          password = "$__env{PAYSLIPS_PG_PASSWORD}"
        }
        editable = true
      }]
    })
  }
  depends_on = [kubernetes_manifest.grafana_payslips_db_external_secret]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
