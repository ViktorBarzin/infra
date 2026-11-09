# =============================================================================
# Daily DNS digest (London + Sofia) -> #alerts Slack
# =============================================================================
# Once a day, checks the last 24 h of DNS lookups at both sites against HaGeZi's
# Threat Intelligence Feeds list and posts matches (blocked or not), London DNS
# errors that point at a real problem, GL content-protection blocks, and hours
# in which a query log recorded nothing. Posts nothing on a quiet day.
# London lookups come from the Flint's dnsmasq log in Loki; Sofia's from
# Technitium's Postgres query log (dns_logs), read with psql.
#
# Replaced london-dns-digest on 2026-11-04. Its "newly blocked by AdGuard"
# section listed 300-760 names a day, almost all ad and tracker names, and is
# gone (Viktor). History: docs/plans/2026-10-02-london-dns-block-monitoring.md.
#
# job-runtime has python3 and psql baked in, so nothing installs at runtime.
# The script is ConfigMap-mounted (tests: python3 dns_digest_test.py).
# Each successful run PUTs dns_digest_* to the Pushgateway; the DNSDigestStale
# and DNSDigestBlind alerts (prometheus_chart_values.tpl) fire if it stops.
# The HaGeZi list is about 1.8M names; the run peaks at about 210 MB.
# =============================================================================

resource "kubernetes_config_map" "dns_digest_script" {
  metadata {
    name      = "dns-digest-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "dns_digest.py" = file("${path.module}/dns_digest.py")
  }
}

resource "kubernetes_cron_job_v1" "dns_digest" {
  metadata {
    name      = "dns-digest"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "dns-digest"
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
        # 4 retries: the wait below is skipped if Kyverno itself is down.
        backoff_limit              = 4
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "dns-digest"
            }
            # A host restart on 2026-10-23 ran the London digest while Loki was
            # still starting, and it failed. Kyverno injects a wait-for init
            # container, so the pod waits for Loki and the Pushgateway instead.
            annotations = {
              "dependency.kyverno.io/wait-for" = "loki.monitoring:3100,prometheus-prometheus-pushgateway.monitoring:9091"
            }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name              = "dns-digest"
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/scripts/dns_digest.py"]
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
                name  = "PUSHGATEWAY_URL"
                value = "http://prometheus-prometheus-pushgateway.monitoring:9091"
              }
              env {
                name  = "PGHOST"
                value = var.postgresql_host
              }
              env {
                name  = "PGUSER"
                value = "technitium"
              }
              env {
                name  = "PGDATABASE"
                value = "technitium"
              }
              env {
                # Vault static role pg-technitium, synced by the
                # grafana-technitium-pg-creds ExternalSecret (technitium stack).
                # Read once at pod start; the Tuesday rotation is outside 08:00.
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "grafana-technitium-pg-creds"
                    key  = "TECHNITIUM_PG_PASSWORD"
                  }
                }
              }
              env {
                name  = "SOFIA_INSTANCES"
                value = "technitium,technitium-secondary,technitium-tertiary"
              }
              env {
                # Secondary and tertiary started logging on 2026-11-04; hours
                # before this are not reported as gaps.
                name  = "COVERAGE_START"
                value = "2026-11-04T16:00:00Z"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "20m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "384Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.dns_digest_script.metadata[0].name
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
