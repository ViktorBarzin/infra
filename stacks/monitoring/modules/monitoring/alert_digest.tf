# =============================================================================
# Daily alert digest -> #alerts Slack
# =============================================================================
# Companion to the "alert on change" routing model (alert-noise-reduction
# 2026-06-12). Warning/info alerts no longer re-notify while they stay firing
# (repeat_interval is effectively off) and criticals only re-ping every 6h, so
# Slack reflects *changes*, not steady state. This CronJob is the safety net:
# once a day it posts the full current board of firing alerts grouped by
# severity (+ what cleared in the last 24h) so the standing state is reviewed
# on a schedule, the way the #security lane is skimmed daily.
#
# Implementation: stock python:3.12-alpine running a pure-stdlib script
# (alert_digest.py, mounted from a ConfigMap). NO pip/apk at runtime — once a
# day, zero per-run package-install disk writes (the footprint that got
# status-page-pusher disabled, memory id=559). Queries the in-cluster
# Alertmanager v2 API for the current board (respects silences + inhibitions)
# and Prometheus for the resolved-in-24h line.
# =============================================================================

resource "kubernetes_config_map" "alert_digest_script" {
  metadata {
    name      = "alert-digest-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "alert_digest.py" = file("${path.module}/alert_digest.py")
  }
}

# Reuses the same Slack incoming-webhook the Alertmanager receivers post with
# (var.alertmanager_slack_api_url) — no new webhook, just a namespaced Secret so
# the URL isn't a literal in the pod spec.
resource "kubernetes_secret" "alert_digest" {
  metadata {
    name      = "alert-digest"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  type = "Opaque"
  data = {
    SLACK_WEBHOOK_URL = var.alertmanager_slack_api_url
  }
}

resource "kubernetes_cron_job_v1" "alert_digest" {
  metadata {
    name      = "alert-digest"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "alert-digest"
      tier = var.tier
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "0 8 * * *"
    timezone                      = "Europe/London"
    starting_deadline_seconds     = 600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "alert-digest"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "alert-digest"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/alert_digest.py"]
              env {
                name = "SLACK_WEBHOOK_URL"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret.alert_digest.metadata[0].name
                    key  = "SLACK_WEBHOOK_URL"
                  }
                }
              }
              env {
                name  = "SLACK_CHANNEL"
                value = "#alerts"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "96Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.alert_digest_script.metadata[0].name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
