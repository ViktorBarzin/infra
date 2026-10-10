# shellcheck shell=bash
# Verify checks for stacks/descheduler (docs/runbooks/verify-jobs.md).
# The descheduler is an hourly CronJob (:55), so its function is a Job that
# completes on the current image. When the newest run predates the change
# (--since), a full run waits for the next scheduled run.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="descheduler"

_newest_job() {
  kubectl get jobs -n descheduler -o json |
    jq -r '[.items[] | select(.metadata.ownerReferences[0].name == "descheduler")] | sort_by(.metadata.creationTimestamp) | last
           | "\(.metadata.name) \(.metadata.creationTimestamp | fromdateiso8601) \(.status.succeeded // 0) \(.status.failed // 0)"'
}

_run_on_current_image() {
  local name created ok failed want img
  read -r name created ok failed <<<"$(_newest_job)"
  [ -n "$name" ] && [ "$name" != "null" ] || { echo "no descheduler job found"; return 1; }
  if [ "${VERIFY_QUICK:-0}" != 1 ] && [ "$created" -lt "${VERIFY_SINCE:-0}" ]; then
    echo "newest job $name started before the change; waiting for the next run"
    return 1
  fi
  want=$(kubectl get cronjob -n descheduler descheduler -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')
  img=$(kubectl get pods -n descheduler -l "job-name=$name" -o jsonpath='{.items[0].spec.containers[0].image}')
  echo "job=$name succeeded=$ok failed=$failed pod image=$img template=$want"
  [ "$ok" -ge 1 ] && [ "$img" = "$want" ]
}

_run_log_summary() {
  local name pod logs
  name=$(_newest_job | cut -d' ' -f1)
  pod=$(kubectl get pods -n descheduler -l "job-name=$name" -o jsonpath='{.items[0].metadata.name}')
  logs=$(kubectl logs -n descheduler "$pod")
  grep -E 'Number of evictions|unknown field|forbidden|E[0-9]{4} ' <<<"$logs" | tail -3
  grep -q 'Number of evictions' <<<"$logs" && ! grep -Eq 'unknown field|forbidden' <<<"$logs"
}

_last_success_recent() {
  local t age
  t=$(kubectl get cronjob -n descheduler descheduler -o jsonpath='{.status.lastSuccessfulTime}')
  age=$(age_seconds "$t")
  echo "last success $t (${age}s ago)"
  [ "$age" -lt 5400 ]
}

verify_component() {
  check "descheduler CronJob last succeeded within 90 min" _last_success_recent
  local wait=60
  [ "${VERIFY_QUICK:-0}" = 1 ] || wait=3000
  check "a descheduler run completed on the current image" retry "$wait" 60 _run_on_current_image
  check "that run logged its eviction summary, no policy or RBAC errors" _run_log_summary
}
