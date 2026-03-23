variable "tls_secret_name" {}
variable "alertmanager_account_password" {}
variable "idrac_host" {
  default = "192.168.1.4"
}
variable "idrac_username" {
  default = "root"
}
variable "idrac_password" {
  default   = "calvin"
  sensitive = true
}
variable "alertmanager_slack_api_url" {}
variable "tiny_tuya_service_secret" {
  type      = string
  sensitive = true
}
variable "haos_api_token" {
  type      = string
  sensitive = true
}
variable "pve_password" {
  type      = string
  sensitive = true
}
variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
variable "tier" { type = string }
variable "mysql_host" { type = string }
variable "truenas_api_key" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "istio-injection" : "disabled"
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.monitoring.metadata[0].name
  tls_secret_name = var.tls_secret_name
}
# Terraform get angry with the 30k values file :/ use ansible until solved
# resource "helm_release" "ups_prometheus_snmp_exporter" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "ups_prometheus_exporter"

#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-snmp-exporter"

#   values = [file("${path.module}/ups_snmp_values.yaml")]
# }



resource "kubernetes_cron_job_v1" "monitor_prom" {
  metadata {
    name = "monitor-prometheus"
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "*/30 * * * *"
    job_template {
      metadata {

      }
      spec {
        template {
          metadata {

          }
          spec {
            container {
              name    = "monitor-prometheus"
              image   = "alpine"
              command = ["/bin/sh", "-c", "apk add --update curl && curl --connect-timeout 2 prometheus-server.monitoring.svc.cluster.local || curl https://webhook.viktorbarzin.me/fb/message-viktor -d 'Prometheus is down!'"]
            }
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Cloud Sync Monitor — check TrueNAS Cloud Sync job status, push to Pushgateway
# Runs every 6h. Alert fires if no successful sync in 8 days.
# -----------------------------------------------------------------------------
resource "kubernetes_cron_job_v1" "cloudsync_monitor" {
  metadata {
    name      = "cloudsync-monitor"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "0 */6 * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "cloudsync-monitor"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euo pipefail
                apk add --no-cache curl jq

                # Query TrueNAS Cloud Sync tasks
                RESPONSE=$(curl -sf -H "Authorization: Bearer $TRUENAS_API_KEY" \
                  "http://10.0.10.15/api/v2.0/cloudsync" 2>&1) || {
                  echo "ERROR: Failed to query TrueNAS API"
                  exit 1
                }

                # Parse each task's last successful run
                echo "$RESPONSE" | jq -c '.[]' | while read -r task; do
                  TASK_ID=$(echo "$task" | jq -r '.id')
                  TASK_DESC=$(echo "$task" | jq -r '.description // "task-\(.id)"' | tr ' ' '_' | tr -cd '[:alnum:]_-')
                  JOB_STATE=$(echo "$task" | jq -r '.job.state // "UNKNOWN"')
                  JOB_TIME=$(echo "$task" | jq -r '.job.time_finished."$date" // 0')

                  if [ "$JOB_TIME" != "0" ] && [ "$JOB_TIME" != "null" ]; then
                    # TrueNAS returns milliseconds since epoch
                    EPOCH_SECS=$((JOB_TIME / 1000))
                  else
                    EPOCH_SECS=0
                  fi

                  # Extract transfer stats from job progress description (rclone output)
                  JOB_PROGRESS=$(echo "$task" | jq -r '.job.progress.description // ""')
                  BYTES_TX=$(echo "$JOB_PROGRESS" | grep -oP 'Transferred:\s+[\d.]+ \w+' | head -1 | awk '{print $2}' || echo 0)
                  JOB_STARTED=$(echo "$task" | jq -r '.job.time_started."$date" // 0')
                  JOB_FINISHED=$(echo "$task" | jq -r '.job.time_finished."$date" // 0')
                  if [ "$JOB_STARTED" != "0" ] && [ "$JOB_STARTED" != "null" ] && [ "$JOB_FINISHED" != "0" ] && [ "$JOB_FINISHED" != "null" ]; then
                    SYNC_DURATION=$(( (JOB_FINISHED - JOB_STARTED) / 1000 ))
                  else
                    SYNC_DURATION=0
                  fi

                  echo "Task $TASK_ID ($TASK_DESC): state=$JOB_STATE, last_finished=$EPOCH_SECS, duration=$${SYNC_DURATION}s"

                  # Push metrics to Pushgateway
                  cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/cloudsync-monitor/task_id/$TASK_ID"
                  # HELP cloudsync_last_success_timestamp Last successful Cloud Sync completion (unix epoch)
                  # TYPE cloudsync_last_success_timestamp gauge
                  cloudsync_last_success_timestamp $EPOCH_SECS
                  # HELP cloudsync_job_state Cloud Sync job state (1=SUCCESS, 0=other)
                  # TYPE cloudsync_job_state gauge
                  cloudsync_job_state $([ "$JOB_STATE" = "SUCCESS" ] && echo 1 || echo 0)
                  # HELP cloudsync_duration_seconds Duration of the last Cloud Sync run
                  # TYPE cloudsync_duration_seconds gauge
                  cloudsync_duration_seconds $SYNC_DURATION
                METRICS
                done

                echo "Cloud Sync monitor complete"
              EOT
              ]
              env {
                name  = "TRUENAS_API_KEY"
                value = var.truenas_api_key
              }
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
}

# -----------------------------------------------------------------------------
# DNS Anomaly Monitor — query Technitium stats API, detect anomalies, push to Pushgateway
# Runs every 15 min. Checks for query spikes, high error rates, and suspicious patterns.
# -----------------------------------------------------------------------------
resource "kubernetes_cron_job_v1" "dns_anomaly_monitor" {
  metadata {
    name      = "dns-anomaly-monitor"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/15 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "dns-anomaly-monitor"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euo pipefail
                apk add --no-cache curl jq

                TECHNITIUM_URL="http://technitium-web.technitium.svc.cluster.local:5380"

                # Get main stats
                STATS=$(curl -sf "$TECHNITIUM_URL/api/stats/get?token=&type=LastHour" 2>&1) || {
                  echo "ERROR: Failed to query Technitium stats API"
                  exit 1
                }

                # Parse key metrics
                TOTAL_QUERIES=$(echo "$STATS" | jq -r '.response.stats.totalQueries // 0')
                SERVER_FAILURE=$(echo "$STATS" | jq -r '.response.stats.serverFailure // 0')
                NX_DOMAIN=$(echo "$STATS" | jq -r '.response.stats.nxDomain // 0')
                BLOCKED=$(echo "$STATS" | jq -r '.response.stats.blocked // 0')
                NO_ERROR=$(echo "$STATS" | jq -r '.response.stats.noError // 0')

                echo "DNS Stats (last hour): total=$TOTAL_QUERIES noError=$NO_ERROR nxDomain=$NX_DOMAIN serverFailure=$SERVER_FAILURE blocked=$BLOCKED"

                # Get top clients for anomaly context
                TOP_CLIENTS=$(curl -sf "$TECHNITIUM_URL/api/stats/getTopClients?token=&type=LastHour&limit=10" 2>&1) || true

                # Get top domains for DGA/tunneling detection
                TOP_DOMAINS=$(curl -sf "$TECHNITIUM_URL/api/stats/getTopDomains?token=&type=LastHour&limit=20" 2>&1) || true

                # Check for high-entropy domains (potential DGA)
                DGA_SUSPECT=0
                if [ -n "$TOP_DOMAINS" ]; then
                  # Simple heuristic: domains with many consonant clusters or very long labels
                  DGA_SUSPECT=$(echo "$TOP_DOMAINS" | jq -r '[.response.topDomains[]?.name // empty | select(length > 30 or test("[bcdfghjklmnpqrstvwxyz]{5,}"))] | length')
                fi

                # Push metrics to Pushgateway
                cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/dns-anomaly-monitor"
                # HELP dns_anomaly_total_queries Total DNS queries in last hour
                # TYPE dns_anomaly_total_queries gauge
                dns_anomaly_total_queries $TOTAL_QUERIES
                # HELP dns_anomaly_server_failure DNS server failures in last hour
                # TYPE dns_anomaly_server_failure gauge
                dns_anomaly_server_failure $SERVER_FAILURE
                # HELP dns_anomaly_nx_domain NX domain responses in last hour
                # TYPE dns_anomaly_nx_domain gauge
                dns_anomaly_nx_domain $NX_DOMAIN
                # HELP dns_anomaly_blocked Blocked queries in last hour
                # TYPE dns_anomaly_blocked gauge
                dns_anomaly_blocked $BLOCKED
                # HELP dns_anomaly_dga_suspects Domains with DGA-like characteristics
                # TYPE dns_anomaly_dga_suspects gauge
                dns_anomaly_dga_suspects $DGA_SUSPECT
                # HELP dns_anomaly_check_timestamp Last successful check timestamp
                # TYPE dns_anomaly_check_timestamp gauge
                dns_anomaly_check_timestamp $(date +%s)
              METRICS

                # Calculate average for spike detection (store as a simple rolling metric)
                # The Prometheus alert rule compares current vs stored average
                AVG_FILE="/tmp/dns_avg"
                if [ -f "$AVG_FILE" ]; then
                  PREV_AVG=$(cat "$AVG_FILE")
                  NEW_AVG=$(( (PREV_AVG + TOTAL_QUERIES) / 2 ))
                else
                  NEW_AVG=$TOTAL_QUERIES
                fi

                cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/dns-anomaly-monitor"
                # HELP dns_anomaly_avg_queries Rolling average DNS queries
                # TYPE dns_anomaly_avg_queries gauge
                dns_anomaly_avg_queries $NEW_AVG
              METRICS

                echo "DNS anomaly check complete (DGA suspects: $DGA_SUSPECT)"
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
}

resource "kubernetes_manifest" "status_redirect_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "status-redirect"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = ".*"
        replacement = "https://hetrixtools.com/r/38981b548b5d38b052aca8d01285a3f3/"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_ingress_v1" "status" {
  metadata {
    name      = "hetrix-redirect-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "traefik.ingress.kubernetes.io/router.middlewares" = "monitoring-status-redirect@kubernetescrd"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
    }
  }

  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["status.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "status.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "not-used"
              port {
                number = 80 # redirected by middleware
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_manifest" "yotovski_redirect_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "yotovski-redirect"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
    }
    spec = {
      redirectRegex = {
        regex       = ".*"
        replacement = "https://hetrixtools.com/r/2ba9d7a5e017794db0fd91f0115a8b3b/"
        permanent   = true
      }
    }
  }
}

resource "kubernetes_ingress_v1" "status_yotovski" {
  metadata {
    name      = "hetrix-yotovski-redirect-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "traefik.ingress.kubernetes.io/router.middlewares" = "monitoring-yotovski-redirect@kubernetescrd"
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
    }
  }

  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["yotovski-status.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "yotovski-status.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "not-used" # redirected by middleware
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# Custom ResourceQuota for monitoring — larger than the default 1-cluster tier quota
# because monitoring runs 29+ pods (Prometheus, Grafana, Loki, Alloy, exporters, etc.)
resource "kubernetes_resource_quota" "monitoring" {
  metadata {
    name      = "monitoring-quota"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "64Gi"
      pods              = "100"
    }
  }
}
