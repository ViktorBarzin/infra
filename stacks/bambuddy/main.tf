# Bambuddy: the 3D-print workshop for the Bambu Lab P2S in Emo's Sofia flat
# (docs/architecture/bambuddy.md). Projects, model library, server-side
# slicing, camera and print queue in one web app; agents publish designs into
# it with `homelab print`.
#
# One pod, two containers: Bambuddy itself, and the Bambu Studio CLI sidecar
# that its Slice button calls on localhost:3001. Data: Postgres for the
# database, NFS /srv/nfs/bambuddy for the files (library, archive, plate
# calibration references), which the NFS backup chain carries offsite.
#
# The printer is reached on the Sofia LAN (192.168.1.110: MQTT 8883, FTPS 990,
# camera 322). Until the printer is switched to Developer Mode, Bambuddy only
# reads its status; starting a print from Bambuddy needs Developer Mode.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }
variable "nfs_server" { type = string }

locals {
  namespace = "bambuddy"
  host      = "bambuddy.viktorbarzin.me"
  # Bambuddy and its slicer sidecar are released together; keep the tags equal.
  image        = "ghcr.io/maziggy/bambuddy:1.3.2"
  slicer_image = "ghcr.io/maziggy/bambu-studio-api:bambuddy-1.3.2"

  oidc_client_id = "bambuddy"

  labels = {
    app = "bambuddy"
  }

  env = {
    TZ      = "Europe/Sofia"
    APP_URL = "https://${local.host}"
    # Logs go to stdout (Loki); the image's file log would only fill the pod.
    LOG_TO_FILE = "false"
    # The sidecar below. Only the Bambu Studio engine is deployed, the same
    # slicer Emo uses on his laptop; the OrcaSlicer URL points at it too so a
    # setting that picks OrcaSlicer still reaches a slicer.
    BAMBU_STUDIO_API_URL = "http://localhost:3001"
    SLICER_API_URL       = "http://localhost:3001"
    # Bambuddy's Postgres default is 20 + 60 connections. One pod and two
    # people need a handful on the shared primary (max_connections 300).
    DB_POOL_SIZE    = "3"
    DB_MAX_OVERFLOW = "4"
    # No outbound bug reports from this install.
    BUG_REPORT_RELAY_URL = ""

    # Sign-in through the Authentik application in authentik.tf. Local login
    # stays on for the bootstrap admin (Vault secret/bambuddy admin_password)
    # and the agent account that owns the `homelab print` API key.
    BAMBUDDY_OIDC_NAME                   = "Authentik"
    BAMBUDDY_OIDC_ISSUER_URL             = "https://authentik.viktorbarzin.me/application/o/bambuddy/"
    BAMBUDDY_OIDC_CLIENT_ID              = local.oidc_client_id
    BAMBUDDY_OIDC_SCOPES                 = "openid email profile"
    BAMBUDDY_OIDC_EMAIL_CLAIM            = "email"
    BAMBUDDY_OIDC_AUTO_CREATE_USERS      = "true"
    BAMBUDDY_OIDC_REQUIRE_EMAIL_VERIFIED = "false"
    BAMBUDDY_OIDC_GROUP_CLAIM            = "groups"
    BAMBUDDY_OIDC_GROUP_MAPPING          = jsonencode({ "Home Server Admins" = "Administrators" })
  }

  secret_env = {
    JWT_SECRET_KEY              = { secret = "bambuddy-secrets", key = "jwt_secret_key" }
    MFA_ENCRYPTION_KEY          = { secret = "bambuddy-secrets", key = "mfa_encryption_key" }
    BAMBUDDY_OIDC_CLIENT_SECRET = { secret = "bambuddy-secrets", key = "oidc_client_secret" }
    DATABASE_URL                = { secret = "bambuddy-db-creds", key = "DATABASE_URL" }
  }
}

resource "kubernetes_namespace" "bambuddy" {
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

# Vault KV secret/bambuddy: jwt_secret_key, mfa_encryption_key,
# oidc_client_secret, and admin_password (the bootstrap admin, not read by the
# pod). The agent's API key is in secret/bambuddy-agent, which the pod never
# needs.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "bambuddy-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "bambuddy-secrets"
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
          key = "bambuddy"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.bambuddy]
}

# Database credentials from the Vault static role pg-bambuddy
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
      name      = "bambuddy-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "bambuddy-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DATABASE_URL = "postgresql+asyncpg://bambuddy:{{ .password }}@${var.postgresql_host}:5432/bambuddy"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-bambuddy"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.bambuddy]
}

# Library files, print archive and plate-detection references. Plain files,
# no database on it (the database is Postgres), so NFS: it needs no block
# volume slot, and /srv/nfs is mirrored to sda and the Synology nightly.
module "nfs_data" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "bambuddy-data-host"
  namespace          = kubernetes_namespace.bambuddy.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/bambuddy"
  storage_class_name = "nfs-pve"
  storage            = "20Gi"
}

resource "kubernetes_deployment" "bambuddy" {
  metadata {
    name      = "bambuddy"
    namespace = kubernetes_namespace.bambuddy.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    # One replica: Bambuddy keeps one MQTT session per printer and runs its
    # queue scheduler in-process.
    replicas = 1
    strategy {
      # Two pods would both hold the printer's MQTT session and both run the
      # queue scheduler during a rolling update.
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
          name  = "bambuddy"
          image = local.image
          # The entrypoint starts as root, chowns /app/data to PUID:PGID
          # (1000 by default) and drops to that user with gosu.

          port {
            name           = "http"
            container_port = 8000
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
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "logs"
            mount_path = "/app/logs"
          }
          # /health is the image's own Docker HEALTHCHECK target.
          startup_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 60
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds    = 30
            timeout_seconds   = 10
            failure_threshold = 3
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
          }
          # No measurements yet. Right-size with krr after a few weeks.
          resources {
            requests = {
              cpu    = "50m"
              memory = "384Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        # Bambu Studio CLI behind a small HTTP API; Bambuddy posts a model and
        # profiles to it and gets a .gcode.3mf back. Idle between slices.
        container {
          name  = "bambu-studio-api"
          image = local.slicer_image
          port {
            name           = "slicer"
            container_port = 3001
          }
          env {
            name  = "NODE_ENV"
            value = "production"
          }
          env {
            name  = "PORT"
            value = "3001"
          }
          env {
            name  = "MAX_MODEL_UPLOAD_MB"
            value = "200"
          }
          volume_mount {
            name       = "slicer-data"
            mount_path = "/app/data"
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 3001
            }
            period_seconds  = 30
            timeout_seconds = 5
          }
          # A slice of a large multi-part plate peaks around 1-2 GiB.
          resources {
            requests = {
              cpu    = "20m"
              memory = "256Mi"
            }
            limits = {
              memory = "3Gi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "logs"
          empty_dir {}
        }
        # Uploaded models and profile caches for one slice at a time.
        volume {
          name = "slicer-data"
          empty_dir {
            size_limit = "2Gi"
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

resource "kubernetes_service" "bambuddy" {
  metadata {
    name      = "bambuddy"
    namespace = kubernetes_namespace.bambuddy.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

# The web app loads its JavaScript chunks, the model thumbnails and a burst of
# API calls at once; the default 10/50 per-client limiter answered 429 to the
# login page's own API calls on first load (2026-11-22), as it did for
# GlitchTip.
resource "kubernetes_manifest" "rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "bambuddy-rate-limit"
      namespace = kubernetes_namespace.bambuddy.metadata[0].name
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
  # Forward auth would 302 the `homelab print` API calls, which authenticate
  # with a Bambuddy API key.
  # auth = "app": Bambuddy's own login gates the UI and API (authentication enabled at bootstrap, sign-in through the Authentik OIDC application in authentik.tf for Home Server Admins, API keys for agents).
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.bambuddy.metadata[0].name
  name            = "bambuddy"
  tls_secret_name = var.tls_secret_name
  # real-ip first so X-Client-Prefix is set for the per-client limiter.
  skip_default_rate_limit = true
  extra_middlewares = [
    "traefik-real-ip@kubernetescrd",
    "bambuddy-bambuddy-rate-limit@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Bambuddy"
    "gethomepage.dev/description"  = "3D print projects, models and the P2S printer"
    "gethomepage.dev/icon"         = "mdi-printer-3d"
    "gethomepage.dev/group"        = "Home"
    "gethomepage.dev/pod-selector" = ""
  }
}
