variable "image_tag" {
  type        = string
  default     = "latest"
  description = "recruiter-responder image tag. Use 8-char git SHA in CI."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "recruiter-responder"
  # GHA builds + pushes ghcr.io/viktorbarzin/recruiter-responder (PRIVATE,
  # ADR-0002 off-infra builds, infra#27). Canonical repo stays on Forgejo;
  # the GitHub mirror runs the build and the Woodpecker deploy moves the tag.
  image = "ghcr.io/viktorbarzin/recruiter-responder:${var.image_tag}"
  labels = {
    app = "recruiter-responder"
  }
}

resource "kubernetes_namespace" "recruiter_responder" {
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
#   secret/recruiter-responder
#     webhook_bearer_token   — bearer for all /api/* endpoints (consumed by
#                              the OpenClaw recruiter-api plugin)
#     imap_me_user           — IMAP for me@viktorbarzin.me (full address)
#     imap_me_pass           — IMAP password for me@
#     imap_spam_user         — IMAP for spam@viktorbarzin.me
#     imap_spam_pass         — IMAP password for spam@
#     smtp_password          — SMTP password for me@viktorbarzin.me
#     claude_agent_token     — Bearer for claude-agent-service (Tier-2)
#     telegram_bot_token     — Bot token for @ViktorBarzinOpenClawBot
#                              (same as secret/openclaw.telegram_bot_token)
#     telegram_chat_id       — Viktor's Telegram chat id (8281953845)
#
# Schema in CNPG: `recruiter_responder` (alembic creates on first migrate).
# DB user: created via Vault database engine — see static-creds/pg-recruiter-responder.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "recruiter-responder-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "recruiter-responder-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "WEBHOOK_BEARER_TOKEN", remoteRef = { key = "recruiter-responder", property = "webhook_bearer_token" } },
        { secretKey = "IMAP_ME_USER", remoteRef = { key = "recruiter-responder", property = "imap_me_user" } },
        { secretKey = "IMAP_ME_PASS", remoteRef = { key = "recruiter-responder", property = "imap_me_pass" } },
        { secretKey = "IMAP_SPAM_USER", remoteRef = { key = "recruiter-responder", property = "imap_spam_user" } },
        { secretKey = "IMAP_SPAM_PASS", remoteRef = { key = "recruiter-responder", property = "imap_spam_pass" } },
        { secretKey = "SMTP_PASSWORD", remoteRef = { key = "recruiter-responder", property = "smtp_password" } },
        { secretKey = "CLAUDE_AGENT_TOKEN", remoteRef = { key = "recruiter-responder", property = "claude_agent_token" } },
        { secretKey = "TELEGRAM_BOT_TOKEN", remoteRef = { key = "recruiter-responder", property = "telegram_bot_token" } },
        { secretKey = "TELEGRAM_CHAT_ID", remoteRef = { key = "recruiter-responder", property = "telegram_chat_id" } },
        # Gmail app password for the backtest CLI (read-only). Same
        # credential as wealthfolio uses for broker statement ingestion.
        { secretKey = "GMAIL_IMAP_USER", remoteRef = { key = "recruiter-responder", property = "gmail_imap_user" } },
        { secretKey = "GMAIL_IMAP_PASS", remoteRef = { key = "recruiter-responder", property = "gmail_imap_pass" } },
        # gpt-5.4-mini (NIM-served qwen3-coder-480b) for /api/draft generation.
        { secretKey = "GPT_MINI_ENDPOINT", remoteRef = { key = "recruiter-responder", property = "gpt_mini_endpoint" } },
        { secretKey = "GPT_MINI_API_KEY", remoteRef = { key = "recruiter-responder", property = "gpt_mini_api_key" } },
        { secretKey = "GPT_MINI_MODEL", remoteRef = { key = "recruiter-responder", property = "gpt_mini_model" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.recruiter_responder]
}

# DB credentials from Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
# Pre-req in dbaas: CNPG cluster has DB `recruiter_responder`, role
# `recruiter_responder`, and Vault role `static-creds/pg-recruiter-responder`.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "recruiter-responder-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "recruiter-responder-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://recruiter_responder:{{ .password }}@${var.postgresql_host}:5432/recruiter_responder"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-recruiter-responder"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.recruiter_responder]
}

resource "kubernetes_deployment" "recruiter_responder" {
  metadata {
    name      = "recruiter-responder"
    namespace = kubernetes_namespace.recruiter_responder.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    # IMAP IDLE + APScheduler want a single leader; concurrency hurts both.
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
        # GHCR pull secret: the ghcr-credentials Secret in this namespace is
        # cloned in by the kyverno stack's sync-ghcr-credentials ClusterPolicy
        # (allowlisted namespace) — the ghcr package is PRIVATE (ADR-0002).
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        init_container {
          name    = "alembic-migrate"
          image   = local.image
          command = ["alembic", "upgrade", "head"]

          env_from {
            secret_ref { name = "recruiter-responder-secrets" }
          }
          env_from {
            secret_ref { name = "recruiter-responder-db-creds" }
          }

          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name  = "recruiter-responder"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref { name = "recruiter-responder-secrets" }
          }
          env_from {
            secret_ref { name = "recruiter-responder-db-creds" }
          }

          # IMAP fan-in: read both mailboxes off the in-cluster mailserver.
          env {
            name  = "IMAP_MAILBOXES"
            value = "me,spam"
          }
          env {
            name  = "IMAP_ME_HOST"
            value = "mailserver.mailserver.svc.cluster.local"
          }
          env {
            name  = "IMAP_SPAM_HOST"
            value = "mailserver.mailserver.svc.cluster.local"
          }
          # SMTP (outbound reply) — same mailserver service, STARTTLS on 587.
          env {
            name  = "SMTP_HOST"
            value = "mailserver.mailserver.svc.cluster.local"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_USER"
            value = "me@viktorbarzin.me"
          }
          env {
            name  = "SMTP_FROM_ADDR"
            value = "me@viktorbarzin.me"
          }
          env {
            name  = "SMTP_FROM_NAME"
            value = "Viktor Barzin"
          }
          # Tier-0 LLM
          env {
            name  = "LLAMA_SWAP_URL"
            value = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
          }
          env {
            name  = "LLAMA_SWAP_MODEL"
            value = "qwen3-8b"
          }
          # Tier-2 LLM (deep_research only)
          env {
            name  = "CLAUDE_AGENT_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
          }
          # Telegram bot (no URL env needed — token in secret)
          # Public callback base URL for inline-keyboard URL buttons.
          # Must match the ingress host below (proxied via Cloudflare).
          env {
            name  = "CALLBACK_BASE_URL"
            value = "https://recruiter-responder.viktorbarzin.me"
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
            requests = { cpu = "100m", memory = "192Mi" }
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

resource "kubernetes_service" "recruiter_responder" {
  metadata {
    name      = "recruiter-responder"
    namespace = kubernetes_namespace.recruiter_responder.metadata[0].name
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

# Public ingress for the /cb/* callback endpoints driven by Telegram URL
# buttons. /api/* and /healthz stay internal — they're routed via cluster
# DNS from the OpenClaw plugin / kubelet probes respectively.
#
# auth = "none": the /cb endpoints are gated by HMAC-signed query params
# (sig + exp) generated from WEBHOOK_BEARER_TOKEN. Authentik would force
# a login flow before the GET could fire and break the one-tap flow.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": HMAC + expiry gate the /cb endpoints — Authentik would
  # force a login dance and break Telegram's one-tap UX. See callback_links.py.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "proxied"
  namespace        = kubernetes_namespace.recruiter_responder.metadata[0].name
  name             = "recruiter-responder"
  port             = 8080
  ingress_path     = ["/cb"]
  tls_secret_name  = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/icon" = "mdi-email-fast"
  }
}
