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
  # Phase 3 cutover 2026-05-07. NOTE: the registry-private repo for
  # fire-planner has 0 tags — first build via Woodpecker on the new Forgejo
  # repo (viktor/fire-planner, Dockerfile + .woodpecker.yml added 2026-05-07)
  # must succeed BEFORE the next pod restart, otherwise pulls will 404.
  image = "forgejo.viktorbarzin.me/viktor/fire-planner:${var.image_tag}"
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

# Read-only credentials for the wealthfolio_sync mirror DB (a separate
# Postgres database on the same CNPG cluster). The wealthfolio pod's
# pg-sync sidecar populates `daily_account_valuation` etc. hourly; the
# fire-planner ingest reads those tables via this role.
resource "kubernetes_manifest" "wealthfolio_sync_db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
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
  auth            = "none"
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
