# shellcheck shell=bash
# Verify checks for stacks/keel (docs/runbooks/verify-jobs.md). Keel is retired
# in wave 5 of the software-currency design; until then its chart is a
# helm_release and needs a script.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="keel"

_health() {
  local ip
  ip=$(kubectl get pod -n keel -l app=keel -o jsonpath='{.items[0].status.podIP}')
  expect_http "http://$ip:9300/healthz" '200'
}

verify_component() {
  check "keel deployment converged" retry 300 10 workload_ready keel deployment/keel
  check "keel health endpoint answers" _health
  check "no panics or API errors in the last 15m" expect_no_log_errors keel app=keel 'panic|forbidden|level=fatal'
}
