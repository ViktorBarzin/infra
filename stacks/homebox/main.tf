# Homebox: the home inventory (docs/architecture/homebox.md). Things,
# where they are stored (nested locations), tags and photos. Viktor sends an
# agent photos of things; the agent adds them through the API with the key
# in Vault secret/homebox-agent, and answers "do I have X" by searching it.
#
# One pod. Data: Postgres for the database, NFS /srv/nfs/homebox for the
# photos and attachments, which the NFS backup chain carries offsite.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }
variable "nfs_server" { type = string }

locals {
  namespace = "homebox"
  host      = "homebox.viktorbarzin.me"
  image     = "ghcr.io/sysadminsmedia/homebox:0.27.1"

  oidc_client_id = "homebox"

  labels = {
    app = "homebox"
  }

  env = {
    TZ             = "Europe/London"
    HBOX_LOG_LEVEL = "info"
    # Phone photos are often over the 10 MB default.
    HBOX_WEB_MAX_UPLOAD_SIZE = "30"

    HBOX_DATABASE_DRIVER   = "postgres"
    HBOX_DATABASE_HOST     = var.postgresql_host
    HBOX_DATABASE_PORT     = "5432"
    HBOX_DATABASE_USERNAME = "homebox"
    HBOX_DATABASE_DATABASE = "homebox"
    HBOX_DATABASE_SSL_MODE = "disable"

    # Sign-in only through the Authentik application in authentik.tf, which
    # decides who gets in. No local passwords and no self-registration on a
    # public hostname. API keys still work: they do not use local login.
    HBOX_OPTIONS_ALLOW_REGISTRATION = "false"
    HBOX_OPTIONS_ALLOW_LOCAL_LOGIN  = "false"
    HBOX_OPTIONS_TRUST_PROXY        = "true"
    HBOX_OPTIONS_HOSTNAME           = local.host
    HBOX_OIDC_ENABLED               = "true"
    HBOX_OIDC_ISSUER_URL            = "https://authentik.viktorbarzin.me/application/o/homebox/"
    HBOX_OIDC_CLIENT_ID             = local.oidc_client_id
    HBOX_OIDC_AUTO_REDIRECT         = "true"
    HBOX_OIDC_BUTTON_TEXT           = "Sign in with Authentik"
  }

  secret_env = {
    HBOX_OIDC_CLIENT_SECRET  = { secret = "homebox-secrets", key = "oidc_client_secret" }
    HBOX_AUTH_API_KEY_PEPPER = { secret = "homebox-secrets", key = "api_key_pepper" }
    HBOX_DATABASE_PASSWORD   = { secret = "homebox-db-creds", key = "password" }
  }
}

resource "kubernetes_namespace" "homebox" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Vault KV secret/homebox: oidc_client_secret and api_key_pepper. The pepper
# is HMAC-keyed into every stored API key hash; changing it invalidates all
# API keys. The agent's key is in secret/homebox-agent, which the pod never
# needs.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "homebox-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "homebox-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      dataFrom = [{
        extract = {
          key = "homebox"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.homebox]
}

# Database password from the Vault static role pg-homebox
# (stacks/vault app_db_roles.tf), rotated weekly in its Tuesday slot. The
# db-rotation-watcher force-syncs this ExternalSecret and Reloader restarts
# the pod.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "homebox-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "homebox-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-homebox"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.homebox]
}

# Photos and attachments. Plain files, no database on it (the database is
# Postgres), so NFS: it needs no block volume slot, and /srv/nfs is mirrored
# to sda and the Synology nightly.
module "nfs_data" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "homebox-data-host"
  namespace          = kubernetes_namespace.homebox.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/homebox"
  storage_class_name = "nfs-pve"
  storage            = "20Gi"
}

resource "kubernetes_deployment" "homebox" {
  metadata {
    name      = "homebox"
    namespace = kubernetes_namespace.homebox.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      # Homebox runs its schema migrations at start; two versions must not
      # migrate side by side during an upgrade.
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        container {
          name  = "homebox"
          image = local.image

          port {
            name           = "http"
            container_port = 7745
          }
          dynamic "env" {
            for_each = local.env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = env.value.secret
                  key  = env.value.key
                }
              }
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # /api/v1/status is the image's own Docker HEALTHCHECK target.
          startup_probe {
            http_get {
              path = "/api/v1/status"
              port = 7745
            }
            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 60
          }
          liveness_probe {
            http_get {
              path = "/api/v1/status"
              port = 7745
            }
            period_seconds    = 30
            timeout_seconds   = 10
            failure_threshold = 3
          }
          readiness_probe {
            http_get {
              path = "/api/v1/status"
              port = 7745
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
          }
          # Upstream quotes about 50 MB idle; thumbnailing a large photo
          # takes more. Right-size with krr after a few weeks.
          resources {
            requests = {
              cpu    = "20m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

resource "kubernetes_service" "homebox" {
  metadata {
    name      = "homebox"
    namespace = kubernetes_namespace.homebox.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 7745
    }
  }
}

# The web app loads its JavaScript chunks, thumbnails and a burst of API
# calls at once; the default 10/50 per-client limiter answered 429 to the
# first page load of Bambuddy and GlitchTip, which load the same way.
resource "kubernetes_manifest" "rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "homebox-rate-limit"
      namespace = kubernetes_namespace.homebox.metadata[0].name
    }
    spec = {
      rateLimit = {
        average = 50
        burst   = 300
        sourceCriterion = {
          requestHeaderName = "X-Client-Prefix"
        }
      }
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Forward auth would 302 the agent's API calls, which authenticate with a
  # Homebox API key.
  # auth = "app": Homebox's own login gates the UI and API (OIDC through the Authentik application in authentik.tf for Home Server Admins, no local login or registration, API keys for agents).
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.homebox.metadata[0].name
  name            = "homebox"
  tls_secret_name = var.tls_secret_name
  # real-ip first so X-Client-Prefix is set for the per-client limiter.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-real-ip@kubernetescrd",
    "homebox-homebox-rate-limit@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Homebox"
    "gethomepage.dev/description"  = "Home inventory: what we own and where it is"
    "gethomepage.dev/icon"         = "homebox.png"
    "gethomepage.dev/group"        = "Home"
    "gethomepage.dev/pod-selector" = ""
  }
}
