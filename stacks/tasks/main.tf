variable "image_tag" {
  type        = string
  default     = "latest"
  description = "tasks image tag. Running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "tasks"
  # ADR-0002: built on GHA from the public GitHub mirror, pushed to ghcr
  # (public package — anonymous pulls). Running tag is managed by the
  # Woodpecker deploy (kubectl set image); the image ref below is
  # ignore_changes'd (CI_SETS_IMAGE), so this base only matters on
  # (re)create.
  image = "ghcr.io/viktorbarzin/tasks:${var.image_tag}"
  labels = {
    app = "tasks"
  }
}

resource "kubernetes_namespace" "tasks" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets — seed these in Vault before applying:
#   secret/tasks
#     fernet_key — Fernet key encrypting the per-user Nextcloud app passwords
#                  stored in the Connected Accounts table (tasks ADR-0002).
#     better_auth_secret, oidc_client_id, oidc_client_secret — used by the
#                  TypeScript build and the OAuth2 provider (authentik.tf).
#
# DB: CNPG database `tasks` (created in dbaas, null_resource.pg_tasks_db);
# role password managed via the Vault database engine — see
# static-creds/pg-tasks. The Deployment's `migrate` init container runs the
# Drizzle migrations.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tasks-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tasks-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "TASKS_FERNET_KEY", remoteRef = { key = "tasks", property = "fernet_key" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.tasks]
}

# DB credentials from Vault database engine (7-day rotation). The app reads
# DB_PASSWORD from a mounted file on every new connection.
# Pre-req in dbaas: CNPG cluster has DB `tasks`, role `tasks`, and Vault
# role `static-creds/pg-tasks`.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tasks-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tasks-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-tasks"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.tasks]
}

# Kyverno ClusterPolicy `sync-tls-secret` auto-clones the wildcard TLS
# secret into every namespace, so we don't need a setup_tls_secret module.

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": the app runs its own OIDC sign-in against the `tasks`
  # Authentik application (Tasks Users, Tasks Admins, Home Server Admins) and
  # answers /api with 401 without a session or bearer token. Forward-auth
  # would break the bearer-token API and the OAuth callback.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.tasks.metadata[0].name
  name            = "tasks"
  service_name    = kubernetes_service.tasks_next.metadata[0].name
  port            = 3000
  tls_secret_name = var.tls_secret_name
  # Keeps the default rate-limit middleware: it runs the real-ip plugin, and
  # Better Auth's rate limiter keys on the X-Real-Ip that sets.
  # The default csp-headers middleware lets any *.viktorbarzin.me page frame
  # the app; this one forbids framing.
  custom_content_security_policy = "frame-ancestors 'none'"
  # No public route may carry a client-sent X-authentik-* identity.
  extra_middlewares = ["traefik-strip-auth-headers@kubernetescrd"]
  # An installable PWA whose service worker, SSE stream and bearer-token API
  # make most requests. Every page past the sign-in wall needs a session, so
  # there is nothing for a crawler to mine, and the bot-block forwardAuth
  # would sit on every API call.
  anti_ai_scraping = false
  # Same reasoning, plus the installed PWA runs in a standalone webview and
  # the Turnstile pass is tied to the network that solved it, so a phone
  # changing networks would meet the challenge page mid-session.
  turnstile = false
  extra_annotations = {
    "gethomepage.dev/description" = "Reminders-style task PWA over Nextcloud CalDAV"
    "gethomepage.dev/icon"        = "mdi-format-list-checks"
  }
}

