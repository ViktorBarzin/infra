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
  # Image now built OFF-INFRA by GitHub Actions, pushed to GHCR (private), 2026-06-09:
  # Forgejo viktor/tripit push-mirrors -> private ViktorBarzin/tripit GitHub repo ->
  # GHA builds + pushes ghcr.io/viktorbarzin/tripit. Removes both the build IO and the
  # Forgejo/sdc registry push from the homelab. Running tag is set via `kubectl set
  # image` (image is KEEL_IGNORE_IMAGE below); CronJobs track :latest.
  image = "ghcr.io/viktorbarzin/tripit:${var.image_tag}"
  labels = {
    app = "tripit"
  }

  # Env shared by the Deployment app container and the worker CronJobs.
  # Real integrations: FLIGHT_PROVIDER=aerodatabox + RAIL_PROVIDER=realtimetrains
  # (keys via the tripit-secrets ExternalSecret), WEATHER_PROVIDER=openmeteo,
  # GEOCODER_PROVIDER=openmeteo, PUSH_PROVIDER=webpush. LLM_MODE=fake and
  # MAIL_INGEST_ENABLED=false here (the ingest-plans CronJob overrides both).
  # AUTH_MODE=forwardauth: the backend trusts the Authentik-injected
  # X-authentik-email header (forward-auth at the ingress). STORAGE_DIR points
  # at the RWX NFS PVC — the app's default ./var is not writable by the
  # non-root user.
  app_env = {
    AUTH_MODE            = "forwardauth"
    SERVE_FRONTEND_DIR   = "/app/frontend_build"
    STORAGE_DIR          = "/data/documents"
    PERSONAL_STORAGE_DIR = "/data/personal-documents"
    # Live flight status via AeroDataBox (RapidAPI). Free BASIC plan = 600
    # units/month, 1 unit per flight-by-number call, gate/terminal included.
    # AERODATABOX_API_KEY arrives via the tripit-secrets ExternalSecret;
    # AERODATABOX_BASE_URL defaults to the RapidAPI host in config.
    FLIGHT_PROVIDER = "aerodatabox"
    # UK rail status via Realtime Trains (data.rtt.io). RTT_API_TOKEN (a
    # long-life refresh token, already in Vault) arrives via tripit-secrets; the
    # adapter exchanges it for short-life access tokens. On-demand only — no
    # rail poller CronJob, so rail status is fetched when a segment is opened.
    RAIL_PROVIDER    = "realtimetrains"
    WEATHER_PROVIDER = "openmeteo"
    # Geocodes lodging addresses -> coords for the per-city itinerary weather
    # (Open-Meteo keyless geocoding API; results cached in the geocode_cache table).
    GEOCODER_PROVIDER   = "openmeteo"
    PUSH_PROVIDER       = "webpush"
    LLM_MODE            = "fake"
    MAIL_INGEST_ENABLED = "false"
    # Outbound mail (linked-email verification + trip-share invites) — submitted
    # via the cluster mailserver authenticated as spam@ (SMTP_USER), but sent
    # From: plans@viktorbarzin.me (SMTP_FROM). docker-mailserver SPOOF_PROTECTION
    # requires the login to "own" the From; an explicit plans@ -> spam@ virtual
    # alias grants that (see mailserver extra/aliases.txt) and keeps inbound
    # plans@ routing to spam@. Relays out via Brevo. SMTP_PASSWORD comes from
    # tripit-secrets (the existing PLANS_IMAP_PASSWORD = spam@'s password).
    # PUBLIC_BASE_URL builds the links mailed to recipients.
    EMAIL_PROVIDER  = "smtp"
    SMTP_HOST       = "mailserver.mailserver.svc"
    SMTP_PORT       = "587"
    SMTP_USER       = "spam@viktorbarzin.me"
    SMTP_FROM       = "plans@viktorbarzin.me"
    PUBLIC_BASE_URL = "https://tripit.viktorbarzin.me"
    # Narrator audio (ADR-0004): Chatterbox via the in-cluster `tts` stack.
    # OpenAI-compatible /v1/audio/speech; the bake POSTs best-effort synth
    # requests, so a down/Pending Chatterbox is a clean skip (browser-TTS
    # fallback), never a bake error. ClusterIP-only → no token. Note: the mode
    # is `openai_compatible` (tripit renamed it from `chatterbox`); TTS_MODEL is
    # still the `chatterbox` family string tripit sends as the OpenAI `model`.
    TTS_MODE     = "openai_compatible"
    TTS_BASE_URL = "http://chatterbox-tts.tts.svc.cluster.local:8000"
    TTS_MODEL    = "chatterbox"
    # Live flight-fare scrape (tripit ADR-0007, issue #18): Playwright driving
    # the SHARED chrome-service browser over CDP (no per-pod browser). The
    # provider rate-limits (30s min interval), caches 6h, backs off 300s on
    # failure, and degrades to manual entry — never blocks the grid. NOTE:
    # FareMode `playwright` only exists in images >= the #18 slice; setting
    # this against an older image crash-loops on the unknown enum (old pods
    # keep serving), so the env landed AFTER that image rolled out.
    FARE_PROVIDER = "playwright"
    FARE_CDP_URL  = "http://chrome-service.chrome-service.svc.cluster.local:9222"
    # Calendar-conflict column (tripit issue #19): read the owner's Nextcloud
    # calendar over CalDAV to flag date clashes on a planning Option. Base +
    # user are non-secret; the app-password arrives via tripit-secrets. Same
    # image-first hold-order as FARE_PROVIDER — `nextcloud` mode only exists in
    # images >= the #19 slice (older images crash-loop on the unknown enum).
    CALENDAR_CONFLICT_PROVIDER = "nextcloud"
    NEXTCLOUD_CALDAV_BASE      = "https://nextcloud.viktorbarzin.me/remote.php/dav"
    NEXTCLOUD_CALDAV_USER      = "admin"
    # Live "Research this" agent (tripit issue #23, ADR-0008): opt-in per-Decision
    # research via the in-cluster claude-agent-service (the `trip-planner` agent),
    # budget-capped ~$2/run, bounded to a wall-clock deadline so a slow agent
    # degrades to "found nothing" rather than a 504. Reuses CLAUDE_AGENT_TOKEN
    # (already in tripit-secrets, shared with the tour ScriptWriter + planner bot)
    # — shares the Anthropic OAuth quota, hence opt-in not always-on. Flipped live
    # 2026-06-11 after a prod-pod behaviour review (country_when proposed
    # not-yet-visited countries + real UK bank-holiday leave windows + fares).
    # `claude_agent` mode requires images >= the #23 slice (already deployed).
    RESEARCH_PROVIDER = "claude_agent"
    # Stay cover photos (tripit issue #47, ADR-0017): auto-fetch each picked
    # city's Wikipedia lead image (keyless REST summary API, "City, Country"
    # first), downloaded into the app's STORAGE_DIR (never hotlinked) and
    # served by the backend; editable per Stay (URL/upload). Fetches run
    # post-commit under an 8s budget and degrade to a placeholder — never
    # block trip creation. `wikipedia` mode requires images >= the #47 slice
    # (older images crash-loop on the unknown enum) — landed after that
    # image rolled out, same hold-order as FARE/CALENDAR/RESEARCH above.
    CITY_IMAGE_PROVIDER = "wikipedia"
    # Tour-guide content pipeline (tripit#24/#25): these three default to `fake`
    # in tripit's config, which is what shipped dark on 2026-06-08 — prod only
    # ever showed the placeholder "Sight 1". Real providers: Wikipedia GeoSearch
    # discovery, the five web story sources, and the claude-agent-service script
    # writer (CLAUDE_AGENT_TOKEN already in tripit-secrets).
    # wikipedia+llm = GeoSearch merged with claude-agent-service "what's worth
    # seeing here" proposals (tripit#29); the place resolver backs manual sight
    # search AND LLM-proposal resolution — its fake default is the same class of
    # gap that shipped the feature dark, so set it explicitly.
    SIGHT_DISCOVERY_PROVIDER = "wikipedia+llm"
    STORY_SOURCE_MODE        = "web"
    SCRIPT_WRITER_MODE       = "chat"
    PLACE_RESOLVER_MODE      = "wikipedia"
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
      # Admit this namespace through chrome-service's CDP NetworkPolicy
      # (chrome-service-ws-ingress) — the fare scrape (#18) drives the
      # shared browser on :9222.
      "chrome-service.viktorbarzin.me/client" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# GHCR pull secret: the ghcr-credentials Secret in this namespace is cloned in
# by the kyverno stack's sync-ghcr-credentials ClusterPolicy (allowlisted
# private-ghcr namespaces only — ADR-0002). Source of truth:
# stacks/kyverno/modules/kyverno/ghcr-credentials.tf.

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
        { secretKey = "DOCUMENT_ENCRYPTION_KEY", remoteRef = { key = "tripit", property = "DOCUMENT_ENCRYPTION_KEY" } },
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
        # Live flight status — AeroDataBox key (RapidAPI free BASIC plan, 600
        # units/month). Seed secret/tripit AERODATABOX_API_KEY before applying.
        { secretKey = "AERODATABOX_API_KEY", remoteRef = { key = "tripit", property = "AERODATABOX_API_KEY" } },
        # UK rail status — Realtime Trains (data.rtt.io) long-life refresh token.
        { secretKey = "RTT_API_TOKEN", remoteRef = { key = "tripit", property = "RTT_API_TOKEN" } },
        # Planner subsystem (merged trip-planner): Slack v0-signature secret + TREK
        # creds + claude-agent token. SLACK_BOT_TOKEN above is reused (nudges + planner).
        { secretKey = "SLACK_SIGNING_SECRET", remoteRef = { key = "tripit", property = "SLACK_SIGNING_SECRET" } },
        { secretKey = "TREK_USER", remoteRef = { key = "tripit", property = "TREK_USER" } },
        { secretKey = "TREK_PASSWORD", remoteRef = { key = "tripit", property = "TREK_PASSWORD" } },
        { secretKey = "CLAUDE_AGENT_TOKEN", remoteRef = { key = "tripit", property = "CLAUDE_AGENT_TOKEN" } },
        # Read-only Nextcloud app-password for the calendar-conflict column
        # (tripit issue #19) — CalDAV PROPFIND/REPORT only. Single-account: this
        # is the owner's (admin's) calendar, so every tripit user's conflict
        # check reflects viktor's availability (v1 caveat, documented in-app).
        { secretKey = "NEXTCLOUD_CALDAV_APP_PASSWORD", remoteRef = { key = "tripit", property = "NEXTCLOUD_CALDAV_APP_PASSWORD" } },
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

# RWO encrypted PVC for the PERSONAL document vault (passports, IDs). Separate
# from the RWX NFS trip-doc store: owner-private identity docs get LUKS2 at-rest
# (proxmox-lvm-encrypted) UNDER the app-layer AES-256-GCM ciphertext (defense in
# depth). RWO is safe because the Deployment is replicas=1 + Recreate (single
# writer); only the app container mounts it, not the worker CronJobs.
resource "kubernetes_persistent_volume_claim" "personal_documents" {
  wait_until_bound = false
  metadata {
    name      = "tripit-personal-documents"
    namespace = kubernetes_namespace.tripit.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
  lifecycle {
    # Autoresizer grows requests.storage up to storage_limit; PVCs can't shrink.
    ignore_changes = [spec[0].resources[0].requests]
  }
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
        image_pull_secrets {
          name = "ghcr-credentials"
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

        # The proxmox-lvm-encrypted block PVC mounts root-owned; the app runs as
        # uid 10001. chown it so the non-root app can write. Scoped to THIS block
        # volume only (a pod-level fsGroup would also recursively chown the NFS
        # doc vault, whose CSI fsGroupPolicy=File — risky on a root-squashed
        # export). The NFS vault handles its own perms and is left untouched.
        init_container {
          name    = "chown-personal-documents"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown -R 10001:999 /data/personal-documents"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "personal-documents"
            mount_path = "/data/personal-documents"
          }
          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { memory = "32Mi" }
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

          volume_mount {
            name       = "personal-documents"
            mount_path = "/data/personal-documents"
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

        volume {
          name = "personal-documents"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.personal_documents.metadata[0].name
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

# Worker CronJobs share the app image + secret/env wiring. Defined via a map so
# the jobs stay identical except for schedule, subcommand, and the suspend flag.
locals {
  cronjobs = {
    # Hourly (not */30) to stay within AeroDataBox's free 600-unit/month quota:
    # the sweep spends 1 unit per soon-departing flight per run. On-demand reads
    # (the segment status endpoint) still refresh on a 30-min staleness window
    # when the user opens the app, so this only paces background change-detection.
    poll-flights = {
      schedule  = "0 * * * *"
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
    # Forward-to-parse — the SOLE ingest channel: forward any booking
    # confirmation to plans@viktorbarzin.me (which the @viktorbarzin.me catch-all
    # delivers into the spam@ mailbox), and this job ingests it. Polls spam@
    # read-only, filtered by IMAP SEARCH to mail addressed To plans@ — so only
    # deliberate forwards are processed, not the rest of the catch-all junk. The
    # sender is routed to a registered user (primary email or a verified linked
    # address); mail from anyone else is ignored — there is no default-owner
    # fallback. On a parsed/failed outcome the sender is emailed an "Added to
    # trip" / "Couldn't import" notice (EMAIL_PROVIDER/SMTP_* from app_env;
    # SMTP_PASSWORD via the tripit-secrets ES). IMAP_PASSWORD is overridden to
    # spam@'s password via imap_pw_secret_key (secret/tripit PLANS_IMAP_PASSWORD),
    # because env_from otherwise injects the Gmail app-password. (The old
    # Gmail-scrape ingest-mail CronJob was removed 2026-06-05 — plans@ is now the
    # only inbound path; no more auto-scraping vbarzin@gmail.com.)
    ingest-plans = {
      schedule           = "*/15 * * * *"
      command            = ["python", "-m", "tripit_api", "ingest-mail"]
      suspend            = false
      imap_pw_secret_key = "PLANS_IMAP_PASSWORD"
      extra_env = {
        LLM_MODE            = "llamacpp"
        LLM_ENDPOINT        = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
        LLM_MODEL           = "qwen3vl-4b"
        MAIL_INGEST_ENABLED = "true"
        IMAP_HOST           = "mailserver.mailserver.svc.cluster.local"
        IMAP_PORT           = "993"
        IMAP_USER           = "spam@viktorbarzin.me"
        IMAP_FOLDER         = "INBOX"
        IMAP_USE_SSL        = "true"
        IMAP_SEARCH         = "TO \"plans@viktorbarzin.me\""
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
      schedule = "0 8 * * *"
      timezone = "Europe/London"
      command  = ["python", "-m", "tripit_api", "run-transport-nudge"]
      suspend  = false
      extra_env = {
        NUDGES_ENABLED    = "true"
        SLACK_PROVIDER    = "slack"
        LOCATION_PROVIDER = "dawarich"
        DAWARICH_BASE_URL = "https://dawarich.viktorbarzin.me"
      }
    }
    weather-brief = {
      schedule = "0 21 * * *"
      timezone = "Europe/London"
      command  = ["python", "-m", "tripit_api", "run-weather-brief"]
      suspend  = false
      extra_env = {
        NUDGES_ENABLED    = "true"
        SLACK_PROVIDER    = "slack"
        LOCATION_PROVIDER = "dawarich"
        DAWARICH_BASE_URL = "https://dawarich.viktorbarzin.me"
      }
    }
    # Tour-guide overnight audio fill (tripit#30, ADR-0011): synthesizes the
    # narration audio queue against Chatterbox, which the tts stack scales up
    # 02:00–06:00 Europe/London behind a free-VRAM preflight. 02:20 gives the
    # scale-up + first model load headroom; the 04:30 pass re-runs the same
    # idempotent worker as insurance (skipped window / mid-window guard yield /
    # slow FP16 synthesis). Outside the window the worker records a
    # `tts_unreachable` run and exits quietly — that is the normal daytime state.
    fill-tour-audio = {
      schedule  = "20 2 * * *"
      timezone  = "Europe/London"
      command   = ["python", "-m", "tripit_api", "fill-tour-audio"]
      suspend   = false
      extra_env = {}
    }
    fill-tour-audio-retry = {
      schedule  = "30 4 * * *"
      timezone  = "Europe/London"
      command   = ["python", "-m", "tripit_api", "fill-tour-audio"]
      suspend   = false
      extra_env = {}
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
            image_pull_secrets {
              name = "ghcr-credentials"
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
  # The Photos tab proxies Immich thumbnails through /api — a trip-gallery
  # scroll is hundreds of parallel image GETs, far past the default 10/50
  # limiter. Dedicated 100/1000 middleware (stacks/traefik middleware.tf);
  # the calendar/email carve-out ingresses below stay on the default.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-tripit-rate-limit@kubernetescrd"]
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

# Planner Slack webhook carve-out: POST /api/planner/slack/{events,interactions,commands}
# is gated by Slack v0 HMAC signature verification (SLACK_SIGNING_SECRET) in-app, not
# Authentik — Slack posts events server-to-server and can't do the forward-auth dance.
module "ingress_planner_slack" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": Slack Events/Interactivity webhooks are gated by Slack v0
  # signature verification in-app (SLACK_SIGNING_SECRET), not Authentik.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.tripit.metadata[0].name
  name             = "tripit-planner-slack"
  service_name     = "tripit"
  full_host        = "tripit.viktorbarzin.me"
  ingress_path     = ["/api/planner/slack"]
  port             = 8080
  tls_secret_name  = var.tls_secret_name
}

# Bearer-only API host for the native Shell (tripit ADR-0017, viktor/tripit#49):
# the Shell's WebView can't do the forward-auth cookie dance, and CORS
# preflights would die at the outpost, so this host carries no Authentik
# middleware at all.
module "ingress_api" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": requests are gated by the backend itself — it validates
  # OIDC bearer JWTs from the tripit-app Authentik provider (AUTH_MODE=hybrid,
  # tripit slice 2; 401 for everything else). strip-auth-headers deletes
  # inbound X-authentik-* so the hybrid fallback header can never be spoofed
  # through this host.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.tripit.metadata[0].name
  name             = "tripit-api"
  service_name     = "tripit"
  port             = 8080
  tls_secret_name  = var.tls_secret_name
  # Same photo-grid burst profile as the main tripit host (the Android Shell's
  # gallery fetches thumbnails through this host) — share the dedicated
  # 100/1000 tripit-rate-limit instead of the default 10/50.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-strip-auth-headers@kubernetescrd",
    "traefik-tripit-rate-limit@kubernetescrd",
  ]
}
