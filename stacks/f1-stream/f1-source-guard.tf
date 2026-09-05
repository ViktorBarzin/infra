# f1-stream source-guard — playback verification and fault filing.
#
# The community aggregators f1-stream extracts from break in two distinct ways.
# They rotate hosts and paths (dead domains, TLD hops, legal-takedown
# relocations), and they rotate how the embed page hides the playlist URL. The
# first is a constant in the image; the second needs new decoding logic. Both
# silently produce zero streams until someone notices mid-session.
#
# The earlier version of this CronJob probed each extractor's upstream for
# reachability and dispatched a repair agent over claude-agent-service /execute.
# That check sits one layer above where the September 2026 break happened:
# aceztrims answered 200 and still carried an iframe while returning no
# playable stream for ten days. So this job now runs the whole chain — extract,
# resolve, and actually play the m3u8 in a browser — and files a Forgejo issue
# rather than dispatching directly.
#
# Design: f1-stream repo docs/playback-guard.md (supersedes the trigger and
# dispatch halves of docs/source-guard.md; the per-source source_health() check
# it describes still runs inside the app).

# Credentials the guard needs in this namespace.
#
# forgejo_token is now the claude-agent-service agent account rather than
# ci/global's read-only repo token: the guard files and comments on issues, and
# the old token has read scope only (it existed to count auto-fix commits for a
# cooldown that no longer runs). This is the same account issue-responder
# already writes issues with.
#
# slack_webhook is the shared #alerts incoming webhook, projected here the way
# goldmane-edge-aggregator projects it rather than minted fresh. The guard's
# Slack path existed before this change but no webhook was ever configured, so
# three failed repair runs on 2026-09-05 degraded to logger.info and reached
# nobody.
resource "kubernetes_manifest" "f1_stream_guard_secrets" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "f1-stream-guard-secrets"
      namespace = "f1-stream"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-guard-secrets"
      }
      data = [
        {
          # Write-scoped: the guard opens issues and comments on them.
          secretKey = "forgejo_token"
          remoteRef = {
            key      = "claude-agent-service"
            property = "forgejo_agent_token"
          }
        },
        {
          # The #alerts incoming webhook (same URL Alertmanager and the
          # goldmane digest post with — no new webhook, no new Slack app).
          secretKey = "slack_webhook"
          remoteRef = {
            key      = "viktor"
            property = "alertmanager_slack_api_url"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.f1-stream]
}

resource "kubernetes_cron_job_v1" "f1_stream_source_guard" {
  metadata {
    name      = "f1-stream-source-guard"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
    labels = {
      app  = "f1-stream-source-guard"
      tier = local.tiers.aux
    }
  }
  spec {
    # Hourly, but the run itself is calendar-gated: backend.guard reads
    # /api/schedule and returns within a second unless the next session falls
    # inside the T-2h or T-30m band. Hourly is what makes those bands reachable
    # — they are bands rather than instants precisely because a cron tick lands
    # on the hour and a session start does not. The cost of a tick outside a
    # window is one short-lived pod.
    schedule                      = "0 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = {
          app = "f1-stream-source-guard"
        }
      }
      spec {
        backoff_limit = 1
        # Was 3300, sized for the guard blocking on a fix job it dispatched.
        # It no longer waits for anything: the longest run is one extraction
        # plus one 45s playback attempt per registered source, then an issue
        # POST. 900 leaves several times that.
        active_deadline_seconds    = 900
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = {
              app = "f1-stream-source-guard"
            }
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            # Private ghcr image (ADR-0002) — cloned into this namespace by the
            # kyverno sync-ghcr-credentials allowlist policy.
            image_pull_secrets {
              name = "ghcr-credentials"
            }

            container {
              name = "guard"
              # Runs the SAME image as the Deployment so its extractor code (and
              # thus the playback chain it exercises) matches production.
              # :latest + Always pull — a CronJob spawns a fresh pod each run.
              image             = "ghcr.io/viktorbarzin/f1-stream:latest"
              image_pull_policy = "Always"
              command           = ["python", "-m", "backend.guard"]

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "256Mi"
                }
                limits = {
                  # Was 384Mi, when the run was httpx calls only. It now drives
                  # a remote page session through the Playwright python client,
                  # which starts a second long-lived Node driver process — the
                  # app Deployment measured that pair at ~377MB against a 384Mi
                  # ceiling and OOMKilled hourly (see main.tf). The browser
                  # itself runs in the leased chrome worker, not here.
                  memory = "768Mi"
                }
              }

              # The chrome-fleet broker. This is a LEASE endpoint, not a CDP
              # endpoint: the guard POSTs /acquire, gets back a worker pod IP,
              # dials CDP on that IP:9222, and POSTs /release when done. Setting
              # CHROME_CDP_URL to this address would not work — :8080 answers
              # /json/version with the FleetView HTML page (measured
              # 2026-09-05). The per-run worker URL cannot be a static env var,
              # so the guard injects it into PlaybackVerifier itself.
              env {
                name  = "CHROME_FLEET_URL"
                value = "http://chrome-fleet.chrome-service.svc.cluster.local:8080"
              }
              # Playback goes through our own /proxy, never straight at the CDN:
              # the videocdn token is bound to the requesting IP, and /proxy
              # re-originates from the f1-stream pod, so the token stays valid
              # whichever node the leased browser sits on. The code default is
              # 127.0.0.1:8000, which is right for the app's in-process use and
              # wrong here — a cron pod runs no FastAPI, so an unset value would
              # send every playback attempt at nothing and read as a dead source.
              env {
                name  = "PLAYBACK_VERIFY_PROXY_BASE"
                value = "http://f1.f1-stream.svc.cluster.local"
              }
              # Set explicitly: when the verifier is disabled it returns
              # is_playable=true with error="disabled", so an accidental false
              # here would report every source healthy forever.
              env {
                name  = "PLAYBACK_VERIFY_ENABLED"
                value = "true"
              }
              # Per-source playback budget. Time-to-first-frame was measured at
              # under 2s to 17s depending on how warm the upstream segments are,
              # so 45s is clear headroom above the worst observed case.
              env {
                name  = "GUARD_PLAYBACK_BUDGET_SECONDS"
                value = "45"
              }
              # The calendar the window gate reads. In-cluster, so it never goes
              # through Anubis. NB `/api/schedule` is the JSON route; `/schedule`
              # is the SPA's HTML page and would parse as an empty calendar,
              # which the gate reads as "no window" — i.e. a permanently quiet
              # guard. Verified 2026-09-05: /api/schedule returns 18,677 bytes
              # of season JSON, /schedule returns 1,504 bytes of HTML.
              env {
                name  = "GUARD_SCHEDULE_URL"
                value = "http://f1.f1-stream.svc.cluster.local/api/schedule"
              }
              # Faults are filed against the infra tracker, where the
              # broken-label webhook and issue-responder already live — not
              # against viktor/f1-stream, which the old GUARD_REPO pointed at
              # only to count commit trailers.
              env {
                name  = "GUARD_ISSUE_REPO"
                value = "viktor/infra"
              }
              env {
                name  = "GUARD_FORGEJO_API"
                value = "https://forgejo.viktorbarzin.me/api/v1"
              }
              env {
                name = "GUARD_FORGEJO_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "f1-stream-guard-secrets"
                    key  = "forgejo_token"
                  }
                }
              }
              # Three events reach #alerts: a fault filed, a check that could
              # not run (no browser leased — every source then looks dead and
              # none of that is evidence), and a filing that failed. Not
              # optional any more: an unset webhook is what made the last set of
              # failures invisible.
              env {
                name = "GUARD_SLACK_WEBHOOK"
                value_from {
                  secret_key_ref {
                    name = "f1-stream-guard-secrets"
                    key  = "slack_webhook"
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }

  depends_on = [
    kubernetes_manifest.f1_stream_guard_secrets,
    kubernetes_manifest.external_secret,
  ]
}
