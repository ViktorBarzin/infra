variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag used when the Deployments are (re)created. The running tags are set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }
variable "nfs_server" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Reels: fast-cut trip films from Immich photos, optionally cut to the beat of
# a trending song (Forgejo viktor/trip-reel, private; plan in that repo at
# docs/plans/2026-11-11-reels-web-app.md). Two images from one repo:
#
# - reels (TanStack Start, module "app" below): accounts, trips, cuts, the
#   editor and preview, the gallery, and the job queue in its own database;
# - reels-worker (Python, kubernetes_deployment.worker): imports, picking,
#   beat timing, rendering, song download and the trending list. It claims
#   jobs from the same database and reaches the page through the app's
#   realtime NOTIFY channel.
#
# secret/reels holds better_auth_secret, oidc_client_id, oidc_client_secret,
# app_encryption_key (encrypts each person's Immich API key; both images read
# it) and trending_token (the worker's token for claude-agent-service's
# /v1/reels/trending-songs, the same value as secret/claude-agent-service
# reels_trending_token). Seeded by hand on 2026-11-11.
locals {
  namespace     = "reels"
  worker_labels = { app = "reels-worker" }
  immich_url    = "http://immich-server.immich:2283"
  trending_url  = "http://claude-agent-service.claude-agent.svc.cluster.local:8080/v1/reels/trending-songs"
}

# Renders and song audio. Photo images are never copied here: the web app
# proxies Immich, and the worker scores and renders from Immich directly.
# /srv/nfs/reels was created on the PVE host owned by 10001:10001, mode 750,
# before the first apply (docs/runbooks/nfs-prerequisites.md).
module "data" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "reels-data"
  namespace          = local.namespace
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/reels"
  storage            = "50Gi"
  storage_class_name = "nfs-pve"
  depends_on         = [module.app]
}

module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "reels"
  display_name = "Reels"
  tier         = local.tiers.aux

  # Private repo, private ghcr package: Kyverno clones ghcr-credentials into
  # this namespace (stacks/kyverno ghcr_private_namespaces).
  image              = "ghcr.io/viktorbarzin/reels"
  image_tag          = var.image_tag
  image_pull_secrets = ["ghcr-credentials"]

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = { APP_ENCRYPTION_KEY = "app_encryption_key" }
  extra_env = concat([
    { name = "IMMICH_URL", value = local.immich_url },
    { name = "DATA_DIR", value = "/data" },
  ], local.telemetry_env)
  # TELEMETRY_WRITE_KEY, SENTRY_DSN, SENTRY_BROWSER_DSN (telemetry.tf).
  secret_env     = local.telemetry_secret_env
  emit_group_env = true

  volumes = [{ name = "data", claim_name = "reels-data", mount_path = "/data" }]

  # The web pod proxies photo images and streams renders (Range requests).
  resources = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { memory = "768Mi" }
  }

  # Viktor approves everyone else (family members sign up by request).
  initial_user_pks = [data.authentik_user.viktor.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "Fast-cut trip films from your Immich photos, cut to a trending song"
    homepage_icon        = "mdi-filmstrip"
    homepage_group       = "Media & Entertainment"
  }
}

# The worker's own secrets: the module's reels-secrets carries only what the
# web app needs, and the trending token stays out of the web pod.
resource "kubernetes_manifest" "worker_secrets" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "reels-worker-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "reels-worker-secrets" }
      data = [
        { secretKey = "APP_ENCRYPTION_KEY", remoteRef = { key = "reels", property = "app_encryption_key" } },
        { secretKey = "TRENDING_TOKEN", remoteRef = { key = "reels", property = "trending_token" } },
      ]
    }
  }
  depends_on = [module.app]
}

resource "kubernetes_deployment" "worker" {
  metadata {
    name      = "reels-worker"
    namespace = local.namespace
    labels    = local.worker_labels
    annotations = {
      # Not reels-db-creds: the worker reads the password file on every new
      # connection, so the weekly rotation needs no restart (and a restart
      # would kill a render in progress).
      "secret.reloader.stakater.com/reload" = "reels-worker-secrets"
    }
  }

  spec {
    replicas = 1
    # One worker with two lanes (fast edits, slow imports and renders). A
    # rollout must not run two renderers side by side on the same jobs.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.worker_labels
    }
    template {
      metadata {
        labels = local.worker_labels
      }
      spec {
        security_context {
          run_as_non_root        = true
          run_as_user            = 10001
          run_as_group           = 10001
          fs_group               = 10001
          fs_group_change_policy = "OnRootMismatch"
        }

        image_pull_secrets {
          name = "ghcr-credentials"
        }

        # A render may be mid-encode; let it finish its current job.
        termination_grace_period_seconds = 120

        container {
          name  = "worker"
          image = "ghcr.io/viktorbarzin/reels-worker:${var.image_tag}"

          env_from {
            secret_ref {
              name = "reels-worker-secrets"
            }
          }
          env {
            name  = "DATABASE_URL"
            value = "postgres://reels@${var.postgresql_host}:5432/reels"
          }
          env {
            name  = "DATABASE_PASSWORD_FILE"
            value = "/secrets/db/password"
          }
          env {
            name  = "IMMICH_URL"
            value = local.immich_url
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "TRENDING_URL"
            value = local.trending_url
          }

          volume_mount {
            name       = "db-password"
            mount_path = "/secrets/db"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          # Rendering a 1080p final is a few cores for about a minute; the
          # request is the guaranteed share, the rest bursts into idle node
          # capacity (no CPU limits on this cluster).
          resources {
            requests = { cpu = "1", memory = "1Gi" }
            limits   = { memory = "3Gi" }
          }
        }

        # The module's reels-db-creds, mounted as a directory (no subPath) so
        # the kubelet refreshes the file when ESO writes a rotated password.
        volume {
          name = "db-password"
          secret {
            secret_name  = "reels-db-creds"
            default_mode = "0440"
            items {
              key  = "DB_PASSWORD"
              path = "password"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.data.claim_name
          }
        }
      }
    }
  }

  # CI owns rollouts; the first apply comes before the first worker image.
  wait_for_rollout = false

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      metadata[0].labels["tier"], # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }

  depends_on = [kubernetes_manifest.worker_secrets, module.data]
}
