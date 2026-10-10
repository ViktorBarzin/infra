# shellcheck shell=bash
# Verify checks for stacks/keel (docs/runbooks/verify-jobs.md). Since
# 2026-10-10 Keel is parked at 0 replicas for the Renovate cutover
# (software-currency design, Phase 3, batch B00), so the checks confirm it
# stays stopped. The stack is removed after the last cutover batch.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="keel"

_parked() {
  local spec pods
  spec=$(kubectl get deployment -n keel keel -o jsonpath='{.spec.replicas}')
  pods=$(kubectl get pods -n keel -l app=keel --no-headers 2>/dev/null | wc -l)
  echo "spec.replicas=$spec pods=$pods"
  [ "$spec" = 0 ] && [ "$pods" -eq 0 ]
}

verify_component() {
  check "keel is parked (0 replicas, no pods)" retry 300 10 _parked
}
