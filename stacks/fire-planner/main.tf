variable "image_tag" {
  type        = string
  default     = "latest"
  description = "fire-planner image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "fire-planner"
  # ADR-0002 off-infra builds (2026-06-13, issue infra#26): GHA on the GitHub
  # mirror builds + pushes ghcr.io/viktorbarzin/fire-planner (:sha8 + :latest);
  # Woodpecker is deploy-only. PRIVATE ghcr package — every pod spec pulls via
  # the ghcr-credentials Secret (kyverno sync-ghcr-credentials allowlist).
  # registry-credentials stays alongside so the currently-running sha-pinned
  # forgejo image remains pullable until the first ghcr deploy lands.
  # (Applied via the 2026-06-13 re-trigger commit: the original pipeline 150
  # was auto-killed by a concurrent nextcloud-todos master push before its
  # apply step ran, and the successor's diff base excluded this stack.)
  image = "ghcr.io/viktorbarzin/fire-planner:${var.image_tag}"
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
      # Lets us drive the deployed UI from the in-cluster chrome-service
      # for headless verification (NetworkPolicy in chrome-service ns admits
      # any namespace carrying this label).
      "chrome-service.viktorbarzin.me/client" = "true"
      # Opt into Keel auto-update (inject-keel-annotations ClusterPolicy).
      "keel.sh/enrolled" = "true"
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
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
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
        {
          secretKey = "ACTUALBUDGET_API_URL"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_api_url"
          }
        },
        {
          secretKey = "ACTUALBUDGET_API_KEY"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_api_key"
          }
        },
        {
          secretKey = "ACTUALBUDGET_SYNC_ID"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_sync_id"
          }
        },
        # Anca's SEPARATE actualbudget instance — drives her half of the
        # Household/Family FIRE spend (live_anca_or_default in the recompute).
        {
          secretKey = "ACTUALBUDGET_ANCA_API_URL"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_anca_api_url"
          }
        },
        {
          secretKey = "ACTUALBUDGET_ANCA_API_KEY"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_anca_api_key"
          }
        },
        {
          secretKey = "ACTUALBUDGET_ANCA_SYNC_ID"
          remoteRef = {
            key      = "fire-planner"
            property = "actualbudget_anca_sync_id"
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
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
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

# Read-only credentials for the wealthfolio_sync mirror DB (a separate
# Postgres database on the same CNPG cluster). The wealthfolio pod's
# pg-sync sidecar populates `daily_account_valuation` etc. hourly; the
# fire-planner ingest reads those tables via this role.
resource "kubernetes_manifest" "wealthfolio_sync_db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealthfolio-sync-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealthfolio-sync-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            WEALTHFOLIO_SYNC_DB_CONNECTION_STRING = "postgresql+asyncpg://wealthfolio_sync:{{ .password }}@${var.postgresql_host}:5432/wealthfolio_sync"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-wealthfolio-sync"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.fire_planner]
}

# tls-secret for fire-planner.viktorbarzin.me is auto-cloned into every
# namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local module
# call needed.

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
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        init_container {
          name              = "alembic-migrate"
          image             = local.image
          image_pull_policy = "Always"
          command           = ["python", "-m", "fire_planner", "migrate"]

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
          env_from {
            secret_ref {
              name = "wealthfolio-sync-db-creds"
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
              memory = "192Mi"
            }
            limits = {
              memory = "320Mi"
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

# Monthly recompute on the 2nd at 09:00 UTC.
#
# This runs `recompute-all` (the Monte Carlo Cartesian sweep), NOT
# `ingest`. The /networth path no longer depends on an ingest CronJob —
# as of 2026-05-27 the account_snapshot cache is refreshed lazily on
# every /networth, /networth/history, /progress request when older than
# NETWORTH_CACHE_TTL_DAYS (default 1). See
# fire_planner/ingest/wealthfolio.py :: refresh_account_snapshots_if_stale.
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
            image_pull_secrets {
              name = "ghcr-credentials"
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
              env_from {
                secret_ref {
                  name = "wealthfolio-sync-db-creds"
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
    kubernetes_manifest.wealthfolio_sync_db_external_secret,
  ]
}

# Monthly FIRE-countdown target solve on the 2nd at 10:00 UTC (an hour after
# recompute-all, so account_snapshot is fresh). Binary-searches each Case's FIRE
# number per country at the 99% Guyton-Klinger bar and upserts fire_target, which
# the wealth Grafana dashboard's "FIRE Countdown" section reads.
resource "kubernetes_cron_job_v1" "fire_planner_fire_targets" {
  metadata {
    name      = "fire-planner-fire-targets"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  spec {
    schedule                      = "0 10 2 * *"
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
        # The full country sweep is CPU-bound (binary search × ~22 cities ×
        # 3 cases). Give it room rather than letting it run forever.
        active_deadline_seconds = 3600
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name  = "fire-targets"
              image = local.image
              # --horizon 72: Viktor retires ~age 28 and plans to live to 100, so
              # the portfolio must last 72 years (was the 60y default ≈ to age 88).
              command = ["python", "-m", "fire_planner", "recompute-fire-targets",
              "--countries", "all", "--horizon", "72"]

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
                  cpu    = "500m"
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

# Weekly refresh of the COL cache: walks col_snapshot for rows
# expiring within 7 days, re-scrapes Numbeo + Expatistan, upserts. With
# the user-chosen 1-year TTL, a healthy cache has 0 stale rows on most
# Sundays — the job is a no-op until rows age out. Schedule Sunday 04:00
# UTC so Numbeo's contributor activity (mostly weekday) doesn't race
# our reads.
resource "kubernetes_cron_job_v1" "fire_planner_col_refresh" {
  metadata {
    name      = "fire-planner-col-refresh"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  spec {
    schedule                      = "0 4 * * 0"
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
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name    = "col-refresh"
              image   = local.image
              command = ["python", "-m", "fire_planner", "col-refresh-stale", "--within-days", "7"]

              env_from {
                secret_ref {
                  name = "fire-planner-db-creds"
                }
              }

              resources {
                requests = {
                  cpu    = "100m"
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
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }

  depends_on = [
    kubernetes_manifest.db_external_secret,
  ]
}

# Public ingress at fire-planner.viktorbarzin.me. Authentik-protected
# (forward-auth at the Traefik layer); Cloudflare-proxied for CDN +
# DDoS shielding. Backend FastAPI serves the SPA at / and the API
# under /api/* (FRONTEND_DIST=/app/frontend_dist, baked into the image).
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.fire_planner.metadata[0].name
  name            = "fire-planner"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "FIRE Planner"
    "gethomepage.dev/description" = "Risk-adjusted retirement projections (ProjectionLab clone)"
    "gethomepage.dev/icon"        = "mdi-fire"
    "gethomepage.dev/group"       = "Finance"
  }
}

# Second ingress at the same host for the /api/ prefix WITHOUT Authentik
# forward-auth. The SPA loads under Authentik (main ingress at /), then its
# fetch() XHRs hit /api/* directly — ANY forward-auth here (required OR
# public-tier auto-bind) would 302 the XHR to a cross-origin Authentik
# login page, which fetch() rejects under CORS preflight rules. Even the
# `auth = "public"` flow needs a 302+cookie dance on first visit to set
# the guest session cookie, so it doesn't help XHR APIs. App-layer bearer
# auth still gates writes (POST/PATCH/DELETE on scenarios, /recompute,
# /simulate); read endpoints are open. Acceptable for a personal tool
# whose only data is anonymous numeric projections.
module "ingress_api" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "none"
  namespace       = kubernetes_namespace.fire_planner.metadata[0].name
  name            = "fire-planner-api"
  host            = "fire-planner" # share effective_host with main ingress
  service_name    = "fire-planner"
  port            = 8080
  ingress_path    = ["/api/"]
  tls_secret_name = var.tls_secret_name
  # auth = "none": XHR-based API endpoints; forward-auth 302+cookie-dance breaks CORS preflight and browser fetch().
  auth = "none"
}

# ExternalSecret in the monitoring namespace mirroring the rotating
# fire_planner DB password. Grafana mounts this via envFromSecrets in
# monitoring/grafana_chart_values.yaml; the datasource ConfigMap below
# references it as $__env{FIRE_PLANNER_PG_PASSWORD}. Reloader restarts
# Grafana whenever ESO updates this secret (on the 7d static-role
# rotation), so the provisioned datasource never goes stale — replaces
# the old plan-time `data.kubernetes_secret` bake that broke weekly.
# Mirrors the wealth-pg / payslips-pg pattern.
resource "kubernetes_manifest" "grafana_fire_planner_pg_creds" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-fire-planner-pg-creds"
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "grafana-fire-planner-pg-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            FIRE_PLANNER_PG_PASSWORD = "{{ .password }}"
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
          # Live env from grafana-fire-planner-pg-creds (above), injected into
          # Grafana via envFromSecrets; reloader refreshes it on rotation.
          password = "$__env{FIRE_PLANNER_PG_PASSWORD}"
        }
        editable = true
      }]
    })
  }
  depends_on = [kubernetes_manifest.grafana_fire_planner_pg_creds]
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# ----------------------------------------------------------------------
# Reddit FIRE examples ingest — Job (bulk, toggled) + weekly CronJob
# Backs the fire_planner.examples module. See:
#   ~/code/fire-planner/docs/plans/2026-05-28-reddit-examples-{design,plan}.md
# ----------------------------------------------------------------------

variable "llama_cpp_base_url" {
  type        = string
  description = "llama-swap /v1/chat/completions endpoint for primary LLM extraction"
  # Service is named `llama-swap`, NOT `llama-cpp` — the proxy in front of
  # the actual llama-cpp pod. Port 8080. (Initial 2026-05-28 value pointed
  # at a non-existent service:port and the bulk Job produced 0 rows.)
  default = "http://llama-swap.llama-cpp.svc.cluster.local:8080/v1/chat/completions"
}

variable "claude_agent_service_url" {
  type        = string
  description = "claude-agent-service /v1/chat/completions endpoint for Tier 2 fallback"
  default     = "http://claude-agent-service.claude-agent.svc.cluster.local:8080/v1/chat/completions"
}

variable "examples_llm_model" {
  type        = string
  description = "llama-swap model id for the examples LLM primary extractor. Use qwen3-8b when GPU has ≥5GB free; qwen3vl-4b when immich-ml is using ~10GB."
  default     = "qwen3vl-4b"
}

variable "run_examples_bulk_ingest" {
  type        = bool
  description = "Flip to true once to bulk-populate fire_example. Reset to false after."
  default     = false
}

# Reddit OAuth creds pulled from Vault secret/viktor.
resource "kubernetes_manifest" "external_secret_examples_reddit" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "fire-planner-examples-reddit"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "fire-planner-examples-reddit"
      }
      data = [
        {
          secretKey = "REDDIT_CLIENT_ID"
          remoteRef = {
            key      = "viktor"
            property = "trading_bot_reddit_client_id"
          }
        },
        {
          secretKey = "REDDIT_CLIENT_SECRET"
          remoteRef = {
            key      = "viktor"
            property = "trading_bot_reddit_client_secret"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.fire_planner]
}

# claude-agent-service bearer pulled separately so its rotation cadence
# is decoupled from the Reddit creds.
resource "kubernetes_manifest" "external_secret_examples_claude" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "fire-planner-examples-claude"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "fire-planner-examples-claude"
      }
      data = [
        {
          secretKey = "CLAUDE_AGENT_BEARER"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.fire_planner]
}

# Bulk one-shot Job — toggled via var.run_examples_bulk_ingest. Flip to
# true once, apply, wait for completion, flip back. The timestamp() in
# the name ensures Terraform creates a fresh Job on each (true)
# transition rather than refusing to recreate an existing one.
resource "kubernetes_job_v1" "examples_bulk_ingest" {
  count = var.run_examples_bulk_ingest ? 1 : 0
  metadata {
    name      = "fire-planner-examples-bulk-${formatdate("YYYYMMDDhhmm", timestamp())}"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  spec {
    backoff_limit = 0
    template {
      metadata {
        labels = local.labels
      }
      spec {
        restart_policy = "OnFailure"
        image_pull_secrets {
          name = "registry-credentials"
        }
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        container {
          name              = "ingest"
          image             = local.image
          image_pull_policy = "IfNotPresent"
          command = ["python", "-m", "fire_planner", "examples", "ingest",
          "--top=all,year", "--limit=1000"]

          # DB plumbing — mirror the fire_planner_recompute CronJob.
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
          env_from {
            secret_ref {
              name = "wealthfolio-sync-db-creds"
            }
          }

          # Examples-specific vars.
          env {
            name = "REDDIT_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "fire-planner-examples-reddit"
                key  = "REDDIT_CLIENT_ID"
              }
            }
          }
          env {
            name = "REDDIT_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "fire-planner-examples-reddit"
                key  = "REDDIT_CLIENT_SECRET"
              }
            }
          }
          env {
            name = "CLAUDE_AGENT_BEARER"
            value_from {
              secret_key_ref {
                name = "fire-planner-examples-claude"
                key  = "CLAUDE_AGENT_BEARER"
              }
            }
          }
          env {
            name  = "REDDIT_USER_AGENT"
            value = "fire-planner/0.1"
          }
          env {
            name  = "LLAMA_CPP_BASE_URL"
            value = var.llama_cpp_base_url
          }
          env {
            name  = "CLAUDE_AGENT_SERVICE_URL"
            value = var.claude_agent_service_url
          }
          env {
            name  = "LLM_MODEL"
            value = var.examples_llm_model
          }
          env {
            name  = "LLM_CONCURRENCY"
            value = "3"
          }
        }
      }
    }
  }
  lifecycle {
    # The name embeds a timestamp so a re-plan after time has passed
    # would otherwise propose a no-op rename. Ignore.
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [
      metadata[0].name,
      spec[0].template[0].spec[0].dns_config,
    ]
  }
  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
    kubernetes_manifest.wealthfolio_sync_db_external_secret,
    kubernetes_manifest.external_secret_examples_reddit,
    kubernetes_manifest.external_secret_examples_claude,
  ]
}

# Weekly delta — top-of-week milestone posts. Sunday 04:00 UTC.
resource "kubernetes_cron_job_v1" "examples_weekly_delta" {
  metadata {
    name      = "fire-planner-examples-weekly"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  spec {
    schedule                      = "0 4 * * 0"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 0
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
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name              = "ingest"
              image             = local.image
              image_pull_policy = "IfNotPresent"
              command = ["python", "-m", "fire_planner", "examples", "ingest",
              "--top=week", "--limit=200"]

              # DB plumbing — mirror the fire_planner_recompute CronJob.
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
              env_from {
                secret_ref {
                  name = "wealthfolio-sync-db-creds"
                }
              }

              # Examples-specific vars — keep in sync with the bulk Job.
              env {
                name = "REDDIT_CLIENT_ID"
                value_from {
                  secret_key_ref {
                    name = "fire-planner-examples-reddit"
                    key  = "REDDIT_CLIENT_ID"
                  }
                }
              }
              env {
                name = "REDDIT_CLIENT_SECRET"
                value_from {
                  secret_key_ref {
                    name = "fire-planner-examples-reddit"
                    key  = "REDDIT_CLIENT_SECRET"
                  }
                }
              }
              env {
                name = "CLAUDE_AGENT_BEARER"
                value_from {
                  secret_key_ref {
                    name = "fire-planner-examples-claude"
                    key  = "CLAUDE_AGENT_BEARER"
                  }
                }
              }
              env {
                name  = "REDDIT_USER_AGENT"
                value = "fire-planner/0.1"
              }
              env {
                name  = "LLAMA_CPP_BASE_URL"
                value = var.llama_cpp_base_url
              }
              env {
                name  = "CLAUDE_AGENT_SERVICE_URL"
                value = var.claude_agent_service_url
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
    kubernetes_manifest.wealthfolio_sync_db_external_secret,
    kubernetes_manifest.external_secret_examples_reddit,
    kubernetes_manifest.external_secret_examples_claude,
  ]
}
