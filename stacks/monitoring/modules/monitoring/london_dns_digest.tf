# =============================================================================
# Daily London DNS digest -> #alerts Slack
# =============================================================================
# Once a day, reads the London Flint's dnsmasq query log from Loki and posts
# DNS errors (SERVFAIL/REFUSED, dnsmasq's concurrent-query limit), names newly
# blocked by AdGuard (after a 7-day learning window), and GL content-protection
# blocks, per device. Posts nothing on a day with nothing to report.
# Design: docs/plans/2026-10-02-london-dns-block-monitoring.md.
#
# Same doctrine as the alert-digest and proxy-visit-digest CronJobs: stock
# python:3.12-alpine running a pure-stdlib script (london_dns_digest.py,
# ConfigMap-mounted, tests in london_dns_digest_test.py), NO pip at runtime.
# Reuses the alert-digest Slack webhook secret (same #alerts channel).
# =============================================================================

resource "kubernetes_config_map" "london_dns_digest_script" {
  metadata {
    name      = "london-dns-digest-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "london_dns_digest.py" = file("${path.module}/london_dns_digest.py")
  }
}

resource "kubernetes_cron_job_v1" "london_dns_digest" {
  metadata {
    name      = "london-dns-digest"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "london-dns-digest"
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
              app = "london-dns-digest"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "london-dns-digest"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/london_dns_digest.py"]
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
              env {
                # When provision.sh turned the Flint's query log on. The
                # newly-blocked section stays empty for 7 days after this.
                name  = "LOG_START"
                value = "2026-10-02T16:10:00Z"
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
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.london_dns_digest_script.metadata[0].name
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
