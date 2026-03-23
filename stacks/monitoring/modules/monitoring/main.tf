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

                  echo "Task $TASK_ID ($TASK_DESC): state=$JOB_STATE, last_finished=$EPOCH_SECS"

                  # Push metrics to Pushgateway
                  cat <<METRICS | curl -sf --data-binary @- "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/cloudsync-monitor/task_id/$TASK_ID"
                  # HELP cloudsync_last_success_timestamp Last successful Cloud Sync completion (unix epoch)
                  # TYPE cloudsync_last_success_timestamp gauge
                  cloudsync_last_success_timestamp $EPOCH_SECS
                  # HELP cloudsync_job_state Cloud Sync job state (1=SUCCESS, 0=other)
                  # TYPE cloudsync_job_state gauge
                  cloudsync_job_state $([ "$JOB_STATE" = "SUCCESS" ] && echo 1 || echo 0)
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
