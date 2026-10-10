# shellcheck shell=bash
# Verify checks for stacks/metrics-server (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="metrics-server"

_apiservice_available() {
  local s
  s=$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
  echo "v1beta1.metrics.k8s.io Available=$s"
  [ "$s" = "True" ]
}

_node_metrics_cover_ready_nodes() {
  local ready got
  ready=$(kubectl get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
  got=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | jq '.items | length')
  echo "node metrics=$got ready nodes=$ready"
  [ "$got" -eq "$ready" ]
}

_pod_metrics_present() {
  local n
  n=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods | jq '.items | length')
  echo "pod metrics=$n"
  [ "$n" -gt 50 ]
}

verify_component() {
  check "metrics-server deployment converged" retry 300 10 workload_ready metrics-server deployment/metrics-server
  check "metrics APIService is Available" retry 120 10 _apiservice_available
  check "node metrics for every Ready node" retry 120 15 _node_metrics_cover_ready_nodes
  check "pod metrics served" retry 120 15 _pod_metrics_present
}
