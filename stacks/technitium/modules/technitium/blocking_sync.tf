# Blocking parity: secondary and tertiary block what the primary blocks.
#
# Clients reach Technitium through one address (LB 10.0.20.201), which spreads
# lookups over all three instances. Until 2026-11-04 only the primary had block
# lists, the Advanced Blocking and Drop Requests apps and the query log, so
# about 7 in 10 Sofia lookups went unfiltered and unlogged (measured: tertiary
# 46%, secondary 25%, primary 29% of last-hour queries; ad.doubleclick.net
# blocked on the primary and answered by both replicas).
#
# The primary stays the place to change blocking (web UI or API). Every 6 hours
# this job copies its built-in blocking settings and the Advanced Blocking and
# Drop Requests app configs to both replicas, installing any of those apps that
# a replica is missing, and installs "Query Logs (PostgreSQL)" on the replicas
# for technitium-password-sync to configure. Only the blocking keys are sent to
# settings/set; the replicas' other settings (forwarders, recursion) are left
# alone. App configs are copied as raw text because the Drop Requests config
# carries // comments, which a JSON parser rejects.
#
# Pushes technitium_blocking_sync_status / _last_run to the Pushgateway; alerts
# TechnitiumBlockingSyncFailed / Stale (monitoring stack).

resource "kubernetes_secret_v1" "technitium_api" {
  metadata {
    name      = "technitium-api"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  data = {
    TECH_USER = var.technitium_username
    TECH_PASS = var.technitium_password
  }
}

resource "kubernetes_cron_job_v1" "technitium_blocking_sync" {
  metadata {
    name      = "technitium-blocking-sync"
    namespace = kubernetes_namespace.technitium.metadata[0].name
  }
  spec {
    schedule                      = "20 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 2
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name = "blocking-sync"
              # job-runtime has curl and jq baked in.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "IfNotPresent"
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
                PRIMARY="http://technitium-web:5380"
                REPLICAS="http://technitium-secondary-web:5380 http://technitium-tertiary-web:5380"
                PUSHGW="http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/technitium-blocking-sync"
                COPY_APPS="Advanced Blocking|Drop Requests"
                INSTALL_APPS="Advanced Blocking|Drop Requests|Query Logs (PostgreSQL)"
                STATUS=0

                push() {
                  cat <<METRICS | curl -sf -X PUT --data-binary @- "$$PUSHGW" >/dev/null || echo "WARN: pushgateway push failed"
                # HELP technitium_blocking_sync_status Blocking sync status (0=ok, 1=fail)
                # TYPE technitium_blocking_sync_status gauge
                technitium_blocking_sync_status $$STATUS
                # HELP technitium_blocking_sync_last_run Unix time of the last blocking sync run
                # TYPE technitium_blocking_sync_last_run gauge
                technitium_blocking_sync_last_run $$(date +%s)
              METRICS
                }
                fail() { echo "ERROR: $$*"; STATUS=1; }
                login() {
                  curl -sf "$$1/api/user/login" --data-urlencode "user=$$TECH_USER" --data-urlencode "pass=$$TECH_PASS" | jq -r '.token // empty'
                }
                ok() { [ "$$(printf '%s' "$$1" | jq -r '.status // empty' 2>/dev/null)" = "ok" ]; }
                app_config() {
                  curl -sf -G "$$1/api/apps/config/get" --data-urlencode "token=$$2" --data-urlencode "name=$$3" | jq -r '.response.config // empty'
                }

                PT=$$(login "$$PRIMARY")
                if [ -z "$$PT" ]; then fail "cannot log in to the primary"; push; exit 1; fi
                PS=$$(curl -sf "$$PRIMARY/api/settings/get?token=$$PT")
                URLS=$$(printf '%s' "$$PS" | jq -r '(.response.blockListUrls // []) | join(",")')
                if [ -z "$$URLS" ]; then
                  # An empty list would wipe the replicas' lists; treat it as a bad read.
                  fail "primary reports no block list URLs"; push; exit 1
                fi
                WANT=$$(printf '%s' "$$PS" | jq -c '.response | {enableBlocking, blockingType, blockingAnswerTtl, allowTxtBlockingReport, blockListUpdateIntervalHours, blockListUrls}')
                STORE=$$(curl -sf "$$PRIMARY/api/apps/listStoreApps?token=$$PT")

                for R in $$REPLICAS; do
                  echo "== $$R"
                  RT=$$(login "$$R")
                  if [ -z "$$RT" ]; then fail "cannot log in to $$R"; continue; fi

                  HAVE_APPS=$$(curl -sf "$$R/api/apps/list?token=$$RT" | jq -r '.response.apps[].name')
                  # Every instance has at least Split Horizon; an empty list is a failed read.
                  if [ -z "$$HAVE_APPS" ]; then fail "cannot list apps on $$R"; continue; fi
                  echo "$$INSTALL_APPS" | tr '|' '\n' | while read -r APP; do
                    if printf '%s\n' "$$HAVE_APPS" | grep -qxF "$$APP"; then continue; fi
                    URL=$$(printf '%s' "$$STORE" | jq -r --arg n "$$APP" '.response.storeApps[] | select(.name == $$n) | .url')
                    if [ -z "$$URL" ]; then echo "ERROR: $$APP not in the app store"; exit 1; fi
                    RES=$$(curl -sf -G "$$R/api/apps/downloadAndInstall" --data-urlencode "token=$$RT" --data-urlencode "name=$$APP" --data-urlencode "url=$$URL")
                    if ok "$$RES"; then echo "installed $$APP"; else echo "ERROR: installing $$APP: $$RES"; exit 1; fi
                  done || fail "app install on $$R"

                  RS=$$(curl -sf "$$R/api/settings/get?token=$$RT")
                  HAVE=$$(printf '%s' "$$RS" | jq -c '.response | {enableBlocking, blockingType, blockingAnswerTtl, allowTxtBlockingReport, blockListUpdateIntervalHours, blockListUrls}')
                  if [ "$$HAVE" != "$$WANT" ]; then
                    RES=$$(curl -sf "$$R/api/settings/set?token=$$RT" \
                      --data-urlencode "enableBlocking=$$(printf '%s' "$$WANT" | jq -r .enableBlocking)" \
                      --data-urlencode "blockingType=$$(printf '%s' "$$WANT" | jq -r .blockingType)" \
                      --data-urlencode "blockingAnswerTtl=$$(printf '%s' "$$WANT" | jq -r .blockingAnswerTtl)" \
                      --data-urlencode "allowTxtBlockingReport=$$(printf '%s' "$$WANT" | jq -r .allowTxtBlockingReport)" \
                      --data-urlencode "blockListUpdateIntervalHours=$$(printf '%s' "$$WANT" | jq -r .blockListUpdateIntervalHours)" \
                      --data-urlencode "blockListUrls=$$URLS")
                    if ok "$$RES"; then
                      echo "blocking settings set"
                      curl -sf "$$R/api/settings/forceUpdateBlockLists?token=$$RT" >/dev/null && echo "block list download started"
                    else
                      fail "settings/set on $$R: $$RES"
                    fi
                  else
                    echo "blocking settings already match"
                  fi

                  echo "$$COPY_APPS" | tr '|' '\n' | while read -r APP; do
                    WANT_CFG=$$(app_config "$$PRIMARY" "$$PT" "$$APP")
                    if [ -z "$$WANT_CFG" ]; then echo "ERROR: primary has no $$APP config"; exit 1; fi
                    HAVE_CFG=$$(app_config "$$R" "$$RT" "$$APP")
                    if [ "$$HAVE_CFG" = "$$WANT_CFG" ]; then echo "$$APP config already matches"; continue; fi
                    RES=$$(curl -sf -X POST "$$R/api/apps/config/set?token=$$RT" --data-urlencode "name=$$APP" --data-urlencode "config=$$WANT_CFG")
                    if ok "$$RES"; then echo "$$APP config copied"; else echo "ERROR: $$APP config on $$R: $$RES"; exit 1; fi
                  done || fail "app config copy on $$R"
                done

                push
                exit $$STATUS
              EOT
              ]
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "128Mi"
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
