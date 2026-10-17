# The Watcher (f1-stream ADR-0040, amended by ADR-0044, ADR-0045, ADR-0046).
#
# A fourth Role on the same image, `ROLE=watcher`. It watches every Feed of the
# hand-picked Tier 1 Channels through the Edges' in-cluster reader path
# (http://f1.f1-stream.svc.cluster.local/proxy), so it shares the viewers'
# upstream session and costs download only. It keeps a Reputation and a Watch
# score per Feed in the viewing Postgres, publishes the order a press on a
# Tier 1 Channel opens Feeds in (Redis), keeps the first of them resolved, and
# when a Tier 1 Channel has had no smooth Feed for 10 minutes posts one line to
# #alerts and files a `broken` + `channel-source` issue on viktor/infra, which
# dispatches `.claude/agents/channel-source-fixer.md`. The health card is at
# https://f1.viktorbarzin.me/admin/channels.
#
# One replica, Recreate: two Watchers would double every watch and every
# alert. No GPU and no Service: nothing routes to it. Prometheus scrapes it like
# every app pod (job f1-stream, by pod), which is where f1_watcher_* and
# f1_stgledai_exit_* come from.
#
# Memory: the process is the full app (about 250 MiB, like an Edge at rest)
# plus up to ~10 full watches and ~40 light ones, each streaming segments
# without holding them. 768Mi limit. The namespace quota still has room for a
# deploy with the Transcoder back on a surge (2026-10-17): limits used 10176Mi
# of 16Gi at rest, Watcher included; a Transcoder surge pod +2048Mi, the old
# Transcoder still terminating while the Edge surge pod starts +1536Mi, and the
# hourly source-guard job +768Mi come to 14528Mi. Requests peak at 3776Mi of
# 6Gi memory and 910m of 2 CPU. The quota is unchanged.
resource "kubernetes_deployment_v1" "f1_watcher" {
  metadata {
    name      = "f1-stream-watcher"
    namespace = local.f1_namespace
    labels = {
      app  = "f1-stream"
      role = "watcher"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app  = "f1-stream"
        role = "watcher"
      }
    }
    template {
      metadata {
        labels = {
          app  = "f1-stream"
          role = "watcher"
        }
      }
      spec {
        termination_grace_period_seconds = 30
        automount_service_account_token  = false
        container {
          # deploy.yml in the f1-stream repo sets the image by this name, after
          # the Edges (it reads through them).
          name  = "f1-stream"
          image = local.f1_image
          port {
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "768Mi"
            }
          }
          # Ready once its scheduler runs (backend/readiness.py). Nothing routes
          # here; the probe only tells a rollout the pod came up.
          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }
          env {
            name  = "ROLE"
            value = "watcher"
          }
          # Where it reads Feeds: the Edges, through the in-cluster Service, so
          # /proxy needs no signature and the rewritten playlist points back here.
          env {
            name  = "WATCHER_EDGE_BASE"
            value = local.f1_edge_url
          }
          # About this many full (Learning) watches at once (ADR-0044).
          env {
            name  = "WATCHER_FULL_SLOTS"
            value = "10"
          }
          # What full watches may bring the Watcher's download up to, in Mbit/s
          # (ADR-0044, Download budget). Alert: F1WatcherDownloadOverBudget.
          env {
            name  = "WATCHER_DOWNLOAD_BUDGET_MBPS"
            value = "30"
          }
          # ADR-0046, measured 2026-10-16 through proxy-egress-uk: no refusal up
          # to 120 mints/hour and 24 open Feeds. These are those floors less 50%
          # headroom (measured = 1.5 x configured), per exit.
          env {
            name  = "STGLEDAI_MAX_OPEN_FEEDS_PER_EXIT"
            value = "16"
          }
          env {
            name  = "STGLEDAI_MAX_MINTS_PER_HOUR_PER_EXIT"
            value = "80"
          }
          # Channels whose every Watcher sample is treated as failed, and whose
          # down alert goes out as a [drill] with no issue filed. Empty in
          # normal running; set to a non-family Channel to exercise the alert
          # path end to end.
          env {
            name  = "WATCHER_FAULT_CHANNELS"
            value = ""
          }
          env {
            name  = "WATCHER_ISSUE_REPO"
            value = "viktor/infra"
          }
          # The #alerts webhook and the Forgejo token the source guard already
          # carries in this namespace (f1-source-guard.tf). The token is
          # `viktor`'s, which is NOT the fixer's bot actor, so a filed issue
          # survives the webhook's loop guard and dispatches. optional, so the
          # pod starts before the ExternalSecret syncs; the app then logs the
          # line instead.
          env {
            name = "WATCHER_SLACK_WEBHOOK"
            value_from {
              secret_key_ref {
                name     = "f1-stream-guard-secrets"
                key      = "slack_webhook"
                optional = true
              }
            }
          }
          env {
            name = "WATCHER_FORGEJO_TOKEN"
            value_from {
              secret_key_ref {
                name     = "f1-stream-guard-secrets"
                key      = "forgejo_token"
                optional = true
              }
            }
          }
          # Signs the URLs and headers the Roles pass each other; set on every
          # Role (see the Edge).
          env {
            name = "ADMIN_SESSION_KEY"
            value_from {
              secret_key_ref {
                name     = "f1-stream-secrets"
                key      = "admin_session_key"
                optional = false
              }
            }
          }
          # Set on every Role, so this pod never trusts Authentik headers from
          # anything that can reach it (see the Edge).
          env {
            name = "INGRESS_PROOF_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.ingress_proof.metadata[0].name
                key  = "proof"
              }
            }
          }
          # Reputation, samples, the Tier 1 list and viewers' interruptions all
          # live in the viewing Postgres (schema version 7).
          env {
            name  = "VIEWING_DATABASE_URL"
            value = "postgresql://f1_stream@${var.postgresql_host}:5432/f1_stream"
          }
          env {
            name  = "VIEWING_DATABASE_PASSWORD_FILE"
            value = "/secrets/viewing-db/password"
          }
          # The gledaitv Feeds of Tier 1 need a browser capture to mint.
          env {
            name  = "CHROME_FLEET_URL"
            value = "http://chrome-fleet.chrome-service.svc.cluster.local:8080"
          }
          volume_mount {
            name       = "viewing-db"
            mount_path = "/secrets/viewing-db"
            read_only  = true
          }
        }
        volume {
          name = "viewing-db"
          secret {
            secret_name = "f1-stream-viewing-db"
            optional    = true
          }
        }
        image_pull_secrets {
          name = "registry-credentials"
        }
        image_pull_secrets {
          name = "ghcr-credentials"
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by its own CI
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}
