variable "image_tag" {
  type        = string
  default     = "latest"
  description = "tripit image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "postgresql_host" { type = string }

variable "nfs_server" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "tripit"
  image     = "forgejo.viktorbarzin.me/viktor/tripit:${var.image_tag}"
  labels = {
    app = "tripit"
  }

  # Env shared by the Deployment app container and the three worker CronJobs.
  # Providers are pinned to fakes/no-op until the real integrations are wired:
  #   FLIGHT_PROVIDER=fake, WEATHER_PROVIDER=openmeteo, PUSH_PROVIDER=webpush,
  #   LLM_MODE=fake, MAIL_INGEST_ENABLED=false.
  # AUTH_MODE=forwardauth: the backend trusts the Authentik-injected
  # X-authentik-email header (forward-auth at the ingress). STORAGE_DIR points
  # at the RWX NFS PVC — the app's default ./var is not writable by the
  # non-root user.
  app_env = {
    AUTH_MODE           = "forwardauth"
    SERVE_FRONTEND_DIR  = "/app/frontend_build"
    STORAGE_DIR         = "/data/documents"
    FLIGHT_PROVIDER     = "fake"
    WEATHER_PROVIDER    = "openmeteo"
    PUSH_PROVIDER       = "webpush"
    LLM_MODE            = "fake"
    MAIL_INGEST_ENABLED = "false"
  }
}

resource "kubernetes_namespace" "tripit" {
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
#   secret/tripit
#     VAPID_PUBLIC_KEY      — Web Push (VAPID) public key for push subscriptions
#     VAPID_PRIVATE_KEY     — Web Push (VAPID) private key
#     VAPID_SUBJECT         — VAPID subject (mailto: or https: URL)
#     CALENDAR_TOKEN_SECRET — HMAC secret used to mint/verify the per-user
#                             .ics calendar feed tokens (the /api/calendar
#                             carve-out is gated by these tokens, not Authentik)
#
# Schema in CNPG: `tripit` (alembic creates tables on first migrate).
# DB user: created via Vault database engine — see static-creds/pg-tripit.
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tripit-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tripit-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "VAPID_PUBLIC_KEY", remoteRef = { key = "tripit", property = "VAPID_PUBLIC_KEY" } },
        { secretKey = "VAPID_PRIVATE_KEY", remoteRef = { key = "tripit", property = "VAPID_PRIVATE_KEY" } },
        { secretKey = "VAPID_SUBJECT", remoteRef = { key = "tripit", property = "VAPID_SUBJECT" } },
        { secretKey = "CALENDAR_TOKEN_SECRET", remoteRef = { key = "tripit", property = "CALENDAR_TOKEN_SECRET" } },
        { secretKey = "IMAP_PASSWORD", remoteRef = { key = "tripit", property = "IMAP_PASSWORD" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.tripit]
}

# DB credentials from Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
# Pre-req in dbaas: CNPG cluster has DB `tripit`, role `tripit`, and Vault
# role `static-creds/pg-tripit`.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tripit-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tripit-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://tripit:{{ .password }}@${var.postgresql_host}:5432/tripit"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-tripit"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.tripit]
}

# RWX NFS PVC for the documents vault. Mounted at /data/documents on the
# Deployment app container and on every worker CronJob (they all share the
# same document store, hence RWX). Lives under /srv/nfs on the Proxmox host,
# so the daily-backup pipeline auto-discovers and versions it.
module "documents_nfs" {
  source       = "../../modules/kubernetes/nfs_volume"
  name         = "tripit-documents-host"
  namespace    = kubernetes_namespace.tripit.metadata[0].name
  nfs_server   = var.nfs_server
  nfs_path     = "/srv/nfs/tripit-documents"
  storage      = "5Gi"
  access_modes = ["ReadWriteMany"]
}

resource "kubernetes_deployment" "tripit" {
  metadata {
    name      = "tripit"
    namespace = kubernetes_namespace.tripit.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    # Single leader: APScheduler-style reminders + the RWX document store want
    # one writer. Recreate avoids two pods racing the same NFS volume.
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
          command = ["alembic", "upgrade", "head"]

          env_from {
            secret_ref { name = "tripit-secrets" }
          }
          env_from {
            secret_ref { name = "tripit-db-creds" }
          }

          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name  = "tripit"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref { name = "tripit-secrets" }
          }
          env_from {
            secret_ref { name = "tripit-db-creds" }
          }

          dynamic "env" {
            for_each = local.app_env
            content {
              name  = env.key
              value = env.value
            }
          }

          volume_mount {
            name       = "documents"
            mount_path = "/data/documents"
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
            requests = { cpu = "100m", memory = "384Mi" }
            limits   = { memory = "768Mi" }
          }
        }

        volume {
          name = "documents"
          persistent_volume_claim {
            claim_name = module.documents_nfs.claim_name
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

# Worker CronJobs share the app image + secret/env wiring. Defined via a map
# so the three jobs (poll-flights, run-reminders, ingest-mail) stay identical
# except for schedule, subcommand, and the suspend flag.
locals {
  cronjobs = {
    poll-flights = {
      schedule  = "*/30 * * * *"
      command   = ["python", "-m", "tripit_api", "poll-flights"]
      suspend   = false
      extra_env = {}
    }
    run-reminders = {
      schedule  = "*/15 * * * *"
      command   = ["python", "-m", "tripit_api", "run-reminders"]
      suspend   = false
      extra_env = {}
    }
    # Ongoing forward-to-parse ingest of me@viktorbarzin.me's mailbox. Uses the
    # real local LLM (qwen3vl-4b on llama-swap — qwen3-8b OOMs the shared T4).
    # Read-only IMAP (BODY.PEEK), bounded to the 30 most-recent messages/run;
    # the pipeline is idempotent (skips message_ids already in inbound_email),
    # so re-reading the recent window is a no-op for already-seen mail.
    # IMAP_PASSWORD is injected from secret/tripit via the tripit-secrets ES.
    ingest-mail = {
      schedule = "*/30 * * * *"
      command  = ["python", "-m", "tripit_api", "ingest-mail"]
      suspend  = false
      extra_env = {
        LLM_MODE                 = "llamacpp"
        LLM_ENDPOINT             = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
        LLM_MODEL                = "qwen3vl-4b"
        MAIL_INGEST_ENABLED      = "true"
        MAIL_DEFAULT_OWNER_EMAIL = "me@viktorbarzin.me"
        IMAP_HOST                = "mailserver.mailserver.svc.cluster.local"
        IMAP_PORT                = "993"
        IMAP_USER                = "me@viktorbarzin.me"
        IMAP_FOLDER              = "INBOX"
        IMAP_USE_SSL             = "true"
        IMAP_RECENT_N            = "30"
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "tripit_worker" {
  for_each = local.cronjobs

  metadata {
    name      = "tripit-${each.key}"
    namespace = kubernetes_namespace.tripit.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = each.value.schedule
    suspend                       = each.value.suspend
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
            container {
              name    = "worker"
              image   = local.image
              command = each.value.command

              env_from {
                secret_ref { name = "tripit-secrets" }
              }
              env_from {
                secret_ref { name = "tripit-db-creds" }
              }

              dynamic "env" {
                for_each = merge(local.app_env, each.value.extra_env)
                content {
                  name  = env.key
                  value = env.value
                }
              }

              volume_mount {
                name       = "documents"
                mount_path = "/data/documents"
              }

              resources {
                requests = { cpu = "50m", memory = "256Mi" }
                limits   = { memory = "512Mi" }
              }
            }
            volume {
              name = "documents"
              persistent_volume_claim {
                claim_name = module.documents_nfs.claim_name
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

resource "kubernetes_service" "tripit" {
  metadata {
    name      = "tripit"
    namespace = kubernetes_namespace.tripit.metadata[0].name
    labels    = local.labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8080"
    }
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

# Main host — Authentik forward-auth gates every request. The backend reads
# the injected X-authentik-email header (AUTH_MODE=forwardauth) for multi-user
# SSO; it ships no own login, so Authentik is the gate.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.tripit.metadata[0].name
  name            = "tripit"
  port            = 8080
  tls_secret_name = var.tls_secret_name
}

# Calendar feed carve-out for the same host: path /api/calendar served by the
# bare tripit service, bypassing Authentik.
module "ingress_calendar" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": GET /api/calendar/{token}.ics is token-gated by an HMAC
  # secret (CALENDAR_TOKEN_SECRET), not Authentik — external calendar clients
  # (Apple Calendar, Google, Thunderbird) can't complete the Authentik login
  # dance, so forward-auth would break ICS subscriptions. The token is the gate.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.tripit.metadata[0].name
  name             = "tripit-calendar"
  service_name     = "tripit"
  full_host        = "tripit.viktorbarzin.me"
  ingress_path     = ["/api/calendar"]
  port             = 8080
  tls_secret_name  = var.tls_secret_name
}
