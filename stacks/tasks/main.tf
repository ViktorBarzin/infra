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
  # ignore_changes'd (KEEL_IGNORE_IMAGE), so this base only matters on
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
#   secret/tasks
#     fernet_key — Fernet key encrypting the per-user Nextcloud app passwords
#                  stored in the Connected Accounts table (tasks ADR-0002).
#
# DB: CNPG database `tasks` (created in dbaas, null_resource.pg_tasks_db);
# role password managed via the Vault database engine — see
# static-creds/pg-tasks. Alembic runs migrations on app startup (no init
# container needed).
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
      refreshInterval = "15m"
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

# DB credentials from Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI app as TASKS_DB_DSN.
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
            TASKS_DB_DSN = "postgresql+asyncpg://tasks:{{ .password }}@${var.postgresql_host}:5432/tasks"
            DB_PASSWORD  = "{{ .password }}"
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
      # Reloader restarts the pod when tasks-secrets / tasks-db-creds change
      # (both carry reloader.stakater.com/match=true) — required because the
      # DB password rotates every 7 days and is read only at startup.
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    # Single leader: the CalDAV sync engine wants one writer per user's
    # sync-token cursor; the SPA is served by the same process.
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
          # Prometheus scrapes the service-endpoints (annotations live on the
          # Service below); the pod annotations here let the kubernetes-pods
          # SD job also discover /metrics directly.
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = "8000"
        }
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        container {
          name  = "tasks"
          image = local.image

          port {
            container_port = 8000
          }

          # TASKS_FERNET_KEY via tasks-secrets; TASKS_DB_DSN via tasks-db-creds.
          env_from {
            secret_ref { name = "tasks-secrets" }
          }
          env_from {
            secret_ref { name = "tasks-db-creds" }
          }

          # Wall-clock zone for all-day due dates (DUE;VALUE=DATE) and the
          # Today/Scheduled smart views.
          env {
            name  = "TASKS_LOCAL_TZ"
            value = "Europe/Sofia"
          }
          # SECURITY INVARIANT — DEV_USER must NEVER be set here. It is the
          # dev-only identity fallback: when present the backend treats every
          # request as that user, bypassing the Authentik forward-auth
          # identity (X-authentik-username) entirely. Production identity
          # comes ONLY from the header Traefik/Authentik injects.

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          resources {
            requests = { cpu = "100m", memory = "384Mi" }
            limits   = { memory = "384Mi" }
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Woodpecker deploy sets the running tag
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

resource "kubernetes_service" "tasks" {
  metadata {
    name      = "tasks"
    namespace = kubernetes_namespace.tasks.metadata[0].name
    labels    = local.labels
    annotations = {
      # Prometheus kubernetes-service-endpoints SD scrapes /metrics here.
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "8000"
    }
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}

# Kyverno ClusterPolicy `sync-tls-secret` auto-clones the wildcard TLS
# secret into every namespace, so we don't need a setup_tls_secret module.

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "required": Authentik forward-auth gates EVERY request — the app
  # has no login of its own and blindly trusts the X-authentik-username
  # header the outpost injects, so Authentik is the only thing standing
  # between strangers and everyone's tasks. Do NOT relax this tier (tasks
  # design decision #3; pairs with the NetworkPolicy below, SEC-1).
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.tasks.metadata[0].name
  name            = "tasks"
  port            = 8000
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/icon" = "mdi-format-list-checks"
  }
}

# Carve-out for the PWA icon assets + web manifest. macOS Safari's
# "Add to Dock" (and every other OS icon fetcher: iOS Add-to-Home-Screen,
# Android install prompt) fetches these in a cookie-less context — behind
# forward-auth it got the Authentik 302 and fell back to a letter monogram.
# Traefik prioritises these longer path prefixes over the main "/" router,
# so ONLY these five static files bypass Authentik; the SPA shell and /api
# stay gated by the main ingress above (and the app itself 401s /api
# without the identity header). Guarded against regression by the
# tasks-icons entry in the Authentik walling-off probe
# (stacks/monitoring/modules/monitoring/authentik_walloff_probe.tf).
module "ingress_icons" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": public static icons + manifest, no user data; required for
  # OS icon fetchers (Safari Add-to-Dock etc.) that carry no session and
  # cannot complete the Authentik redirect dance.
  auth         = "none"
  namespace    = kubernetes_namespace.tasks.metadata[0].name
  name         = "tasks-icons"
  service_name = kubernetes_service.tasks.metadata[0].name
  port         = 8000
  ingress_path = [
    "/apple-touch-icon.png",
    "/favicon.png",
    "/pwa-192x192.png",
    "/pwa-512x512.png",
    "/manifest.webmanifest",
  ]
  full_host        = "tasks.viktorbarzin.me" # MUST match the main ingress host; otherwise the factory derives tasks-icons.viktorbarzin.me and the carve-out never matches.
  dns_type         = "none"                  # host record already owned by the main tasks ingress
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false # Five static icons + a manifest; nothing for scrapers to mine.
  homepage_enabled = false # path carve-out, not its own dashboard tile
}

# --- NetworkPolicy: scoped pod ingress (security-review finding SEC-1). ---
# The app trusts X-authentik-username unconditionally, so its ENTIRE auth
# model depends on requests only ever arriving through Traefik (where the
# Authentik forward-auth middleware sets that header). Any pod that could
# reach the pod IP directly could spoof the header and read/write anyone's
# tasks — hence ingress is restricted to:
#   - TCP/8000 from the traefik namespace (user traffic, post-forward-auth);
#   - TCP/8000 from the monitoring namespace (Prometheus /metrics scrape).
# The cluster has no default-deny, so this NP only takes effect inside the
# tasks ns — pods elsewhere remain unaffected. (Same shape as
# chrome-service's chrome-service-ws-ingress.)
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
        port     = "8000"
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
        port     = "8000"
        protocol = "TCP"
      }
    }
  }
}
