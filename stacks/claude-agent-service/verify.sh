# shellcheck shell=bash
# Verify checks for stacks/claude-agent-service (docs/runbooks/verify-jobs.md).
# The floor covers the Deployments. The curl image of the
# claude-oauth-expiry-monitor CronJob runs nowhere else, so a full run starts
# that CronJob once: it reads token expiry dates and pushes them to
# Pushgateway, the same thing its 6-hourly schedule does.
VERIFY_GROUP="app"
VERIFY_NAMESPACES="claude-agent"
VERIFY_ALERTNAMES="^ClaudeOAuthToken.*$"

verify_component() {
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "claude-oauth-expiry-monitor Job completes" run_cronjob claude-agent claude-oauth-expiry-monitor 300
    check "the monitor's push reached Prometheus" retry 180 15 expect_prom 'time() - max(claude_oauth_expiry_monitor_last_push_timestamp)' -lt 600
  fi
}
