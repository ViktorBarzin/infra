# f1-stream source-guard — autonomous upstream-link self-healing.
#
# The community aggregators f1-stream extracts from rotate their hosts/paths
# (dead domains, TLD hops, legal-takedown relocations); the extractor constants
# are baked into the image, so a rotation silently breaks a source until it's
# repointed + redeployed — usually discovered mid-session. This CronJob runs the
# app's own `backend.guard` on a schedule: it probes each registered extractor's
# upstream (session-independent) and, on a dead link, dispatches the autonomous
# `f1-source-fixer` agent (claude-agent-service) to repoint + test + ship + verify.
# Design + env contract: f1-stream repo docs/source-guard.md.

# Pull the claude-agent-service bearer token + the Forgejo read token into this
# namespace. (The Slack webhook is optional and rides the existing
# f1-stream-secrets ExternalSecret — add key `guard_slack_webhook` to Vault
# `secret/f1-stream` to enable notifications; until then the guard just logs.)
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
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "f1-stream-guard-secrets"
      }
      data = [
        {
          secretKey = "agent_bearer_token"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
        {
          secretKey = "forgejo_token"
          remoteRef = {
            key      = "ci/global"
            property = "forgejo_push_token"
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
    # Every 6h. The run is a cheap curl+probe when healthy (exits in seconds);
    # only a genuinely-broken link dispatches the agent (and then the pod waits
    # for the fix job, hence the generous active_deadline below).
    schedule                      = "0 */6 * * *"
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
        backoff_limit              = 1
        active_deadline_seconds    = 3300 # covers the guard waiting on a ≤45m fix job
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
              # thus source_health) matches production. :latest + Always pull —
              # a CronJob spawns a fresh pod each run.
              image             = "ghcr.io/viktorbarzin/f1-stream:latest"
              image_pull_policy = "Always"
              command           = ["python", "-m", "backend.guard"]

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "256Mi"
                }
                limits = {
                  memory = "384Mi"
                }
              }

              # Fully autonomous per Viktor's choice (2026-07-25): a dead link is
              # fixed + pushed + deployed without human approval. Flip
              # GUARD_DRY_RUN=true for training-wheels (fix on a branch + PR only).
              env {
                name  = "GUARD_DRY_RUN"
                value = "false"
              }
              env {
                name  = "GUARD_ATTEMPT_CAP"
                value = "2"
              }
              env {
                name  = "GUARD_COOLDOWN_HOURS"
                value = "12"
              }
              env {
                name = "GUARD_AGENT_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "f1-stream-guard-secrets"
                    key  = "agent_bearer_token"
                  }
                }
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
              # Optional — enable Slack notifications by adding key
              # `guard_slack_webhook` to Vault secret/f1-stream (auto-syncs via the
              # existing f1-stream-secrets ExternalSecret). Until then: logs only.
              env {
                name = "GUARD_SLACK_WEBHOOK"
                value_from {
                  secret_key_ref {
                    name     = "f1-stream-secrets"
                    key      = "guard_slack_webhook"
                    optional = true
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
