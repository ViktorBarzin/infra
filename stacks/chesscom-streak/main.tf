# =============================================================================
# chesscom-streak — keep Viktor's Chess.com activity streak alive while he is
# not playing, by solving the unrated Daily Puzzle once a day.
#
# Design: docs/plans/2026-08-08-chesscom-streak-automation.md
# Code:   ~/code/chesscom-streak (ghcr.io/viktorbarzin/chesscom-streak)
#
# How it works: the job connects over CDP to the shared cluster Chrome and
# attaches to its MASTER PERSISTENT PROFILE, where Viktor's chess.com session
# already lives (he logged in by hand via noVNC). It never logs in, so it never
# meets Cloudflare Turnstile. The solution comes from chess.com's own public
# api.chess.com/pub/puzzle, so no engine is involved and no rating moves.
#
# PREREQUISITE: the "chesscom-streak" namespace MUST be in the ghcr-credentials
# Kyverno allowlist (stacks/kyverno/modules/kyverno/ghcr-credentials.tf,
# local.ghcr_private_namespaces) or the image pull 401s.
# =============================================================================

locals {
  name  = "chesscom-streak"
  image = "ghcr.io/viktorbarzin/chesscom-streak:latest"

  labels = {
    app = local.name
  }
}

resource "kubernetes_namespace_v1" "chesscom_streak" {
  metadata {
    name = local.name
    labels = {
      name = local.name
      # Tier 4-aux: a tiny, off-path scheduled job.
      tier = local.tiers.aux
      # Admits this namespace through chrome-service's CDP NetworkPolicy
      # (chrome-service-ws-ingress) — without it the CDP dial is dropped.
      "chrome-service.viktorbarzin.me/client" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# Daily run
# -----------------------------------------------------------------------------
# Hourly across a midday window rather than a single shot. The streak's
# day-boundary timezone is undocumented, and 12:00–16:00 Europe/Sofia sits
# comfortably mid-day whether that boundary is Pacific, UTC, or account-local —
# at least ~10h of margin under every hypothesis.
#
# The first run of the window solves the puzzle; every later run finds it
# already solved and exits without acting, which is exactly the retry safety net
# Viktor asked for. JITTER_SECONDS spreads the actual start off the exact hour.
resource "kubernetes_cron_job_v1" "solve" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.chesscom_streak.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "0 12-16 * * *"
    timezone                      = "Europe/Sofia"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 2
        active_deadline_seconds    = 2700
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy = "Never"

            image_pull_secrets {
              name = "ghcr-credentials"
            }

            container {
              name              = "solve"
              image             = local.image
              image_pull_policy = "Always"

              env {
                name  = "CDP_URL"
                value = "http://chrome-service.chrome-service.svc.cluster.local:9222"
              }
              env {
                name  = "CHESSCOM_USERNAME"
                value = "viktorbarzin"
              }
              # Runtime off-switch: set to anything but "true" and every run is a
              # no-op. Flip this when Viktor is back to playing daily.
              env {
                name  = "ENABLED"
                value = "true"
              }
              # Up to 25 minutes of spread so the hit is not on the exact hour.
              env {
                name  = "JITTER_SECONDS"
                value = "1500"
              }

              resources {
                requests = {
                  cpu    = "25m"
                  memory = "96Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }

              security_context {
                allow_privilege_escalation = false
                run_as_non_root            = true
                capabilities {
                  drop = ["ALL"]
                }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno injects dns_config on pod CREATE
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
