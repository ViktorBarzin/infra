# shellcheck shell=bash
# Verify checks for stacks/keel (docs/runbooks/verify-jobs.md). Keel was
# parked on 2026-10-10 (helm release uninstalled, local.keel_enabled = false)
# and retired on 2026-10-11 (software-currency design, Phase 3), so the checks
# confirm it stays stopped. The stack stays until the first-party apps Keel
# deployed have their own deploy step (stacks/keel/main.tf header).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="keel"

_parked() {
  local deploys pods
  deploys=$(kubectl get deployments -n keel --no-headers 2>/dev/null | wc -l)
  pods=$(kubectl get pods -n keel --no-headers 2>/dev/null | wc -l)
  echo "deployments=$deploys pods=$pods"
  [ "$deploys" -eq 0 ] && [ "$pods" -eq 0 ]
}

verify_component() {
  check "keel is parked (no Deployment, no pods)" retry 300 10 _parked
}
