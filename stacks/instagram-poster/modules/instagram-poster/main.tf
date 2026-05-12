locals {
  namespace = "instagram-poster"
  # Forgejo registry consolidation (2026-05-07): all custom service images
  # live under forgejo.viktorbarzin.me/viktor/<name>. The old 10.0.20.10
  # private registry was decommissioned the same day.
  image = "forgejo.viktorbarzin.me/viktor/instagram-poster:${var.image_tag}"
  labels = {
    app = "instagram-poster"
  }
}

resource "kubernetes_namespace" "instagram_poster" {
  metadata {
    name = local.namespace
    labels = {
      tier              = var.tier
      "istio-injection" = "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets sourced from Vault KV `secret/instagram-poster`.
# Seed these manually in Vault before applying:
#   secret/instagram-poster -> properties:
#     - immich_api_key            (required)
#     - postiz_api_token          (required)
#     - immich_tag_instagram      (optional — auto-resolved if missing)
#     - immich_tag_posted         (optional — auto-resolved if missing)
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "instagram-poster-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "instagram-poster-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        {
          secretKey = "IMMICH_API_KEY"
          remoteRef = { key = "instagram-poster", property = "immich_api_key" }
        },
        {
          secretKey = "POSTIZ_API_TOKEN"
          remoteRef = { key = "instagram-poster", property = "postiz_api_token" }
        },
        {
          secretKey = "IMMICH_TAG_INSTAGRAM"
          remoteRef = { key = "instagram-poster", property = "immich_tag_instagram" }
        },
        {
          secretKey = "IMMICH_TAG_POSTED"
          remoteRef = { key = "instagram-poster", property = "immich_tag_posted" }
        },
        {
          secretKey = "TELEGRAM_BOT_TOKEN"
          remoteRef = { key = "instagram-poster", property = "telegram_bot_token" }
        },
        {
          secretKey = "TELEGRAM_CHAT_ID"
          remoteRef = { key = "instagram-poster", property = "telegram_chat_id" }
        },
        {
          secretKey = "POSTIZ_INTEGRATION_ID"
          remoteRef = { key = "instagram-poster", property = "postiz_integration_id" }
        },
        {
          secretKey = "IMMICH_PG_HOST"
          remoteRef = { key = "instagram-poster", property = "immich_pg_host" }
        },
        {
          secretKey = "IMMICH_PG_PORT"
          remoteRef = { key = "instagram-poster", property = "immich_pg_port" }
        },
        {
          secretKey = "IMMICH_PG_DATABASE"
          remoteRef = { key = "instagram-poster", property = "immich_pg_database" }
        },
        {
          secretKey = "IMMICH_PG_USER"
          remoteRef = { key = "instagram-poster", property = "immich_pg_user" }
        },
        {
          secretKey = "IMMICH_PG_PASSWORD"
          remoteRef = { key = "instagram-poster", property = "immich_pg_password" }
        },
        # IG-archive dedup: tokens for Meta Graph API live ingest. Token
        # is the long-lived (60-day) IG user access token. The token-refresh
        # CronJob writes the rotated value back to Vault; ESO syncs it
        # back into this Secret on its 15m interval.
        {
          secretKey = "IG_GRAPH_TOKEN"
          remoteRef = { key = "instagram-poster", property = "ig_graph_long_lived_token" }
        },
        {
          secretKey = "IG_GRAPH_APP_ID"
          remoteRef = { key = "instagram-poster", property = "ig_graph_app_id" }
        },
        {
          secretKey = "IG_GRAPH_APP_SECRET"
          remoteRef = { key = "instagram-poster", property = "ig_graph_app_secret" }
        },
        {
          secretKey = "IG_BUSINESS_ACCOUNT_ID"
          remoteRef = { key = "instagram-poster", property = "ig_business_account_id" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.instagram_poster]
}

# Benchmark scoring DB — shared CNPG cluster, written by the
# `instagram_poster.benchmark` CLI (vision-LLM scores per Immich asset).
# Vault static role `pg-instagram-poster` rotates the password every 7 days;
# ESO refreshes the K8s Secret every 15m. `reloader.stakater.com/match`
# bounces the pod when the password changes.
resource "kubernetes_manifest" "benchmark_db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "instagram-poster-benchmark-db"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "instagram-poster-benchmark-db"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            BENCHMARK_PG_HOST     = "pg-cluster-rw.dbaas.svc.cluster.local"
            BENCHMARK_PG_PORT     = "5432"
            BENCHMARK_PG_DATABASE = "instagram_poster"
            BENCHMARK_PG_USER     = "instagram_poster"
            BENCHMARK_PG_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-instagram-poster"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.instagram_poster]
}

# Persistent state: SQLite + image cache. Sensitive (API tokens may end up
# in cached images / debug logs), but the proxmox-lvm-encrypted SC is for
# user-data DBs; this is a small app cache so plain proxmox-lvm fits the
# infra/.claude/CLAUDE.md decision rule.
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "instagram-poster-data"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "instagram_poster" {
  metadata {
    name      = "instagram-poster"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels = merge(local.labels, {
      tier = var.tier
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }

  spec {
    replicas = 1
    # RWO PVC — cannot rolling-update.
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
          # Diun watches this image tag and POSTs the auto-upgrade pipeline.
          "diun.enable" = "true"
        }
      }

      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }

        # PVC mounts as root by default; pod runs as uid/gid 10001 (poster).
        # fs_group makes kubelet chown the volume to gid 10001 on mount.
        security_context {
          fs_group        = 10001
          run_as_user     = 10001
          run_as_group    = 10001
          run_as_non_root = true
        }

        container {
          name  = "instagram-poster"
          image = local.image

          port {
            container_port = 8000
          }

          env_from {
            secret_ref {
              name = "instagram-poster-secrets"
            }
          }
          # Vault-rotated benchmark Postgres creds. Sources BENCHMARK_PG_*
          # env vars into the container; benchmark.py builds the SQLAlchemy
          # URL from them. Schema bootstraps via Base.metadata.create_all
          # on first use.
          env_from {
            secret_ref {
              name = "instagram-poster-benchmark-db"
            }
          }

          env {
            name  = "IMMICH_BASE_URL"
            value = "https://immich.viktorbarzin.me"
          }
          env {
            name  = "POSTIZ_BASE_URL"
            value = "http://postiz.postiz.svc.cluster.local"
          }
          env {
            name  = "PUBLIC_BASE_URL"
            value = "https://instagram-poster.viktorbarzin.me"
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "LOG_LEVEL"
            value = "INFO"
          }
          # IG-archive dedup config. Defaults match the Python Settings
          # class; override here so a flag flip is a `terraform apply`
          # not a code change. `enabled=false` until the export-zip
          # backfill + a few days of /ig-ingest produce a populated
          # ig_posted_media table — we don't want to filter everything
          # out on day one when the table is empty.
          env {
            name  = "IG_DEDUP_ENABLED"
            value = "false"
          }
          env {
            name  = "IG_ML_URL"
            value = "http://immich-machine-learning.immich.svc.cluster.local:3003"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

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
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            # Pillow full-resolution HEIC decode peaks ~600-800Mi for big phone
            # photos; 512Mi was OOMKilling on /original requests.
            limits = {
              memory = "1500Mi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }

  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.benchmark_db_external_secret,
  ]
}

resource "kubernetes_service" "instagram_poster" {
  metadata {
    name      = "instagram-poster"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.labels

    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

# Two ingresses on the same host — Traefik picks the longest path prefix.
#
# `/image/*` must be reachable WITHOUT auth so Meta's content fetcher (and
# Telegram's photo preview) can render the 9:16 derivatives we produce.
# Everything else (/queue, /scan, /enqueue, /post-next, /reject, /healthz)
# sits behind Authentik forward-auth — same defense as every other UI on
# the cluster, no random caller can pop items off the approval queue.
module "ingress_image_public" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.instagram_poster.metadata[0].name
  name            = "instagram-poster-image"
  host            = "instagram-poster"
  tls_secret_name = var.tls_secret_name
  # auth = "none": Meta's content fetcher needs to render image derivatives without auth headers (Instagram photos).
  auth            = "none"
  ingress_path    = ["/image", "/original"]
  port            = 80
  service_name    = "instagram-poster"
}

module "ingress_protected" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "none" # DNS record already created by the public ingress above
  namespace       = kubernetes_namespace.instagram_poster.metadata[0].name
  name            = "instagram-poster"
  host            = "instagram-poster"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  ingress_path    = ["/"]
  port            = 80
  service_name    = "instagram-poster"
}

# IG-archive dedup live ingest. Three CronJobs all curl back into the
# in-cluster Service. /ig-ingest is idempotent (ON CONFLICT DO NOTHING),
# so missed runs / restarts are harmless.
#
# Cadence rationale (plan §4):
#   stories — */30. Stories age out at 24h; running every 30m means a
#             missed run still catches the entire window with margin.
#   feed    — every 6h. Feed posts don't expire; this is just for
#             "what's been posted since last poll".
#   refresh — daily 02:00. Long-lived token has 60-day TTL; refreshing
#             daily is wildly conservative but cheap, and the
#             alternative ("rotate at expiry-7d") needs persistent state.

locals {
  ig_cron_image = "curlimages/curl:8.10.1"
}

resource "kubernetes_cron_job_v1" "ig_ingest_stories" {
  # Temporarily disabled: the /ig-ingest endpoint exists in working-copy
  # changes to instagram_poster/app.py but hasn't been committed/built/
  # deployed yet, so every fire returns 404 and JobFailed alerts fire.
  # Re-enable by removing `count = 0` once the endpoint is shipped.
  count = 0

  metadata {
    name      = "ig-ingest-stories"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "*/30 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "ingest"
              image = local.ig_cron_image
              command = [
                "sh", "-c",
                "curl -fsS -X POST http://instagram-poster.instagram-poster.svc.cluster.local/ig-ingest -H 'Content-Type: application/json' -d '{\"include\":[\"stories\"]}'",
              ]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_deployment.instagram_poster]
}

resource "kubernetes_cron_job_v1" "ig_ingest_feed" {
  metadata {
    name      = "ig-ingest-feed"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "0 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "ingest"
              image = local.ig_cron_image
              command = [
                "sh", "-c",
                "curl -fsS -X POST http://instagram-poster.instagram-poster.svc.cluster.local/ig-ingest -H 'Content-Type: application/json' -d '{\"include\":[\"feed\"]}'",
              ]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_deployment.instagram_poster]
}

# Daily token refresh. Hits /ig-refresh-token which returns the new token
# in JSON; we don't write it back to Vault here — that's a follow-up
# decision (plan §6, open item #2). For now the new token is logged and
# operators rotate manually if it ever fails. The 60-day TTL gives plenty
# of room.
resource "kubernetes_cron_job_v1" "ig_refresh_token" {
  metadata {
    name      = "ig-refresh-token"
    namespace = kubernetes_namespace.instagram_poster.metadata[0].name
    labels    = local.labels
  }
  spec {
    # Suspended 2026-05-12 — chronic JobFailed because the deployed image
    # (currently :da5b4191) doesn't yet contain the `POST /ig-refresh-token`
    # FastAPI route. The route is in the working copy at
    # `instagram-poster/instagram_poster/app.py:695` but uncommitted, so
    # the cron returns 404 every night. Unsuspend after the new image
    # rolls (commit + push to instagram-poster repo, GHA builds + Woodpecker
    # deploys, then remove this `suspend = true` line).
    suspend                       = true
    schedule                      = "0 2 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "refresh"
              image = local.ig_cron_image
              command = [
                "sh", "-c",
                "curl -fsS -X POST http://instagram-poster.instagram-poster.svc.cluster.local/ig-refresh-token",
              ]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_deployment.instagram_poster]
}
