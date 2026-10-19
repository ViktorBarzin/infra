# shellcheck shell=bash
# Verify checks for stacks/payslip-ingest (docs/runbooks/verify-jobs.md). The
# floor covers the app. The alpine image of the payslip-freshness-export
# CronJob runs nowhere else, so a full run starts that CronJob once: it reads
# two max() dates from the database and pushes them to Pushgateway, the same
# thing its 6-hourly schedule does.
VERIFY_GROUP="app"
VERIFY_NAMESPACES="payslip-ingest"
VERIFY_ALERTNAMES="^Payslip.*$"

verify_component() {
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "payslip-freshness-export Job completes" run_cronjob payslip-ingest payslip-freshness-export 300
    check "the export's push reached Prometheus" retry 180 15 expect_prom 'time() - max(payslip_freshness_last_success_timestamp_seconds{job="payslip-freshness"})' -lt 600
  fi
}
