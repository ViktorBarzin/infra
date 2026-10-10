# shellcheck shell=bash
# Verify checks for stacks/k8s-dashboard (docs/runbooks/verify-jobs.md).
# End to end through kong -> auth -> api with the verify ServiceAccount's own
# (read-only) token, the same chain the token injector uses.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="kubernetes-dashboard"

D=kubernetes-dashboard.svc.cluster.local

_web_html() { expect_body "http://kubernetes-dashboard-web.$D:8000/" '<title>Kubernetes Dashboard</title>'; }
_csrf() { expect_body "http://kubernetes-dashboard-api.$D:8000/api/v1/csrftoken/login" '"token"'; }

_api_through_kong() {
  local tok out
  tok=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  out=$(curl -sk --max-time 20 -H "Authorization: Bearer $tok" "https://kubernetes-dashboard-kong-proxy.$D/api/v1/namespace")
  echo "namespaces via kong/api: $(jq -r '.listMeta.totalItems // .namespaces? | length' <<<"$out" 2>/dev/null)"
  [ "$(jq -r '.listMeta.totalItems // 0' <<<"$out" 2>/dev/null)" -gt 10 ]
}

verify_component() {
  local d
  for d in kubernetes-dashboard-api kubernetes-dashboard-auth kubernetes-dashboard-kong kubernetes-dashboard-web kubernetes-dashboard-metrics-scraper dashboard-token-injector oauth2-proxy; do
    check "$d converged" retry 300 10 workload_ready kubernetes-dashboard "deployment/$d"
  done
  check "web serves the dashboard UI" _web_html
  check "api issues a CSRF token" _csrf
  check "kong -> auth -> api lists namespaces with a bearer token" _api_through_kong
}
