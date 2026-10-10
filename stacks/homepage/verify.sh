# shellcheck shell=bash
# Verify checks for stacks/homepage (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="homepage"

H="http://homepage.homepage.svc.cluster.local:3000"
# Homepage validates the Host header (HOMEPAGE_ALLOWED_HOSTS).
HOST_HDR="Host: home.viktorbarzin.me"

_health() { expect_body "$H/api/healthcheck" 'up' -H "$HOST_HDR"; }

_services() {
  local out g s
  out=$(curl -sS --max-time 30 -H "$HOST_HDR" "$H/api/services?_=$(date +%s)")
  g=$(jq 'length' <<<"$out" 2>/dev/null)
  s=$(jq '[.[].services[]?] | length' <<<"$out" 2>/dev/null)
  echo "groups=$g services=$s"
  [ "${g:-0}" -ge 5 ] && [ "${s:-0}" -ge 50 ]
}

_k8s_widget() {
  local out n
  out=$(curl -sS --max-time 30 -H "$HOST_HDR" "$H/api/widgets/kubernetes?type=cluster&_=$(date +%s)")
  n=$(jq '.nodes | length' <<<"$out" 2>/dev/null)
  echo "kubernetes widget nodes=$n"
  [ "${n:-0}" -ge 1 ]
}

verify_component() {
  check "homepage deployment converged" retry 300 10 workload_ready homepage deployment/homepage
  check "homepage healthcheck says up" _health
  check "service list renders from ingress annotations" _services
  check "kubernetes widget reads the cluster" _k8s_widget
  check "no host-validation or auth errors in the last 15m" expect_no_log_errors homepage app.kubernetes.io/name=homepage 'host validation|nextauth|\berror\b.*widget'
}
