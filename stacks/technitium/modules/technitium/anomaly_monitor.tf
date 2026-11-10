# DNS anomaly monitor: Technitium's last-hour dashboard stats, summed over the
# primary, secondary and tertiary, pushed to the Pushgateway every 30 minutes.
# The alerts on these metrics (DNSQueryRateDropped, DNSHighErrorRate,
# DNSAnomalyMonitorDown/Stale) live in the monitoring stack's
# prometheus_chart_values.tpl, group "DNS Anomaly Detection".
#
# Moved here from the monitoring stack on 2026-11-04, where it had reported 0
# for at least 180 days: it called /api/stats/get (removed; the path is now
# /api/dashboard/stats/get) with an empty token, and jq turned the
# "invalid-token" reply into zeros. It now logs in, reads every instance, and
# pushes dns_anomaly_up=0 when it cannot, so a broken monitor raises an alert
# instead of reporting a quiet network. The old top-domains "DGA" heuristic is
# gone; the daily dns-digest checks every name against a threat feed instead.

resource "kubernetes_cron_job_v1" "dns_anomaly_monitor" {
  metadata {
    name      = "dns-anomaly-monitor"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "*/30 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name = "dns-anomaly-monitor"
              # job-runtime (images/job-runtime) has curl and jq baked in.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              dynamic "env" {
                for_each = toset(["TECH_USER", "TECH_PASS"])
                content {
                  name = env.value
                  value_from {
                    secret_key_ref {
                      name = kubernetes_secret_v1.technitium_api.metadata[0].name
                      key  = env.value
                    }
                  }
                }
              }
              command = ["/bin/sh", "-c", <<-EOT
                set -u
                INSTANCES="http://technitium-web:5380 http://technitium-secondary-web:5380 http://technitium-tertiary-web:5380"
                PUSHGW="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/dns-anomaly-monitor"
                TOTAL=0; SERVFAIL=0; NXDOMAIN=0; BLOCKED=0; NOERROR=0; UP=0; N=0

                for I in $$INSTANCES; do
                  N=$$((N + 1))
                  T=$$(curl -sf "$$I/api/user/login" --data-urlencode "user=$$TECH_USER" --data-urlencode "pass=$$TECH_PASS" | jq -r '.token // empty')
                  if [ -z "$$T" ]; then echo "ERROR: cannot log in to $$I"; continue; fi
                  S=$$(curl -sf "$$I/api/dashboard/stats/get?token=$$T&type=LastHour" | jq -c 'select(.status == "ok") | .response.stats')
                  curl -sf "$$I/api/user/logout?token=$$T" >/dev/null || true
                  if [ -z "$$S" ]; then echo "ERROR: no stats from $$I"; continue; fi
                  UP=$$((UP + 1))
                  TOTAL=$$((TOTAL + $$(printf '%s' "$$S" | jq '.totalQueries')))
                  SERVFAIL=$$((SERVFAIL + $$(printf '%s' "$$S" | jq '.totalServerFailure')))
                  NXDOMAIN=$$((NXDOMAIN + $$(printf '%s' "$$S" | jq '.totalNxDomain')))
                  BLOCKED=$$((BLOCKED + $$(printf '%s' "$$S" | jq '.totalBlocked')))
                  NOERROR=$$((NOERROR + $$(printf '%s' "$$S" | jq '.totalNoError')))
                  echo "$$I: $$(printf '%s' "$$S" | jq -c '{totalQueries, totalServerFailure, totalNxDomain, totalBlocked}')"
                done
                ALL_UP=0; [ "$$UP" -eq "$$N" ] && ALL_UP=1
                echo "last hour, all instances: total=$$TOTAL noError=$$NOERROR nxDomain=$$NXDOMAIN serverFailure=$$SERVFAIL blocked=$$BLOCKED ($$UP of $$N instances read)"

                # PUT replaces the whole group, which also drops the retired
                # dns_anomaly_dga_suspects / dns_anomaly_avg_queries series.
                # The volume gauges are pushed only when every instance answered,
                # so a partial read cannot look like a traffic drop.
                {
                  echo "# TYPE dns_anomaly_up gauge"
                  echo "dns_anomaly_up $$ALL_UP"
                  echo "# TYPE dns_anomaly_instances_up gauge"
                  echo "dns_anomaly_instances_up $$UP"
                  echo "# TYPE dns_anomaly_check_timestamp gauge"
                  echo "dns_anomaly_check_timestamp $$(date +%s)"
                  if [ "$$ALL_UP" -eq 1 ]; then
                    echo "# TYPE dns_anomaly_total_queries gauge"
                    echo "dns_anomaly_total_queries $$TOTAL"
                    echo "# TYPE dns_anomaly_server_failure gauge"
                    echo "dns_anomaly_server_failure $$SERVFAIL"
                    echo "# TYPE dns_anomaly_nx_domain gauge"
                    echo "dns_anomaly_nx_domain $$NXDOMAIN"
                    echo "# TYPE dns_anomaly_blocked gauge"
                    echo "dns_anomaly_blocked $$BLOCKED"
                    echo "# TYPE dns_anomaly_no_error gauge"
                    echo "dns_anomaly_no_error $$NOERROR"
                  fi
                } | curl -sf -X PUT --data-binary @- "$$PUSHGW" >/dev/null || { echo "ERROR: pushgateway push failed"; exit 1; }
                [ "$$ALL_UP" -eq 1 ] || exit 1
              EOT
              ]
              resources {
                requests = {
                  memory = "32Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "64Mi"
                }
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
