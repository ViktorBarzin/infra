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
