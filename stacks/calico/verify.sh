# shellcheck shell=bash
# Verify checks for stacks/calico (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="tigera-operator calico-system"
VERIFY_ALERTNAMES="^(Calico.*|PodsStuckContainerCreating|KubeletRunningContainersDrop)$"

_tigerastatus() {
  local out
  out=$(kubectl get tigerastatuses.operator.tigera.io -o json | jq -r '
    [.items[] | {n:.metadata.name,
                 a:([.status.conditions[]? | select(.type=="Available")][0].status // "Unknown"),
                 d:([.status.conditions[]? | select(.type=="Degraded")][0].status // "Unknown")}] as $s
    | [$s[] | select(.a != "True" or .d != "False") | .n] as $bad
    | "tigerastatus: \($s | map("\(.n)=\(.a)") | join(" ")) bad=\($bad)", (if ($s|length) > 0 and ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_calico_version() {
  local v
  v=$(kubectl get installations.operator.tigera.io default -o jsonpath='{.status.calicoVersion}')
  echo "installation calicoVersion=$v"
  [ -n "$v" ]
}

_apiserver_available() {
  local s
  s=$(kubectl get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
  echo "v3.projectcalico.org Available=$s"
  [ "$s" = "True" ]
}

_new_pod_network() {
  # A fresh pod gets an IP, resolves cluster DNS and reaches a ClusterIP on
  # another node.
  run_pod net docker.io/curlimages/curl:8.11.1 \
    'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 || getent hosts kubernetes.default.svc.cluster.local; c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://prometheus-server.monitoring.svc.cluster.local/-/ready); echo "pod ip $(hostname -i) prometheus ready -> $c"; [ "$c" = 200 ]' timeout=180
}

verify_component() {
  check "tigera-operator converged" retry 300 10 workload_ready tigera-operator deployment/tigera-operator
  check "calico-node converged on every node" retry 300 10 workload_ready calico-system daemonset/calico-node
  check "every Calico component Available, none Degraded" retry 300 20 _tigerastatus
  check "Installation reports a Calico version" _calico_version
  check "Calico API server Available" _apiserver_available
  check "a new pod gets networking, DNS and a ClusterIP" _new_pod_network
}
