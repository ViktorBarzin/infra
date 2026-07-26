# =============================================================================
# Daily proxy-visit digest -> #alerts Slack (spec infra#83)
# =============================================================================
# Once a day, summarises which sites each proxy.viktorbarzin.me user visited
# (per-user domain counts) and posts to #alerts — ACTIVITY-ONLY, excluding the
# operator's own account. Full per-URL detail lives in the Grafana "Proxy
# visits" dashboard; this is the scannable daily skim.
#
# Same doctrine as the alert-digest CronJob: stock python:3.12-alpine running a
# pure-stdlib script (proxy_visit_digest.py, ConfigMap-mounted), NO pip at
# runtime. Reads the visit lines the per-user browser pods' visit-collector
# sidecars ship to Loki (see stacks/proxy). Reuses the alert-digest Slack
# webhook secret (same #alerts channel, no new webhook).
# =============================================================================

resource "kubernetes_config_map" "proxy_visit_digest_script" {
  metadata {
    name      = "proxy-visit-digest-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "proxy_visit_digest.py" = file("${path.module}/proxy_visit_digest.py")
  }
}

resource "kubernetes_cron_job_v1" "proxy_visit_digest" {
  metadata {
    name      = "proxy-visit-digest"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "proxy-visit-digest"
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
              app = "proxy-visit-digest"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "proxy-visit-digest"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/proxy_visit_digest.py"]
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
                # The operator's own proxy account — present in the dashboard,
                # excluded from the digest so it doesn't self-report.
                name  = "DIGEST_EXCLUDE_USER"
                value = "vbarzin@gmail.com"
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
                name = kubernetes_config_map.proxy_visit_digest_script.metadata[0].name
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
