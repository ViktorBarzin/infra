variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}
variable "tier" { type = string }
variable "sync_id" {
  type    = string
  default = null # If not passed, we won't run banksync
}
variable "budget_encryption_password" {
  type      = string
  default   = null # If not passed, we won't run banksync ;known after initial installation
  sensitive = true
}
# Plan-time toggles — these MUST be known at plan time. The secret values
# (budget_encryption_password, sync_id) are read from ESO-managed K8s Secrets
# and are unknown at plan time on first apply, so we cannot base `count` on
# them directly. Callers pass these booleans as hardcoded plan-time constants
# that reflect whether the corresponding credentials are expected to exist.
variable "enable_http_api" {
  type        = bool
  default     = false
  description = "Deploy the actual-http-api sidecar. Must be true for the cronjob to run."
}
variable "enable_bank_sync" {
  type        = bool
  default     = false
  description = "Deploy the daily bank-sync CronJob. Requires enable_http_api=true."
}
variable "nfs_server" { type = string }
variable "homepage_annotations" {
  type    = map(string)
  default = {}
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "actualbudget-${var.name}-data-encrypted"
    namespace = "actualbudget"
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "actualbudget" {
  metadata {
    name      = "actualbudget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app  = "actualbudget-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "actualbudget-${var.name}"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "false" # daily updates; pretty noisy
          "diun.include_tags" = "^${var.tag}$"
        }
        labels = {
          app = "actualbudget-${var.name}"
        }
      }
      spec {
        container {
          image = "actualbudget/actual-server:${var.tag}"
          name  = "actualbudget"

          port {
            container_port = 5006
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "320Mi"
            }
            limits = {
              memory = "400Mi"
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget" {
  metadata {
    name      = "budget-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-${var.name}"
    }
  }

  spec {
    selector = {
      app = "actualbudget-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5006
    }
  }
}

module "ingress" {
  source            = "../../../modules/kubernetes/ingress_factory"
  namespace         = "actualbudget"
  name              = "budget-${var.name}"
  tls_secret_name   = var.tls_secret_name
  dns_type          = "proxied"
  extra_annotations = var.homepage_annotations
}


resource "random_string" "api-key" {
  length = 32
  lower  = true
}

resource "kubernetes_deployment" "actualbudget-http-api" {
  count = var.enable_http_api ? 1 : 0
  metadata {
    name      = "actualbudget-http-api-${var.name}"
    namespace = "actualbudget"
    labels = {
      app  = "actualbudget-http-api-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "actualbudget-http-api-${var.name}"
      }
    }
    template {
      metadata {
        labels = {
          app = "actualbudget-http-api-${var.name}"
        }
      }
      spec {
        container {
          image = "jhonderson/actual-http-api:latest"
          name  = "actualbudget"
          resources {
            requests = {
              cpu    = "50m"
              memory = "768Mi"
            }
            limits = {
              memory = "768Mi"
            }
          }

          port {
            container_port = 5007
          }
          env {
            name  = "ACTUAL_SERVER_URL"
            value = "http://budget-${var.name}.actualbudget.svc.cluster.local"
          }
          env {
            name  = "ACTUAL_SERVER_PASSWORD"
            value = var.budget_encryption_password
          }
          env {
            name  = "API_KEY"
            value = random_string.api-key.result
          }

        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget-http-api" {
  metadata {
    name      = "budget-http-api-${var.name}"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget-http-api-${var.name}"
    }
  }

  spec {
    selector = {
      app = "actualbudget-http-api-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5007
    }
  }
}

resource "kubernetes_cron_job_v1" "bank-sync" {
  count = var.enable_bank_sync ? 1 : 0
  metadata {
    name      = "bank-sync-${var.name}"
    namespace = "actualbudget"
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 0 * * *" # Daily
    starting_deadline_seconds     = 60
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "bank-sync"
              image = "curlimages/curl"
              command = ["/bin/sh", "-c", <<-EOT
              PUSHGATEWAY="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/bank-sync-${var.name}"
              START=$(date +%s)

              HTTP_CODE=$(curl -s -o /tmp/response.txt -w '%%{http_code}' \
                -X POST --location \
                'http://budget-http-api-${var.name}/v1/budgets/${var.sync_id}/accounts/banksync' \
                --header 'accept: application/json' \
                --header 'budget-encryption-password: ${var.budget_encryption_password}' \
                --header 'x-api-key: ${random_string.api-key.result}')

              END=$(date +%s)
              DURATION=$((END - START))

              if [ "$HTTP_CODE" = "200" ]; then
                SUCCESS=1
                LAST_SUCCESS=$END
              else
                SUCCESS=0
                LAST_SUCCESS=0
                echo "Bank sync failed with HTTP $HTTP_CODE:"
                cat /tmp/response.txt
                echo ""
              fi

              cat <<METRICS | curl -s --data-binary @- "$PUSHGATEWAY"
              # HELP bank_sync_success Whether the last bank sync succeeded (1=ok, 0=fail)
              # TYPE bank_sync_success gauge
              bank_sync_success $SUCCESS
              # HELP bank_sync_duration_seconds Duration of the last bank sync run
              # TYPE bank_sync_duration_seconds gauge
              bank_sync_duration_seconds $DURATION
              # HELP bank_sync_last_success_timestamp Unix timestamp of the last successful sync
              # TYPE bank_sync_last_success_timestamp gauge
              bank_sync_last_success_timestamp $LAST_SUCCESS
              METRICS
              EOT
              ]
            }
          }
        }
      }
    }
  }
}
