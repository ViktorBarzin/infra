variable "image_tag" {
  type        = string
  default     = "latest"
  description = "nextcloud-todos image tag. Use 8-char git SHA in CI."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "nextcloud-todos"
  # ADR-0002 (infra#18): built on GHA from the public GitHub mirror, pushed to
  # ghcr (public package — anonymous pulls). Running tag is managed by the
  # Woodpecker deploy (kubectl set image); both image refs below are
  # ignore_changes'd, so this base only matters on (re)create.
  image = "ghcr.io/viktorbarzin/nextcloud-todos:${var.image_tag}"
  labels = {
    app = "nextcloud-todos"
  }
}

resource "kubernetes_namespace" "nextcloud_todos" {
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
#   secret/nextcloud-todos
#     webhook_bearer_token          — bearer for Nextcloud -> /nextcloud/hook and
#                                      the OpenClaw nextcloud-todos-api plugin
#     hmac_secret                   — signs the /cb approval links (sig + exp)
#     caldav_app_password           — Nextcloud `admin` app-password for CalDAV
#                                      (PROPFIND list resolution + note append)
#     nextcloud_admin_app_password  — admin app-password used by the
#                                      webhook-register null_resource below (may
#                                      reuse the CalDAV one)
#     claude_agent_token            — Bearer for claude-agent-service (Tier-2)
#     telegram_bot_token            — consumed by the OpenClaw plugin (see
#                                      stacks/openclaw), NOT by this service
#     viktor_chat_id                — consumed by the OpenClaw plugin
#
# Schema in CNPG: `nextcloud_todos` (alembic creates tables on first migrate).
# DB user: created in dbaas (null_resource.pg_nextcloud_todos_db); password
# managed via the Vault database engine — see static-creds/pg-nextcloud-todos.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-todos-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "nextcloud-todos-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "WEBHOOK_BEARER_TOKEN", remoteRef = { key = "nextcloud-todos", property = "webhook_bearer_token" } },
        { secretKey = "HMAC_SECRET", remoteRef = { key = "nextcloud-todos", property = "hmac_secret" } },
        { secretKey = "CALDAV_APP_PASSWORD", remoteRef = { key = "nextcloud-todos", property = "caldav_app_password" } },
        { secretKey = "CLAUDE_AGENT_TOKEN", remoteRef = { key = "nextcloud-todos", property = "claude_agent_token" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.nextcloud_todos]
}

# DB credentials from Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI app as DB_CONNECTION_STRING.
# Pre-req in dbaas: CNPG cluster has DB `nextcloud_todos`, role
# `nextcloud_todos`, and Vault role `static-creds/pg-nextcloud-todos`.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "nextcloud-todos-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "nextcloud-todos-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://nextcloud_todos:{{ .password }}@${var.postgresql_host}:5432/nextcloud_todos"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-nextcloud-todos"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.nextcloud_todos]
}

resource "kubernetes_deployment" "nextcloud_todos" {
  metadata {
    name      = "nextcloud-todos"
    namespace = kubernetes_namespace.nextcloud_todos.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    # CalDAV sweep + single webhook leader; concurrency hurts both.
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
          command = ["python", "-m", "nextcloud_todos", "migrate"]

          env_from {
            secret_ref { name = "nextcloud-todos-secrets" }
          }
          env_from {
            secret_ref { name = "nextcloud-todos-db-creds" }
          }

          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name  = "nextcloud-todos"
          image = local.image

          port {
            container_port = 8080
          }

          env_from {
            secret_ref { name = "nextcloud-todos-secrets" }
          }
          env_from {
            secret_ref { name = "nextcloud-todos-db-creds" }
          }

          # Nextcloud / CalDAV
          env {
            name  = "NEXTCLOUD_BASE_URL"
            value = "https://nextcloud.viktorbarzin.me"
          }
          env {
            name  = "NEXTCLOUD_USER"
            value = "admin"
          }
          env {
            name  = "LIST_ALLOWLIST"
            value = "Personal"
          }
          # Noticing lists: skipped by the classifier, routed to the ideation
          # runner (ideas appended onto the todo; learn/romance course).
          env {
            name  = "IDEATION_ALLOWLIST"
            value = "Noticing File"
          }
          # Tier-0 LLM classifier
          env {
            name  = "LLAMA_SWAP_URL"
            value = "http://llama-swap.llama-cpp.svc.cluster.local:8080"
          }
          env {
            name  = "LLAMA_SWAP_MODEL"
            value = "qwen3-8b"
          }
          # Tier-2 LLM (claude-agent-service: research auto-run + two-pass exec)
          env {
            name  = "CLAUDE_AGENT_URL"
            value = "http://claude-agent-service.claude-agent.svc.cluster.local:8080"
          }
          # Public callback base URL for the Telegram inline-keyboard URL
          # buttons. Must match the ingress host below (proxied via Cloudflare).
          env {
            name  = "CALLBACK_BASE_URL"
            value = "https://nextcloud-todos.viktorbarzin.me"
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

resource "kubernetes_service" "nextcloud_todos" {
  metadata {
    name      = "nextcloud-todos"
    namespace = kubernetes_namespace.nextcloud_todos.metadata[0].name
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
# buttons. /nextcloud/hook, /api/* and /healthz stay internal — they're
# reached via cluster DNS by Nextcloud's webhook, the OpenClaw plugin, and
# kubelet probes respectively.
#
# auth = "none": the /cb endpoints are gated by HMAC-signed query params
# (sig + exp) generated from HMAC_SECRET. Authentik would force a login flow
# before the GET could fire and break the one-tap approval flow.
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": HMAC + expiry gate the /cb endpoints — Authentik would
  # force a login dance and break Telegram's one-tap UX. See hmac_links.py.
  auth             = "none"
  anti_ai_scraping = false
  dns_type         = "proxied"
  external_monitor = false
  namespace        = kubernetes_namespace.nextcloud_todos.metadata[0].name
  name             = "nextcloud-todos"
  port             = 8080
  ingress_path     = ["/cb"]
  tls_secret_name  = var.tls_secret_name
}

# =============================================================================
# Nextcloud webhook registration (Task 4.5)
# =============================================================================
# Registers the two Calendar VTODO events (create + update) against the
# Nextcloud `webhook_listeners` OCS API so Nextcloud POSTs to this service
# whenever a task on the Personal list changes. Points at the INTERNAL svc
# URL (Nextcloud calls it from inside the cluster). Idempotent: GETs the
# existing webhooks first and skips registration of any event already
# targeting the svc URL (the OCS API has no upsert — a blind re-POST creates
# duplicates). Re-runs whenever the bearer token or hook URL changes.
#
# Auth: admin app-password (Nextcloud admin) for the OCS call itself; the
# registered webhook then carries `Authorization: Bearer <webhook token>`
# (authMethod=header) so Nextcloud authenticates to THIS service on delivery.
# Both values come from Vault — read here as a plan-time data source (this is
# the one place the stack needs a raw Vault value: a local-exec provisioner
# can't consume an ESO-created K8s Secret).
data "vault_kv_secret_v2" "nextcloud_todos" {
  mount = "secret"
  name  = "nextcloud-todos"
}

resource "null_resource" "register_webhooks" {
  depends_on = [module.ingress]

  triggers = {
    hook_url     = "http://nextcloud-todos.nextcloud-todos.svc.cluster.local:8080/nextcloud/hook"
    bearer_token = sha256(data.vault_kv_secret_v2.nextcloud_todos.data["webhook_bearer_token"])
  }

  provisioner "local-exec" {
    environment = {
      NC_ADMIN_APP_PW      = data.vault_kv_secret_v2.nextcloud_todos.data["nextcloud_admin_app_password"]
      WEBHOOK_BEARER_TOKEN = data.vault_kv_secret_v2.nextcloud_todos.data["webhook_bearer_token"]
    }
    command = <<-EOT
      set -eu
      NC="https://nextcloud.viktorbarzin.me/ocs/v2.php/apps/webhook_listeners/api/v1/webhooks"
      HOOK_URL="http://nextcloud-todos.nextcloud-todos.svc.cluster.local:8080/nextcloud/hook"

      # Idempotency: list existing webhooks and skip any event already
      # pointing at our svc URL. The OCS API has no upsert; re-POSTing the
      # same listener silently creates a duplicate, so we gate on a match.
      EXISTING=$(curl -fsS -H "OCS-APIRequest: true" -H "Accept: application/json" \
        -u "admin:$${NC_ADMIN_APP_PW}" "$${NC}")

      # ONLY the Created event — the agent is purely reactive to newly-created
      # todos. Registering Updated re-fired the pipeline on every edit (incl.
      # the agent's own note-append) and re-processed completed/edited todos.
      for EV in CalendarObjectCreatedEvent; do
        # The event class is a PHP namespace: OCP\Calendar\Events\<EV>. In the
        # JSON body each backslash must be doubled (valid JSON escape), so the
        # shell var holds "\\" per separator -> the heredoc source needs four
        # backslashes per separator (TF heredoc passes them through literally,
        # bash double-quotes then halve them to "\\").
        FULL_EVENT="OCP\\\\Calendar\\\\Events\\\\$${EV}"
        # Match on both the uri and the event short-name within the JSON blob
        # — grep with fixed strings to avoid regex pitfalls.
        if echo "$${EXISTING}" | grep -F "$${HOOK_URL}" | grep -qF "$${EV}"; then
          echo "webhook for $${EV} already registered -> skipping"
          continue
        fi
        echo "registering webhook for $${EV} ..."
        curl -fsS -X POST -H "OCS-APIRequest: true" -H "Content-Type: application/json" \
          -u "admin:$${NC_ADMIN_APP_PW}" "$${NC}" \
          -d "{\"httpMethod\":\"POST\",
               \"uri\":\"$${HOOK_URL}\",
               \"event\":\"$${FULL_EVENT}\",
               \"authMethod\":\"header\",
               \"authData\":{\"Authorization\":\"Bearer $${WEBHOOK_BEARER_TOKEN}\"}}"
        echo
      done
      echo "webhook registration complete"
    EOT
  }
}
