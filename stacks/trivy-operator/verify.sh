# shellcheck shell=bash
# Verify checks for stacks/trivy-operator (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="trivy-system"
VERIFY_ALERTNAMES="^TrivyMetricsAbsent$"

_reports_fresh() {
  # Metadata only: the full reports are far larger than this pod's memory.
  local j n newest age
  j=$(meta_list /apis/aquasecurity.github.io/v1alpha1/vulnerabilityreports) || return 1
  n=$(jq '.items | length' <<<"$j")
  newest=$(jq -r '[.items[].metadata.creationTimestamp] | max' <<<"$j")
  age=$(age_seconds "$newest")
  echo "vulnerabilityreports=$n newest=$newest (${age}s ago)"
  [ "$n" -gt 100 ] && [ "$age" -lt 86400 ]
}

_server_health() { expect_http "http://trivy-service.trivy-system.svc.cluster.local:4954/healthz" '200'; }

verify_component() {
  check "trivy-operator deployment converged" retry 300 10 workload_ready trivy-system deployment/trivy-operator
  check "trivy-server converged" retry 300 10 workload_ready trivy-system statefulset/trivy-server
  check "trivy-server healthz" _server_health
  check "vulnerability reports exist and were refreshed within 24h" _reports_fresh
  check "trivy_ metrics reach Prometheus" expect_series 'trivy_image_vulnerabilities' 50
  check "TrivyMetricsAbsent is not firing" expect_alert_inactive '^TrivyMetricsAbsent$'
}
