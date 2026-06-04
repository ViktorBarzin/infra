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
    # Outbound mail for linked-email verification — submitted via the cluster
    # mailserver as spam@ (which relays out via Brevo). SMTP_PASSWORD comes from
    # tripit-secrets (mapped to the existing PLANS_IMAP_PASSWORD). PUBLIC_BASE_URL
    # builds the confirmation link mailed to the address.
    EMAIL_PROVIDER  = "smtp"
    SMTP_HOST       = "mailserver.mailserver.svc"
    SMTP_PORT       = "587"
    SMTP_USER       = "spam@viktorbarzin.me"
    SMTP_FROM       = "spam@viktorbarzin.me"
    PUBLIC_BASE_URL = "https://tripit.viktorbarzin.me"
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
        # spam@viktorbarzin.me password — used only by the ingest-plans CronJob
        # (forward-to-parse via the @viktorbarzin.me -> spam@ catch-all).
        { secretKey = "PLANS_IMAP_PASSWORD", remoteRef = { key = "tripit", property = "PLANS_IMAP_PASSWORD" } },
        # Proactive nudges (travel-agent merged into tripit): Slack bot token for
        # chat.postMessage + Dawarich read API key for the current-location
        # lookup. Seeded into secret/tripit from secret/travel-agent and
        # secret/owntracks respectively.
        { secretKey = "SLACK_BOT_TOKEN", remoteRef = { key = "tripit", property = "SLACK_BOT_TOKEN" } },
        { secretKey = "DAWARICH_API_KEY", remoteRef = { key = "tripit", property = "DAWARICH_API_KEY" } },
        # Linked-email verification submits SMTP as spam@; reuse its existing
        # password (no new secret) as SMTP_PASSWORD.
        { secretKey = "SMTP_PASSWORD", remoteRef = { key = "tripit", property = "PLANS_IMAP_PASSWORD" } },
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
    # Ongoing forward-to-parse ingest of vbarzin@gmail.com — Viktor's real
    # travel mailbox (the self-hosted me@ box receives no booking mail). LLM =
    # qwen3vl-4b on llama-swap (qwen3-8b OOMs the shared T4). Read-only
    # IMAP_SEARCH over [Gmail]/All Mail (BODY.PEEK, never sets \Seen), bounded
    # to a rolling 12-month window of travel-sender mail via Gmail X-GM-RAW; the
    # two Croatia Jet2 refs (33W6Y3/33W7L2) are excluded so the hand-curated
    # Croatia trip isn't duplicated. Idempotent (skips message_ids already in
    # inbound_email). Trips land under MAIL_DEFAULT_OWNER_EMAIL (vbarzin@gmail.com
    # — Viktor's Authentik login identity, so trips show up in his account).
    # IMAP_PASSWORD (the vbarzin@gmail.com app-password) comes from secret/tripit
    # via the tripit-secrets ES.
    ingest-mail = {
      schedule = "*/30 * * * *"
      command  = ["python", "-m", "tripit_api", "ingest-mail"]
      suspend  = false
      extra_env = {
        LLM_MODE                 = "llamacpp"
        LLM_ENDPOINT             = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
        LLM_MODEL                = "qwen3vl-4b"
        MAIL_INGEST_ENABLED      = "true"
        MAIL_DEFAULT_OWNER_EMAIL = "vbarzin@gmail.com"
        IMAP_HOST                = "imap.gmail.com"
        IMAP_PORT                = "993"
        IMAP_USER                = "vbarzin@gmail.com"
        IMAP_FOLDER              = "[Gmail]/All Mail"
        IMAP_USE_SSL             = "true"
        IMAP_SEARCH              = "X-GM-RAW \"newer_than:12m -33W6Y3 -33W7L2 (from:jet2.com OR from:ryanair.com OR from:easyjet.com OR from:wizzair.com OR from:booking.com OR from:airbnb.com OR from:expedia.com OR from:croatiaairlines.com OR from:vueling.com OR from:lufthansa.com OR from:trainline)\""
      }
    }
    # Forward-to-parse: forward any booking confirmation to plans@viktorbarzin.me
    # (which the @viktorbarzin.me catch-all delivers into the spam@ mailbox), and
    # this job ingests it. Polls spam@ read-only, filtered by IMAP SEARCH to mail
    # addressed To plans@ — so only deliberate forwards are processed, not the
    # rest of the catch-all junk. The LLM extracts segments and the pipeline
    # attaches them to the date-overlapping trip (or creates one) under
    # MAIL_DEFAULT_OWNER_EMAIL. IMAP_PASSWORD is overridden for this job to
    # spam@'s password via imap_password_key (secret/tripit PLANS_IMAP_PASSWORD),
    # because env_from otherwise injects the Gmail app-password.
    ingest-plans = {
      schedule          = "*/15 * * * *"
      command           = ["python", "-m", "tripit_api", "ingest-mail"]
      suspend           = false
      imap_pw_secret_key = "PLANS_IMAP_PASSWORD"
      extra_env = {
        LLM_MODE                 = "llamacpp"
        LLM_ENDPOINT             = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
        LLM_MODEL                = "qwen3vl-4b"
        MAIL_INGEST_ENABLED      = "true"
        MAIL_DEFAULT_OWNER_EMAIL = "vbarzin@gmail.com"
        IMAP_HOST                = "mailserver.mailserver.svc.cluster.local"
        IMAP_PORT                = "993"
        IMAP_USER                = "spam@viktorbarzin.me"
        IMAP_FOLDER              = "INBOX"
        IMAP_USE_SSL             = "true"
        IMAP_SEARCH              = "TO \"plans@viktorbarzin.me\""
      }
    }
    # Proactive nudges (travel-agent merged into tripit, beads code-muqi).
    # London-local schedules (timeZone honoured by K8s 1.27+). NUDGES_ENABLED
    # gates the workers; Slack + Dawarich providers selected here. The app_env
    # base already sets WEATHER_PROVIDER=openmeteo + PUSH_PROVIDER=webpush.
    # SLACK_BOT_TOKEN + DAWARICH_API_KEY arrive via env_from tripit-secrets;
    # SLACK_CHANNEL (#travel) falls back to the config default. DAWARICH_BASE_URL
    # uses the PUBLIC host deliberately: Dawarich is a Rails app whose host
    # authorization 403s the in-cluster *.svc Host header, so we reach it through
    # the ingress (auth=none, api_key-gated) instead.
    transport-nudge = {
      schedule  = "0 8 * * *"
      timezone  = "Europe/London"
      command   = ["python", "-m", "tripit_api", "run-transport-nudge"]
      suspend   = false
      extra_env = {
        NUDGES_ENABLED    = "true"
        SLACK_PROVIDER    = "slack"
        LOCATION_PROVIDER = "dawarich"
        DAWARICH_BASE_URL = "https://dawarich.viktorbarzin.me"
      }
    }
    weather-brief = {
      schedule  = "0 21 * * *"
      timezone  = "Europe/London"
      command   = ["python", "-m", "tripit_api", "run-weather-brief"]
      suspend   = false
      extra_env = {
        NUDGES_ENABLED    = "true"
        SLACK_PROVIDER    = "slack"
        LOCATION_PROVIDER = "dawarich"
        DAWARICH_BASE_URL = "https://dawarich.viktorbarzin.me"
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
    timezone                      = lookup(each.value, "timezone", null)
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

              # Per-job IMAP_PASSWORD override from a secret key. An explicit env
              # takes precedence over env_from, so a job that polls a different
              # mailbox (ingest-plans -> spam@) gets its own password instead of
              # the default IMAP_PASSWORD (vbarzin@gmail.com) from tripit-secrets.
              dynamic "env" {
                for_each = lookup(each.value, "imap_pw_secret_key", null) != null ? [1] : []
                content {
                  name = "IMAP_PASSWORD"
                  value_from {
                    secret_key_ref {
                      name = "tripit-secrets"
                      key  = each.value.imap_pw_secret_key
                    }
                  }
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

# Linked-email confirm carve-out: GET /api/emails/confirm?token=… is gated by the
# verification token mailed to the address (not Authentik), so the emailed link
# works without a session — same shape as the calendar feed carve-out.
module "ingress_emails_confirm" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": GET /api/emails/confirm?token=… is gated by the verification
  # token mailed to the address (not Authentik), so the emailed link works
  # without a session — same rationale as the calendar feed carve-out.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.tripit.metadata[0].name
  name             = "tripit-emails-confirm"
  service_name     = "tripit"
  full_host        = "tripit.viktorbarzin.me"
  ingress_path     = ["/api/emails/confirm"]
  port             = 8080
  tls_secret_name  = var.tls_secret_name
}
