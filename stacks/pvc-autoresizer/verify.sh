# shellcheck shell=bash
# Verify checks for stacks/pvc-autoresizer (docs/runbooks/verify-jobs.md).
# Restart counts are not judged: the controller restarts a few times a day on
# 'leader election lost' from API-server lease timeouts (pre-existing).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="pvc-autoresizer"

_leader_metrics() {
  local holder ip m
  holder=$(kubectl get lease -n pvc-autoresizer 49e22f61.topolvm.io -o jsonpath='{.spec.holderIdentity}')
  holder=${holder%%_*}
  ip=$(kubectl get pod -n pvc-autoresizer "$holder" -o jsonpath='{.status.podIP}' 2>/dev/null)
  [ -n "$ip" ] || { echo "lease holder '$holder' is not a running pod"; return 1; }
  m=$(curl -sS --max-time 10 "http://$ip:8080/metrics")
  echo "leader=$holder $(grep -E '^pvcautoresizer_(kubernetes_client_fail_total|metrics_client_fail_total|loop_seconds_total)' <<<"$m" | tr '\n' ' ')"
  grep -q '^pvcautoresizer_loop_seconds_total' <<<"$m" &&
    grep -Eq '^pvcautoresizer_kubernetes_client_fail_total 0$' <<<"$m"
}

verify_component() {
  check "controller deployment converged" retry 300 10 workload_ready pvc-autoresizer deployment/pvc-autoresizer-controller
  check "leader runs the resize loop with no API client failures" retry 660 60 _leader_metrics
  check "no Prometheus client errors in the last 15m" expect_no_log_errors pvc-autoresizer app.kubernetes.io/name=pvc-autoresizer 'failed to (get|query) .*prometheus|metrics client'
}
