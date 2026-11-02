# The Watcher (tv ADR-0040, amended by ADR-0044, ADR-0045, ADR-0046).
#
# A fourth Role on the same image, `ROLE=watcher`. It watches every Feed of the
# hand-picked Tier 1 Channels through the Edges' in-cluster reader path
# (http://tv.tv.svc.cluster.local/proxy), so it shares the viewers'
# upstream session and costs download only. It keeps a Reputation and a Watch
# score per Feed in the viewing Postgres, publishes the order a press on a
# Tier 1 Channel opens Feeds in (Redis), keeps the first of them resolved, and
# when a Tier 1 Channel has had no smooth Feed for 10 minutes posts one line to
# #alerts and files a `broken` + `channel-source` issue on viktor/infra, which
# dispatches `.claude/agents/source-fixer.md`. The health card is at
# https://tv.viktorbarzin.me/admin/channels.
#
# Since tv plan 2026-11-01-f1-channels-build, Tier 1 also takes the F1 group
# on its own: the curated F1 Channels with a Feed all the time, and F1 Live
# from 60 minutes before a session to 30 minutes after it, read from the F1
# calendar. That gate replaced the hourly source-guard CronJob.
#
# One replica, Recreate: two Watchers would double every watch and every
# alert. No GPU and no Service: nothing routes to it. Prometheus scrapes it like
# every app pod (job tv, by pod), which is where tv_watcher_* and
# tv_stgledai_exit_* come from.
#
# Memory: the process is the full app (about 250 MiB, like an Edge at rest)
# plus up to ~10 full watches and ~40 light ones, each streaming segments
# without holding them. 768Mi limit. The namespace quota still has room for a
# deploy with the Transcoder back on a surge (2026-10-17): limits used 10176Mi
# of 16Gi at rest, Watcher included; a Transcoder surge pod +2048Mi and the old
# Transcoder still terminating while the Edge surge pod starts +1536Mi come to
# 13760Mi. That was 14528Mi with the hourly source-guard Job's 768Mi, retired
# in 2026-11 (tv plan 2026-11-01-f1-channels-build). Requests peaked at
# 3776Mi of 6Gi memory and 910m of 2 CPU with the guard Job, whose requests
# were 256Mi and 50m. The quota is unchanged.
resource "kubernetes_deployment_v1" "tv_watcher" {
  metadata {
    name      = "tv-watcher"
    namespace = local.tv_namespace
    labels = {
      app  = "tv"
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
        app  = "tv"
        role = "watcher"
      }
    }
    template {
      metadata {
        labels = {
          app  = "tv"
          role = "watcher"
        }
      }
      spec {
        termination_grace_period_seconds = 30
        automount_service_account_token  = false
        container {
          # deploy.yml in the tv repo sets the image by this name, after
          # the Edges (it reads through them).
          name  = "tv"
          image = local.tv_image
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
          # Ready once its scheduler runs (tv/readiness.py). Nothing routes
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
            value = local.tv_edge_url
          }
          # About this many full (Learning) watches at once (ADR-0044).
          env {
            name  = "WATCHER_FULL_SLOTS"
            value = "10"
          }
          # What full watches may bring the Watcher's download up to, in Mbit/s
          # (ADR-0044, Download budget). Raised from 30 to 45 on 2026-10-18.
          # Alert: TvWatcherDownloadOverBudget, which reads this value back
          # from the tv_watcher_download_budget_mbps gauge.
          env {
            name  = "WATCHER_DOWNLOAD_BUDGET_MBPS"
            value = "45"
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
          # The #alerts webhook and the Forgejo token in tv-guard-secrets
          # (defined at the end of this file). The token is
          # `viktor`'s, which is NOT the fixer's bot actor, so a filed issue
          # survives the webhook's loop guard and dispatches. optional, so the
          # pod starts before the ExternalSecret syncs; the app then logs the
          # line instead.
          env {
            name = "WATCHER_SLACK_WEBHOOK"
            value_from {
              secret_key_ref {
                name     = "tv-guard-secrets"
                key      = "slack_webhook"
                optional = true
              }
            }
          }
          env {
            name = "WATCHER_FORGEJO_TOKEN"
            value_from {
              secret_key_ref {
                name     = "tv-guard-secrets"
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
                name     = "tv-secrets"
                key      = "admin_session_key"
                optional = false
              }
            }
          }
          # Pinned keys; see tv_env_secrets in main.tf.
          env {
            name = "URL_SIGNING_KEY"
            value_from {
              secret_key_ref {
                name     = "tv-secrets"
                key      = "url_signing_key"
                optional = false
              }
            }
          }
          env {
            name = "FEED_ID_KEY"
            value_from {
              secret_key_ref {
                name     = "tv-secrets"
                key      = "feed_id_key"
                optional = false
              }
            }
          }
          env {
            name = "PLAYBACK_REPORT_KEY"
            value_from {
              secret_key_ref {
                name     = "tv-secrets"
                key      = "playback_report_key"
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
            value = "postgresql://tv@${var.postgresql_host}:5432/tv"
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
            secret_name = "tv-viewing-db"
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

# Credentials the tv issue filers need in this namespace: the Watcher (below)
# and the Worker's daily source probe (main.tf), which file `broken` +
# `channel-source` issues on viktor/infra, and every Role's #alerts lines
# (TV_SLACK_WEBHOOK in main.tf). The Secret keeps the name `tv-guard-secrets`
# and this resource keeps its address: it was created for the hourly
# source-guard CronJob (tv-source-guard.tf), which tv plan
# 2026-11-01-f1-channels-build retired in favour of the Watcher's calendar gate
# and the daily probe. Renaming either would recreate a Secret three
# Deployments mount, for no change in what it holds.
#
# forgejo_token stays on ci/global, and that is a deliberate choice rather than
# the old default left in place. The obvious move was to hand the filers the
# claude-agent-service agent token, since that account already writes issues.
# It would break the dispatch the issue exists to start: that account IS the
# fixer's bot identity (FIXER_BOT_ACTOR=infra-agent, stacks/claude-agent-service
# /main.tf), and the webhook refuses the bot's own actions before every other
# gate (claude-agent-service/app/fixer/gates.py, `if delivery.actor ==
# bot_actor: return Verdict.OWN_ACTION`). An issue filed with it would be
# delivered, recognised as the bot's own, and never dispatched.
#
# ci/global's token is `viktor`, the repo owner, so it clears both gates the
# webhook applies to the filer: it is not the bot actor, and
# ForgejoClient.trusted_actors() is the collaborator set plus the owner. Scope
# was measured on 2026-09-05: POST to a non-existent issue's comments
# distinguishes the two tokens without writing anything:
#
#   forgejo_repo_token  -> 404 IsErrIssueNotExist   (write:issue present)
#   forgejo_push_token  -> 403 "token does not have at least one of required
#                               scope(s): [write:issue]"
#
# The cost of this choice is that the issues read as filed by Viktor. The
# filers say so in the title marker and the body, and #alerts carries the same
# event, so the audit trail is kept; a dedicated Forgejo account for them would
# be cleaner if one is ever created.
#
# slack_webhook is the shared #alerts incoming webhook, projected here the way
# goldmane-edge-aggregator projects it rather than minted fresh.
resource "kubernetes_manifest" "tv_guard_secrets" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tv-guard-secrets"
      namespace = "tv"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tv-guard-secrets"
      }
      data = [
        {
          # `viktor`: carries write:issue, and is NOT the fixer's bot actor, so
          # an issue the Watcher or the daily probe files survives the
          # webhook's loop guard. See the block comment above before
          # repointing this at the agent account.
          secretKey = "forgejo_token"
          remoteRef = {
            key      = "ci/global"
            property = "forgejo_repo_token"
          }
        },
        {
          # The #alerts incoming webhook (same URL Alertmanager and the
          # goldmane digest post with; no new webhook, no new Slack app).
          secretKey = "slack_webhook"
          remoteRef = {
            key      = "viktor"
            property = "alertmanager_slack_api_url"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.tv]
}
