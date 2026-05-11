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
variable "storage_size" {
  type    = string
  default = "1Gi"
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "actualbudget-${var.name}-data-encrypted"
    namespace = "actualbudget"
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source = "../../../modules/kubernetes/ingress_factory"
  # auth = "app": Actual Budget enforces a server password + per-user login
  # on its own sync API. Authentik forward-auth was 302-ing the mobile/web
  # sync clients; Actual's own auth gates users.
  auth              = "app"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
        ttl_seconds_after_finished = 86400
        template {
          metadata {}
          spec {
            container {
              name  = "bank-sync"
              image = "alpine:3.20"
              command = ["/bin/sh", "-c", <<-EOT
              set -u
              apk add --no-cache curl jq >/dev/null 2>&1

              USER_NAME='${var.name}'
              SYNC_ID='${var.sync_id}'
              API_KEY='${random_string.api-key.result}'
              PW='${var.budget_encryption_password}'
              PG="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/bank-sync-$USER_NAME"
              API="http://budget-http-api-$USER_NAME"

              START=$(date +%s)

              # Enumerate active accounts: open + on-budget.
              ACCOUNTS=$(curl -fsS "$API/v1/budgets/$SYNC_ID/accounts" \
                -H "x-api-key: $API_KEY" \
                -H "budget-encryption-password: $PW" \
                | jq -c '.data[] | select(.closed == false and .offbudget == false) | {id, name}')

              if [ -z "$ACCOUNTS" ]; then
                echo "ERROR: GET /accounts returned no eligible accounts; aborting"
                exit 1
              fi

              : > /tmp/payload
              rm -f /tmp/any_success

              # Per-account sync. Each account has its own PSD2/GoCardless
              # quota (4 successful pulls per 24h), so we treat them
              # independently — one rate-limited account doesn't mark the
              # run as a failure.
              echo "$ACCOUNTS" | while IFS= read -r ACCT; do
                [ -z "$ACCT" ] && continue
                ID=$(echo "$ACCT" | jq -r '.id')
                NAME=$(echo "$ACCT" | jq -r '.name')
                LABEL=$(echo "$NAME" | sed -E 's/[^a-zA-Z0-9]+/_/g')

                HTTP_CODE=$(curl -s -o /tmp/r.txt -w '%%{http_code}' \
                  -X POST "$API/v1/budgets/$SYNC_ID/accounts/$ID/banksync" \
                  -H 'accept: application/json' \
                  -H "x-api-key: $API_KEY" \
                  -H "budget-encryption-password: $PW") || HTTP_CODE=0

                NOW=$(date +%s)
                if [ "$HTTP_CODE" = "200" ]; then
                  echo "OK account=$NAME"
                  printf 'bank_sync_account_success{account="%s"} 1\n' "$LABEL" >> /tmp/payload
                  printf 'bank_sync_account_last_success_timestamp{account="%s"} %s\n' "$LABEL" "$NOW" >> /tmp/payload
                  : > /tmp/any_success
                else
                  echo "FAIL account=$NAME http=$HTTP_CODE body=$(cat /tmp/r.txt)"
                  printf 'bank_sync_account_success{account="%s"} 0\n' "$LABEL" >> /tmp/payload
                fi
              done

              END=$(date +%s)
              DUR=$((END - START))

              if [ -f /tmp/any_success ]; then
                ANY=1
              else
                ANY=0
              fi

              # Pushgateway POST preserves prior values for label sets not
              # in the payload, so per-account last_success_timestamp values
              # for accounts that failed this run keep their prior good
              # values — that's what BankSyncAccountStale alerts on.
              {
                printf '# HELP bank_sync_account_success Per-account sync result (1=ok, 0=fail)\n'
                printf '# TYPE bank_sync_account_success gauge\n'
                printf '# HELP bank_sync_account_last_success_timestamp Per-account Unix timestamp of last successful sync\n'
                printf '# TYPE bank_sync_account_last_success_timestamp gauge\n'
                cat /tmp/payload
                printf '# HELP bank_sync_success 1 if at least one account synced this run\n'
                printf '# TYPE bank_sync_success gauge\n'
                printf 'bank_sync_success %s\n' "$ANY"
                printf '# HELP bank_sync_duration_seconds Total duration of the cron run\n'
                printf '# TYPE bank_sync_duration_seconds gauge\n'
                printf 'bank_sync_duration_seconds %s\n' "$DUR"
                if [ "$ANY" = "1" ]; then
                  printf '# HELP bank_sync_last_success_timestamp Unix timestamp of the most recent successful sync of any account\n'
                  printf '# TYPE bank_sync_last_success_timestamp gauge\n'
                  printf 'bank_sync_last_success_timestamp %s\n' "$END"
                fi
              } | curl -fsS --data-binary @- "$PG"
              EOT
              ]
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
