variable "image_tag" {
  type        = string
  default     = "482bd42e"
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "tasks"
  # ADR-0002: built by GitHub Actions in the tasks repo and pushed to a public
  # ghcr package, so pulls are anonymous. The Woodpecker deploy sets the
  # running tag on both containers; both image refs are ignore_changes'd
  # (CI_SETS_IMAGE), so this base only matters on (re)create.
  image = "ghcr.io/viktorbarzin/tasks:${var.image_tag}"
  labels = {
    app = "tasks"
  }
}

# The app signs people in itself, through the `tasks` OAuth2 application in
# authentik.tf. It never reads X-authentik-* headers in production, and the
# ingress strips them anyway.

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

resource "kubernetes_deployment" "tasks" {
  metadata {
    name      = "tasks"
    namespace = kubernetes_namespace.tasks.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      # Restart on a change to any Secret read through env. tasks-db-creds is
      # left out on purpose: the app reads the password file on every new
      # connection, so the 7-day rotation needs no restart.
      "secret.reloader.stakater.com/reload" = join(",", [
        "tasks-secrets",
        "tasks-auth",
        kubernetes_secret.authentik_approver.metadata[0].name,
        kubernetes_secret.authentik_reader.metadata[0].name,
      ])
    }
  }

  spec {
    # One pod: the realtime LISTEN connection and the CalDAV sync want one
    # writer.
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
        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
        }

        # Drizzle migrations from the same image. Idempotent and serialised by
        # a pg_advisory_lock, so it is safe on every pod start; an init
        # container keeps the migration tied to the image that needs it,
        # where a Job would need re-creating for every image change.
        init_container {
          name  = "migrate"
          image = local.image
          args  = ["entrypoints/migrate.js"]

          env {
            name  = "DATABASE_URL"
            value = "postgres://tasks@${var.postgresql_host}:5432/tasks"
          }
          env {
            name  = "DATABASE_PASSWORD_FILE"
            value = "/secrets/db/password"
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/secrets/db"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        container {
          name  = "tasks"
          image = local.image

          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "metrics"
            container_port = 9090
          }

          # TASKS_FERNET_KEY: encrypts the Nextcloud app passwords stored in
          # Connected Accounts.
          env_from {
            secret_ref { name = "tasks-secrets" }
          }
          # BETTER_AUTH_SECRET, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET.
          env_from {
            secret_ref { name = "tasks-auth" }
          }
          # AUTHENTIK_APPROVER_TOKEN, AUTHENTIK_USERS_GROUP_ID.
          env_from {
            secret_ref { name = kubernetes_secret.authentik_approver.metadata[0].name }
          }
          # AUTHENTIK_READER_TOKEN.
          env_from {
            secret_ref { name = kubernetes_secret.authentik_reader.metadata[0].name }
          }

          # No password in the URL: the app reads DATABASE_PASSWORD_FILE each
          # time a connection opens, so a Vault rotation does not break new
          # connections.
          env {
            name  = "DATABASE_URL"
            value = "postgres://tasks@${var.postgresql_host}:5432/tasks"
          }
          env {
            name  = "DATABASE_PASSWORD_FILE"
            value = "/secrets/db/password"
          }
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          # Comma-separated. The first entry is Better Auth's baseURL and the
          # OAuth redirect host. Every entry is a trusted origin for CSRF.
          env {
            name  = "PUBLIC_ORIGINS"
            value = "https://tasks.viktorbarzin.me"
          }
          env {
            name  = "OIDC_DISCOVERY_URL"
            value = "https://authentik.viktorbarzin.me/application/o/${authentik_application.tasks.slug}/.well-known/openid-configuration"
          }
          env {
            name  = "AUTHENTIK_API_URL"
            value = "https://authentik.viktorbarzin.me"
          }
          env {
            name  = "TASKS_CALDAV_BASE_URL"
            value = "https://nextcloud.viktorbarzin.me/remote.php/dav"
          }
          env {
            name  = "TASKS_LOCAL_TZ"
            value = "Europe/Sofia"
          }
          # DEV_USER must never be set here. The app ignores it under
          # NODE_ENV=production, and it has no place in a production pod.

          volume_mount {
            name       = "db-password"
            mount_path = "/secrets/db"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 3000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 3000
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          # Measured at about 50 MiB idle.
          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        # Mounted as a directory (no subPath) so the kubelet refreshes the
        # file when ESO writes a rotated password.
        volume {
          name = "db-password"
          secret {
            secret_name  = "tasks-db-creds"
            default_mode = "0440"
            items {
              key  = "DB_PASSWORD"
              path = "password"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].spec[0].init_container[0].image,                                     # CI_SETS_IMAGE: the migrate init container moves with the app image
    ]
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
    kubernetes_manifest.auth_external_secret,
  ]
}

resource "kubernetes_service" "tasks" {
  metadata {
    name      = "tasks"
    namespace = kubernetes_namespace.tasks.metadata[0].name
    labels    = local.labels
    annotations = {
      # /metrics is served only on the metrics port, which the ingress never
      # routes.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = 3000
      target_port = 3000
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
    }
  }
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
  service_name    = kubernetes_service.tasks.metadata[0].name
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

# User traffic only from Traefik, /metrics only from Prometheus.
resource "kubernetes_network_policy_v1" "tasks_ingress" {
  metadata {
    name      = "tasks-ingress"
    namespace = kubernetes_namespace.tasks.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = "9090"
        protocol = "TCP"
      }
    }
  }
}
