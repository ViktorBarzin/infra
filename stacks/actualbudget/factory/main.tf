variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}
# actual-server and actual-http-api are SEPARATELY released and their version
# ceilings differ (jhonderson publishes patch releases upstream doesn't, e.g.
# 26.6.1), so the http-api needs its own tag rather than reusing var.tag. Both
# images stay in `ignore_changes` — Keel owns the live tag — so this value is
# only the seed used when a Deployment is CREATED or RECREATED. It was a
# hardcoded `latest` until 2026-08-16, which meant any recreate pulled whatever
# was newest at that moment, across a component that migrates the budget file.
variable "http_api_tag" {
  type    = string
  default = "26.8.1"
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
variable "enabled" {
  type        = bool
  default     = true
  description = "Deploy this instance. When false, only the PVC is kept (data preservation); deployment, service, ingress, http-api, and cronjob are not created. Flip back to true to bring the instance back."
}
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
  count = var.enabled ? 1 : 0
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "actualbudget" {
  count = var.enabled ? 1 : 0
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
  count  = var.enabled ? 1 : 0
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
  # Actual's app boot fires ~70 parallel asset/migration revalidations
  # (max-age=0); the default 10/50 limiter 429s the tail and stalls every
  # load. Dedicated higher-burst limiter, same pattern as Immich.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-actualbudget-rate-limit@kubernetescrd"]
}


resource "random_string" "api-key" {
  length = 32
  lower  = true
}

resource "kubernetes_deployment" "actualbudget-http-api" {
  count = var.enabled && var.enable_http_api ? 1 : 0
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
          image = "jhonderson/actual-http-api:${var.http_api_tag}"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "actualbudget-http-api" {
  count = var.enabled && var.enable_http_api ? 1 : 0
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
  count = var.enabled && var.enable_bank_sync ? 1 : 0
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
        backoff_limit = 1
        # Hard ceiling on a single run. The per-curl --max-time values bound each
        # request; this bounds the whole job so a wedge can never sit Running until
        # the next day's schedule replaces it. A normal run is 30-95 s.
        active_deadline_seconds    = 1800
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
              PGROOT="http://prometheus-prometheus-pushgateway.monitoring:9091"
              PG="$PGROOT/metrics/job/bank-sync-$USER_NAME"
              API="http://budget-http-api-$USER_NAME"

              # NOTE: we deliberately do NOT send `budget-encryption-password`.
              # Neither budget file is end-to-end encrypted (encrypt_keyid is null
              # in the server's account.sqlite), but actual-http-api branches on the
              # mere PRESENCE of that header: with it, every request takes the
              # downloadBudget() path — a full re-download, decrypt and ~20 MB backup
              # zip — instead of the cheap loadBudget()+sync(). Measured 2026-08-16:
              # 110,000 ms (timeout) with the header vs 108 ms without on anca, and
              # 340 ms -> 62 ms on viktor. fire-planner has always called this API
              # without it. RESTORE THE HEADER if E2E encryption is ever enabled.
              # (var.budget_encryption_password is really the server login password —
              # it is passed as ACTUAL_SERVER_PASSWORD on the http-api Deployment.)

              # Every curl carries --max-time. Without it the GET below can block
              # forever on a slow budget load; concurrency_policy=Replace then leaves
              # the run hanging until the NEXT day's schedule kills it, silently
              # losing a day's sync while the pushgateway still shows yesterday's
              # success (observed 2026-08-16, anca: 18+ min, zero log output).
              START=$(date +%s)

              # Snapshot the current per-account timestamps BEFORE we overwrite the
              # group. A Pushgateway POST replaces the whole metric family for this
              # job, so any series we don't re-emit disappears entirely — and a
              # series that disappears can never go stale, which is exactly what
              # BankSyncAccountStale needs in order to fire on a per-account failure.
              PRIOR=$(curl -fsS --max-time 15 "$PGROOT/metrics" 2>/dev/null \
                | grep "^bank_sync_account_last_success_timestamp{" \
                | grep "job=\"bank-sync-$USER_NAME\"" || true)

              # Enumerate active accounts: open + on-budget.
              ACCOUNTS=$(curl -fsS --max-time 120 "$API/v1/budgets/$SYNC_ID/accounts" \
                -H "x-api-key: $API_KEY" \
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

                HTTP_CODE=$(curl -s --max-time 300 -o /tmp/r.txt -w '%%{http_code}' \
                  -X POST "$API/v1/budgets/$SYNC_ID/accounts/$ID/banksync" \
                  -H 'accept: application/json' \
                  -H "x-api-key: $API_KEY") || HTTP_CODE=0

                NOW=$(date +%s)
                if [ "$HTTP_CODE" = "200" ]; then
                  echo "OK account=$NAME"
                  printf 'bank_sync_account_success{account="%s"} 1\n' "$LABEL" >> /tmp/payload
                  printf 'bank_sync_account_last_success_timestamp{account="%s"} %s\n' "$LABEL" "$NOW" >> /tmp/payload
                  : > /tmp/any_success
                else
                  echo "FAIL account=$NAME http=$HTTP_CODE body=$(cat /tmp/r.txt)"
                  printf 'bank_sync_account_success{account="%s"} 0\n' "$LABEL" >> /tmp/payload
                  # Carry the previous good timestamp forward so the series survives
                  # this run and can age into BankSyncAccountStale. Emitting 0 here
                  # would make (time() - 0) > 259200 trivially true and fire the
                  # alert after a single failed run — which the deliberate
                  # no-BankSyncFailing design rejects, since GoCardless PSD2 quota
                  # makes isolated per-account failures routine. First-ever run has
                  # no prior value, so nothing is emitted (same as before).
                  PRIOR_TS=$(echo "$PRIOR" | grep "account=\"$LABEL\"" | awk '{print $NF}' | head -1)
                  if [ -n "$PRIOR_TS" ]; then
                    printf 'bank_sync_account_last_success_timestamp{account="%s"} %s\n' "$LABEL" "$PRIOR_TS" >> /tmp/payload
                  fi
                fi
              done

              END=$(date +%s)
              DUR=$((END - START))

              if [ -f /tmp/any_success ]; then
                ANY=1
              else
                ANY=0
              fi

              # Duplicate-import check. HTTP 200 on /banksync asserts nothing about
              # whether the import was CORRECT: from 2024-12 to 2026-08-16 a rule
              # with a `set account` action moved each freshly-imported row out of
              # the account being synced, and Actual's dedupe is scoped to that
              # account (WHERE imported_id = ? AND account = ?), so the same
              # transactions were re-inserted every night — ~93% of rows created per
              # run — while every metric here stayed green. This counts rows sharing
              # an imported_id, which is what that failure actually looks like.
              # Read-only against the local budget file: no GoCardless quota.
              # Pre-initialised: `set -u` is in effect, so these must exist even
              # when the query is skipped or fails.
              DUP_GROUPS=""
              DUP_EXCESS=""
              DUPQ='{"ActualQLquery":{"table":"transactions","filter":{"imported_id":{"$ne":null}},"groupBy":["imported_id"],"select":["imported_id",{"n":{"$count":"id"}}]}}'
              DUPJSON=$(curl -fsS --max-time 60 -X POST "$API/v1/budgets/$SYNC_ID/run-query" \
                -H 'content-type: application/json' \
                -H "x-api-key: $API_KEY" \
                -d "$DUPQ" 2>/dev/null || true)

              if [ -n "$DUPJSON" ]; then
                DUP_GROUPS=$(echo "$DUPJSON" | jq '[.data.data[]? // .data[]? | select(.n > 1)] | length' 2>/dev/null || echo "")
                DUP_EXCESS=$(echo "$DUPJSON" | jq '[.data.data[]? // .data[]? | select(.n > 1) | .n - 1] | add // 0' 2>/dev/null || echo "")
              fi
              if [ -n "$DUP_GROUPS" ] && [ -n "$DUP_EXCESS" ]; then
                DUP_OK=1
              else
                DUP_OK=0
                DUP_GROUPS=0
                DUP_EXCESS=0
              fi

              # A Pushgateway POST REPLACES every metric family in this job's group —
              # it does NOT preserve label sets absent from the payload. That is why
              # the failure branch above re-emits the prior timestamp explicitly.
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
                printf '# HELP bank_sync_duplicate_imported_ids Distinct imported_ids present on more than one live transaction\n'
                printf '# TYPE bank_sync_duplicate_imported_ids gauge\n'
                printf 'bank_sync_duplicate_imported_ids %s\n' "$DUP_GROUPS"
                printf '# HELP bank_sync_excess_imported_rows Live transaction rows beyond one per imported_id\n'
                printf '# TYPE bank_sync_excess_imported_rows gauge\n'
                printf 'bank_sync_excess_imported_rows %s\n' "$DUP_EXCESS"
                printf '# HELP bank_sync_dupcheck_success 1 if the duplicate-import check ran and parsed\n'
                printf '# TYPE bank_sync_dupcheck_success gauge\n'
                printf 'bank_sync_dupcheck_success %s\n' "$DUP_OK"
                if [ "$ANY" = "1" ]; then
                  printf '# HELP bank_sync_last_success_timestamp Unix timestamp of the most recent successful sync of any account\n'
                  printf '# TYPE bank_sync_last_success_timestamp gauge\n'
                  printf 'bank_sync_last_success_timestamp %s\n' "$END"
                fi
              } | curl -fsS --max-time 30 --data-binary @- "$PG"
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

# State migration for the new `enabled` toggle (2026-05-13): adding
# count to these resources shifts their addresses to [0]. Without
# moved {}, Terraform would destroy+recreate. Existing http-api / bank-sync
# resources already had count, so no migration needed there.
moved {
  from = kubernetes_deployment.actualbudget
  to   = kubernetes_deployment.actualbudget[0]
}
moved {
  from = kubernetes_service.actualbudget
  to   = kubernetes_service.actualbudget[0]
}
moved {
  from = kubernetes_service.actualbudget-http-api
  to   = kubernetes_service.actualbudget-http-api[0]
}
moved {
  from = module.ingress
  to   = module.ingress[0]
}
