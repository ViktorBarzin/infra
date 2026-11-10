# =============================================================================
# Weekly Trivy summary -> #alerts Slack (historical name: alert-digest)
# =============================================================================
# Until 2026-11-10 this posted the full board of firing alerts every morning,
# the safety net for alert-on-change routing (2026-06-12). Since notify=page
# routing (docs/plans/2026-07-26-alert-noise-reduction-design.md) only alerts
# that mean something is broken reach Slack, and the rest are visible in
# /cluster-health and Grafana, so the daily board was dropped. What remains
# is the weekly Trivy section (docs/architecture/trivy.md), posted Mondays.
# alert_digest.py can still build the board when ALERT_BOARD is not "off".
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
    # Weekly, Trivy section only (ALERT_BOARD=off below). The daily board of
    # every firing alert went away 2026-11-10 with notify=page routing:
    # docs/plans/2026-07-26-alert-noise-reduction-design.md.
    schedule                  = "0 8 * * 1"
    timezone                  = "Europe/London"
    starting_deadline_seconds = 600
    job_template {
      metadata {}
      spec {
        # 4 retries: the wait below is skipped if Kyverno itself is down.
        backoff_limit              = 4
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "alert-digest"
            }
            # A host restart on 2026-10-23 ran this while Alertmanager and DNS
            # were still starting, and it failed. Kyverno injects a wait-for
            # init container per entry, so the pod waits for them instead.
            annotations = {
              "dependency.kyverno.io/wait-for" = "prometheus-alertmanager.monitoring:9093,prometheus-server.monitoring:80"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "alert-digest"
              image             = "docker.io/library/python:3.15-alpine"
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
              # Weekly Trivy section (alert_digest.py, docs/architecture/trivy.md):
              # appended on this weekday's 08:00 run. "never" turns it off.
              env {
                name  = "TRIVY_WEEKDAY"
                value = "Mon"
              }
              env {
                name  = "ALERT_BOARD"
                value = "off"
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
