# One first-party TanStack Start app on the ADR-0001 stack (~/code/docs/adr/
# 0001-default-app-stack.md): namespace, Deployment with a `migrate` init
# container, Service, ingress (auth = "app"), NetworkPolicy. The secrets are in
# secrets.tf and the Authentik application in authentik.tf. README.md has the
# env contract and the per-app checklist.
#
# The app signs people in itself, through the OAuth2 application in
# authentik.tf. It never reads X-authentik-* headers in production, and the
# ingress strips them anyway.

locals {
  namespace     = coalesce(var.namespace, var.name)
  host          = coalesce(var.host, "${var.name}.${var.root_domain}")
  vault_kv_name = coalesce(var.vault_kv_name, var.name)
  request_mode  = var.signup_mode == "request"

  db_name    = coalesce(var.database.name, replace(var.name, "-", "_"))
  db_user    = coalesce(var.database.user, local.db_name)
  vault_role = coalesce(var.database.vault_role, "pg-${var.name}")
  # No password in the URL: the app reads DATABASE_PASSWORD_FILE each time a
  # connection opens, so a Vault rotation does not break new connections.
  database_url = "postgres://${local.db_user}@${var.postgresql_host}:5432/${local.db_name}"

  # The first entry is Better Auth's baseURL and the OAuth redirect host.
  # Every entry is a trusted origin for CSRF.
  public_origins = concat(["https://${local.host}"], var.extra_public_origins)

  users_group  = coalesce(var.users_group, "${var.display_name} Users")
  admins_group = coalesce(var.admins_group, "${var.display_name} Admins")

  image  = "${var.image}:${var.image_tag}"
  labels = { app = var.name }

  app_secrets_name  = "${var.name}-secrets"
  auth_secrets_name = "${var.name}-auth"
  db_secret_name    = "${var.name}-db-creds"

  # Secrets read through env_from, in this order.
  env_from_secrets = concat(
    length(var.app_secret_env) > 0 ? [local.app_secrets_name] : [],
    [local.auth_secrets_name],
    local.request_mode ? [kubernetes_secret.authentik_approver[0].metadata[0].name] : [],
    [kubernetes_secret.authentik_reader.metadata[0].name],
  )

  group_env = var.emit_group_env ? concat(
    [
      { name = "AUTH_USERS_GROUP", value = local.users_group },
      { name = "AUTH_ADMINS_GROUP", value = local.admins_group },
    ],
    var.agents_group != null ? [{ name = "AUTH_AGENTS_GROUP", value = var.agents_group }] : [],
  ) : []

  # Emitted only when they differ from the image defaults (PORT=3000,
  # METRICS_PORT=9090, signup "request"), so an app on the defaults renders
  # exactly as tasks always has.
  setting_env = concat(
    var.http_port != 3000 ? [{ name = "PORT", value = tostring(var.http_port) }] : [],
    var.metrics_port != 9090 ? [{ name = "METRICS_PORT", value = tostring(var.metrics_port) }] : [],
    local.request_mode ? [] : [{ name = "SIGNUP_MODE", value = var.signup_mode }],
  )

  container_env = concat(
    [
      { name = "DATABASE_URL", value = local.database_url },
      { name = "DATABASE_PASSWORD_FILE", value = "/secrets/db/password" },
      { name = "NODE_ENV", value = "production" },
      { name = "PUBLIC_ORIGINS", value = join(",", local.public_origins) },
      { name = "OIDC_DISCOVERY_URL", value = "${var.authentik_url}/application/o/${authentik_application.this.slug}/.well-known/openid-configuration" },
      { name = "AUTHENTIK_API_URL", value = var.authentik_url },
    ],
    local.setting_env,
    local.group_env,
    var.extra_env,
  )
  # DEV_USER must never be set on a production pod. The app template honours
  # it only under NODE_ENV development or test, and @viktorbarzin/auth ignores
  # it whenever OIDC is configured.
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = local.namespace
    labels = {
      tier              = var.tier
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_deployment" "this" {
  # CI owns rollouts (CI_SETS_IMAGE). Waiting here would fail the first apply,
  # which runs before the first image exists, and leave the Deployment tainted;
  # the next apply would then replace it and roll back CI's image.
  wait_for_rollout = false

  metadata {
    name      = var.name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = merge(local.labels, {
      tier = var.tier
    })
    annotations = {
      # Restart on a change to any Secret read through env. <name>-db-creds is
      # left out on purpose: the app reads the password file on every new
      # connection, so the Vault rotation needs no restart.
      "secret.reloader.stakater.com/reload" = join(",", local.env_from_secrets)
    }
  }

  spec {
    # The realtime LISTEN connection is per pod; more replicas spend more of
    # the shared Postgres connection budget (ADR-0001).
    replicas = var.replicas
    strategy {
      type = var.strategy
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Needed only for a private ghcr image (a package pushed from a private
        # GitHub repo is private); see README "Private repositories".
        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secrets
          content {
            name = image_pull_secrets.value
          }
        }

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
            value = local.database_url
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
            requests = var.migrate_resources.requests
            limits   = var.migrate_resources.limits
          }
        }

        container {
          name  = var.name
          image = local.image

          port {
            name           = "http"
            container_port = var.http_port
          }
          port {
            name           = "metrics"
            container_port = var.metrics_port
          }

          # <name>-secrets (app_secret_env), <name>-auth (BETTER_AUTH_SECRET,
          # OIDC_CLIENT_ID, OIDC_CLIENT_SECRET), the approver Secret
          # (AUTHENTIK_APPROVER_TOKEN, AUTHENTIK_USERS_GROUP_ID; request mode)
          # and the reader Secret (AUTHENTIK_READER_TOKEN).
          dynamic "env_from" {
            for_each = local.env_from_secrets
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          dynamic "env" {
            for_each = local.container_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/secrets/db"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = var.http_port
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = var.http_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }
        }

        # Mounted as a directory (no subPath) so the kubelet refreshes the
        # file when ESO writes a rotated password.
        volume {
          name = "db-password"
          secret {
            secret_name  = local.db_secret_name
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
    kubernetes_manifest.app_secrets,
    kubernetes_manifest.db_creds,
    kubernetes_manifest.auth_secrets,
  ]
}

resource "kubernetes_service" "this" {
  metadata {
    name      = var.name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
    annotations = {
      # /metrics is served only on the metrics port, which the ingress never
      # routes.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = tostring(var.metrics_port)
    }
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = var.http_port
      target_port = var.http_port
    }
    port {
      name        = "metrics"
      port        = var.metrics_port
      target_port = var.metrics_port
    }
  }
}

# Kyverno ClusterPolicy `sync-tls-secret` clones the wildcard TLS secret into
# every namespace, so there is no setup_tls_secret module here.
module "ingress" {
  source = "../ingress_factory"
  # auth = "app": the app runs its own OIDC sign-in against the Authentik
  # application in authentik.tf and answers /api with 401 without a session
  # or bearer token. Forward-auth would break the bearer-token API and the
  # OAuth callback.
  auth            = "app"
  dns_type        = var.ingress.dns_type
  namespace       = kubernetes_namespace.this.metadata[0].name
  name            = var.name
  service_name    = kubernetes_service.this.metadata[0].name
  port            = var.http_port
  tls_secret_name = var.tls_secret_name
  root_domain     = var.root_domain
  full_host       = var.host
  # Keeps the default rate-limit middleware: it runs the real-ip plugin, and
  # Better Auth's rate limiter keys on the X-Real-Ip that sets. Reasons for
  # the CSP, middleware, anti-AI and Turnstile defaults: var.ingress.
  custom_content_security_policy = var.ingress.custom_content_security_policy
  extra_middlewares              = var.ingress.extra_middlewares
  anti_ai_scraping               = var.ingress.anti_ai_scraping
  turnstile                      = var.ingress.turnstile
  homepage_group                 = var.ingress.homepage_group
  extra_annotations = {
    for k, v in {
      "gethomepage.dev/description" = var.ingress.homepage_description
      "gethomepage.dev/icon"        = var.ingress.homepage_icon
    } : k => v if v != null
  }
}

# User traffic only from Traefik, /metrics only from Prometheus.
resource "kubernetes_network_policy_v1" "ingress" {
  metadata {
    name      = "${var.name}-ingress"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = var.ingress_from_namespaces
        content {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = from.value
            }
          }
        }
      }
      ports {
        port     = tostring(var.http_port)
        protocol = "TCP"
      }
    }
    ingress {
      dynamic "from" {
        for_each = var.metrics_from_namespaces
        content {
          namespace_selector {
            match_labels = {
              "kubernetes.io/metadata.name" = from.value
            }
          }
        }
      }
      ports {
        port     = tostring(var.metrics_port)
        protocol = "TCP"
      }
    }
  }
}
