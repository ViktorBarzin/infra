# tasks-next: the TypeScript build of tasks. Since the ADR-0001 cutover
# (~/code/docs/adr/0001-default-app-stack.md) it serves tasks.viktorbarzin.me
# through module.ingress in main.tf, and still answers at
# tasks-next.viktorbarzin.me. The FastAPI Deployment in main.tf keeps running,
# without a route, as the rollback target.
#
# Both builds share the `tasks` database. The TypeScript build's migrations
# are additive (new tables only, app/drizzle/0001_auth_identity.sql), so the
# Python image keeps running `alembic upgrade head` against the same schema.
#
# Identity: the app signs people in itself, through the `tasks` OAuth2
# application in authentik.tf. It never reads X-authentik-* headers in
# production, and the ingress strips them anyway.

variable "next_image_tag" {
  type        = string
  default     = "fe33cf63"
  description = "tasks-ts image tag for tasks-next on (re)create. The running tag is set by the Woodpecker deploy (kubectl set image) after build-ts.yml."
}

locals {
  # Built by GitHub Actions (build-ts.yml in the tasks repo) and pushed to the
  # public ghcr package tasks-ts, so pulls are anonymous. The Woodpecker
  # deploy sets the running tag on both containers; both image refs are
  # ignore_changes'd (CI_SETS_IMAGE), so this base only matters on (re)create.
  next_image = "ghcr.io/viktorbarzin/tasks-ts:${var.next_image_tag}"
  # Must differ from local.labels: the live Deployment's selector and the
  # tasks-ingress NetworkPolicy match app=tasks.
  next_labels = {
    app = "tasks-next"
  }
  next_host = "tasks-next.viktorbarzin.me"
}

# Membership re-checks (every 15 minutes per signed-in user) read the user and
# their groups with this token: GET /api/v3/core/users/?username=..&include_groups=true.
# Without it every re-check fails closed. view_user has to be global because
# any Authentik user may try to sign in; view_group is held only on Tasks Users,
# the one group the app looks up by name. Same shape as stacks/f1-stream/members.tf.
resource "authentik_rbac_role" "membership_reader" {
  name = "tasks membership reader"
}

resource "authentik_rbac_permission_role" "reader_view_user" {
  role       = authentik_rbac_role.membership_reader.id
  permission = "authentik_core.view_user"
}

resource "authentik_rbac_permission_role" "reader_view_users_group" {
  role       = authentik_rbac_role.membership_reader.id
  permission = "authentik_core.view_group"
  model      = "authentik_core.group"
  object_id  = module.signup.group_id
}

resource "authentik_group" "membership_readers" {
  name  = "tasks membership readers"
  roles = [authentik_rbac_role.membership_reader.id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "membership_reader" {
  username = "svc-tasks-reader"
  name     = "tasks (membership check)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.membership_readers.id]

  attributes = jsonencode({
    managed_by = "infra/stacks/tasks/tasks-next.tf"
    purpose    = "tasks re-checks that a signed-in user is still in Tasks Users or Tasks Admins"
  })
}

resource "authentik_token" "membership_reader" {
  identifier   = "svc-tasks-reader"
  user         = authentik_user.membership_reader.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like the approver token: a token that lapses on a date
  # nobody watches turns every re-check into a sign-out. Rotate by tainting
  # this resource.
  expiring    = false
  description = "tasks membership re-check. Rotate by tainting this resource."
}

resource "kubernetes_secret" "authentik_reader" {
  metadata {
    name      = "tasks-authentik-reader"
    namespace = kubernetes_namespace.tasks.metadata[0].name
  }
  data = {
    AUTHENTIK_READER_TOKEN = authentik_token.membership_reader.key
  }
}

resource "kubernetes_deployment" "tasks_next" {
  metadata {
    name      = "tasks-next"
    namespace = kubernetes_namespace.tasks.metadata[0].name
    labels = merge(local.next_labels, {
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
    # writer, as in the Python build.
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.next_labels
    }

    template {
      metadata {
        labels = local.next_labels
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
        # where a Job would need re-creating for every image change. On the
        # Alembic-managed database it records the baseline as applied, then
        # creates the auth tables (additive only).
        init_container {
          name  = "migrate"
          image = local.next_image
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
          name  = "tasks-next"
          image = local.next_image

          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "metrics"
            container_port = 9090
          }

          # TASKS_FERNET_KEY (same key as the Python build, so both read the
          # same Connected Accounts).
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
          # OAuth redirect host, so sign-in started on tasks-next also returns
          # to the main host. Every entry is a trusted origin for CSRF.
          env {
            name  = "PUBLIC_ORIGINS"
            value = "https://tasks.viktorbarzin.me,https://${local.next_host}"
          }
          env {
            name  = "OIDC_DISCOVERY_URL"
            value = "https://authentik.viktorbarzin.me/application/o/${authentik_application.tasks.slug}/.well-known/openid-configuration"
          }
          env {
            name  = "AUTHENTIK_API_URL"
            value = "https://authentik.viktorbarzin.me"
          }
          # Same values as the Python build (its default DAV root and the
          # TASKS_LOCAL_TZ in main.tf).
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

resource "kubernetes_service" "tasks_next" {
  metadata {
    name      = "tasks-next"
    namespace = kubernetes_namespace.tasks.metadata[0].name
    labels    = local.next_labels
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
    selector = local.next_labels

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

module "ingress_next" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": the app runs its own OIDC sign-in against the `tasks`
  # Authentik application (Tasks Users, Tasks Admins, Home Server Admins);
  # /api answers 401 without a session or bearer token. Forward-auth would
  # break the bearer-token API and the OAuth callback.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.tasks.metadata[0].name
  name            = "tasks-next"
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
  # Second host for the same build; the tile is on module.ingress.
  homepage_enabled = false
}

# Same shape as tasks-ingress (main.tf): user traffic only from Traefik,
# /metrics only from Prometheus.
resource "kubernetes_network_policy_v1" "tasks_next_ingress" {
  metadata {
    name      = "tasks-next-ingress"
    namespace = kubernetes_namespace.tasks.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.next_labels
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
