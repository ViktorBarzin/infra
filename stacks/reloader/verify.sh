# shellcheck shell=bash
# Verify checks for stacks/reloader (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="reloader"

_annotations_strategy() {
  local args
  args=$(kubectl get deploy -n reloader reloader-reloader -o jsonpath='{.spec.template.spec.containers[0].args}')
  echo "args=$args"
  # The annotations strategy is load-bearing: env-var strategy would roll
  # about 33 deployments on every upgrade (stacks/reloader/main.tf).
  grep -q -- '--reload-strategy=annotations' <<<"$args"
}

_metrics_endpoint() {
  local ip
  ip=$(kubectl get pod -n reloader -l app=reloader-reloader -o jsonpath='{.items[0].status.podIP}')
  [ -n "$ip" ] || { echo "no reloader pod IP"; return 1; }
  local m
  m=$(curl -sS --max-time 10 "http://$ip:9090/metrics")
  grep -E '^reloader_reload_executed_total' <<<"$m" | sed -n 1,3p
  grep -q '^# TYPE reloader_reload_executed_total' <<<"$m"
}

verify_component() {
  check "reloader deployment converged" retry 300 10 workload_ready reloader deployment/reloader-reloader
  check "reload strategy is annotations" _annotations_strategy
  check "reloader serves its reload counter" retry 60 10 _metrics_endpoint
  check "no RBAC or watch errors in reloader logs" expect_no_log_errors reloader app=reloader-reloader 'forbidden|level=error|level=fatal|panic'
}
