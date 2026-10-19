# shellcheck shell=bash
# Verify checks for stacks/dawarich (docs/runbooks/verify-jobs.md). The floor
# covers the app. The postgres image of the ingestion-freshness-monitor
# CronJob runs nowhere else, so a full run starts that CronJob once: it reads
# the newest point's timestamp from the dawarich database and pushes it to
# Pushgateway, the same thing its daily schedule does.
VERIFY_GROUP="app"
VERIFY_NAMESPACES="dawarich"
VERIFY_ALERTNAMES="^Dawarich.*$"

verify_component() {
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "ingestion-freshness-monitor Job completes" run_cronjob dawarich ingestion-freshness-monitor 300
    check "the monitor's push reached Prometheus" retry 180 15 expect_prom 'time() - max(dawarich_ingestion_monitor_last_push_timestamp{user="viktor"})' -lt 600
  fi
}
