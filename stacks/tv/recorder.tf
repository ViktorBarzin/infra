# The Recorder (tv docs/design/2026-11-08-recordings.md, ADR
# 2026-11-08-a-recorder-role-writes-recordings).
#
# A fifth Role on the same image, `ROLE=recorder`. It archives every Channel a
# Recording asks for (a Member's request, a learned Habit, or a Member
# watching it), reading through the Edges' Feed paths like the Watcher, so a
# Channel somebody watches costs the upstream nothing extra. It writes the
# segments under /srv/nfs/tv/recordings and indexes them in the viewing
# Postgres; the Edges serve them from their read-only /data mount.
#
# It is the only writer of recordings/, so it mounts just that sub-directory
# read-write. The Worker keeps the rest of /data. The backups leave
# recordings/ out (scripts/nfs-mirror.sh, scripts/offsite-sync-backup.sh):
# they are kept 1 to 7 days and capped at 150 GB, so a copy would only churn
# sda and the Synology.
#
# One replica that rolls with overlap (maxSurge 1, maxUnavailable 0): the new
# pod starts archiving before the old one stops, both write the same segments,
# and the index keeps one row, so a release leaves no gap in a Recording. The
# preStop sleep holds the old pod until the new one has caught up. No GPU and
# no Service: nothing routes to it. Prometheus scrapes it like every app pod
# (job tv), which is where tv_recorder_* come from.
#
# Memory: the full app (about 250 MiB) plus up to 8 Channels archived at once
# and the Watched ones, each holding one segment (a few MB) at a time. 512Mi
# limit, 1Gi during a roll; the quota had about 2.6Gi of limit headroom at the
# deploy peak (2026-11-08).
resource "kubernetes_deployment_v1" "tv_recorder" {
  metadata {
    name      = "tv-recorder"
    namespace = local.tv_namespace
    labels = {
      app  = "tv"
      role = "recorder"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }
    selector {
      match_labels = {
        app  = "tv"
        role = "recorder"
      }
    }
    template {
      metadata {
        labels = {
          app  = "tv"
          role = "recorder"
        }
      }
      spec {
        termination_grace_period_seconds = 60
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
              memory = "192Mi"
            }
            limits = {
              memory = "512Mi"
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
            value = "recorder"
          }
          env {
            name  = "RECORDER_EDGE_BASE"
            value = local.tv_edge_url
          }
          env {
            name  = "RECORDINGS_DIR"
            value = "/data/recordings"
          }
          env {
            name  = "RECORDINGS_CAP_GB"
            value = "150"
          }
          env {
            name = "TV_SLACK_WEBHOOK"
            value_from {
              secret_key_ref {
                name     = "tv-guard-secrets"
                key      = "slack_webhook"
                optional = true
              }
            }
          }
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
          volume_mount {
            name       = "viewing-db"
            mount_path = "/secrets/viewing-db"
            read_only  = true
          }
          # Only recordings/ of the TV share, read-write.
          volume_mount {
            name       = "data"
            mount_path = "/data/recordings"
            sub_path   = "recordings"
          }
          lifecycle {
            pre_stop {
              exec {
                command = ["sleep", "20"]
              }
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
