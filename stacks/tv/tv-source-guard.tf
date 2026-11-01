# tv source-guard — playback verification and fault filing.
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
# Design: tv repo docs/playback-guard.md (supersedes the trigger and
# dispatch halves of docs/source-guard.md; the per-source source_health() check
# it describes still runs inside the app).

# Credentials the guard needs in this namespace.
#
# forgejo_token stays on ci/global, and that is a deliberate choice rather than
# the old default left in place. The obvious move was to hand the guard the
# claude-agent-service agent token, since that account already writes issues.
# It would have broken the dispatch it exists to start: that account IS the
# fixer's bot identity (FIXER_BOT_ACTOR=infra-agent, stacks/claude-agent-service
# /main.tf), and the webhook refuses the bot's own actions before every other
# gate — claude-agent-service/app/fixer/gates.py:112,
# `if delivery.actor == bot_actor: return Verdict.OWN_ACTION`. A guard-filed
# issue would be delivered, recognised as the bot's own, and never dispatched by
# the webhook.
#
# ci/global's token is `viktor`, the repo owner, so it clears both gates the
# webhook applies to the filer: it is not the bot actor, and
# ForgejoClient.trusted_actors() is the collaborator set plus the owner. Scope
# was measured on 2026-09-05 rather than assumed — the earlier comment here
# called this token read-only, which is true of its repository scope and not of
# its issue scope. POST to a non-existent issue's comments distinguishes the two
# without writing anything:
#
#   forgejo_repo_token  -> 404 IsErrIssueNotExist   (write:issue present)
#   forgejo_push_token  -> 403 "token does not have at least one of required
#                               scope(s): [write:issue]"
#
# The cost of this choice is that the issue reads as filed by Viktor. The guard
# says so in the title marker and the body, and #alerts carries the same event,
# so the audit trail is not lost — but a dedicated `f1-guard` Forgejo account
# would be cleaner if one is ever created.
#
# slack_webhook is the shared #alerts incoming webhook, projected here the way
# goldmane-edge-aggregator projects it rather than minted fresh. The guard's
# Slack path existed before this change but no webhook was ever configured, so
# three failed repair runs on 2026-09-05 degraded to logger.info and reached
# nobody.
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
          # `viktor` — carries write:issue, and is NOT the fixer's bot actor, so
          # a guard-filed issue survives the webhook's loop guard. See the block
          # comment above before repointing this at the agent account.
          secretKey = "forgejo_token"
          remoteRef = {
            key      = "ci/global"
            property = "forgejo_repo_token"
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
  depends_on = [kubernetes_namespace.tv]
}

resource "kubernetes_cron_job_v1" "tv_source_guard" {
  metadata {
    name      = "tv-source-guard"
    namespace = kubernetes_namespace.tv.metadata[0].name
    labels = {
      app  = "tv-source-guard"
      tier = local.tiers.aux
    }
  }
  spec {
    # Hourly, but the run itself is calendar-gated: tv.guard reads
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
          app = "tv-source-guard"
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
              app = "tv-source-guard"
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
              image             = "ghcr.io/viktorbarzin/tv:latest"
              image_pull_policy = "Always"
              # The guard module moved with the package rename (backend -> tv,
              # f1-stream plan 2026-11-01-tv-rebrand). The version gate that
              # used to wrap this (an import probe of backend.chrome_fleet,
              # expired 2026-09-13) is gone: every image on ghcr.io/viktorbarzin/tv
              # carries the guard, and an old probe would fail on the new
              # package name.
              command = ["python", "-m", "tv.guard"]

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
              # re-originates from a tv Edge, so the token stays valid
              # whichever node the leased browser sits on. The code default is
              # 127.0.0.1:8000, which is right for the app's in-process use and
              # wrong here — a cron pod runs no FastAPI, so an unset value would
              # send every playback attempt at nothing and read as a dead source.
              env {
                name  = "PLAYBACK_VERIFY_PROXY_BASE"
                value = "http://tv.tv.svc.cluster.local"
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
                value = "http://tv.tv.svc.cluster.local/api/schedule"
              }
              # The source history the guard reads before filing, from /metrics.
              # Straight at the Worker since ADR-0029 (tv repo): only the
              # Worker extracts, so only its exposition carries the per-source
              # extraction families, and the `tv` Service reaches an Edge. The
              # app's default is the `tv` Service, which is right only for the
              # single pre-ADR-0029 Deployment. /api/schedule above stays on `f1`,
              # which any Edge answers.
              env {
                name  = "GUARD_METRICS_URL"
                value = "${local.tv_worker_url}/metrics"
              }
              # Faults are filed against the infra tracker, where the
              # broken-label webhook and issue-responder already live — not
              # against viktor/tv, which the old GUARD_REPO pointed at
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
                    name = "tv-guard-secrets"
                    key  = "forgejo_token"
                  }
                }
              }
              # The guard's share of #alerts: a fault filed, a check that could
              # not run (no browser leased — every source then looks dead and
              # none of that is evidence), and a filing that failed. Not
              # optional any more: an unset webhook is what made the last set of
              # failures invisible.
              #
              # docs/playback-guard.md names three events, and the other two —
              # a repair landed, and a repair that failed or could not run — are
              # deliberately NOT here. The old guard blocked on the job it
              # dispatched and reported the outcome itself; this one files an
              # issue and exits, so it is not around when the repair finishes
              # and has nothing to report. Those two events belong to the actor
              # that observes recovery, which is f1-source-fixer — the same
              # reason closing the issue is its job. They are wired in
              # .claude/agents/f1-source-fixer.md, "Telling a person", off the
              # same webhook read from Vault. Do not add a poll back here to
              # recover them.
              env {
                name = "GUARD_SLACK_WEBHOOK"
                value_from {
                  secret_key_ref {
                    name = "tv-guard-secrets"
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
    kubernetes_manifest.tv_guard_secrets,
    kubernetes_manifest.external_secret,
  ]
}
