# Sourced by tests/cloud-access.test.sh and tests/cloud-calico.test.sh: a kind
# cluster with the default CNI off and the Calico stacks/calico pins, installed
# by its tigera-operator chart, with calico-apiserver serving
# projectcalico.org/v3 as on the cluster.
#
# Calico's pods need inotify instances. kind nodes all run as root on the
# host, so other kind clusters on the same machine share
# fs.inotify.max_user_instances (128 on the devvm); with two other clusters
# up, kube-proxy and tigera-operator crashloop with "too many open files".
# cloud_calico_preflight checks for that before a test starts.

cloud_calico_preflight() {
  local max nodes
  max="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
  nodes="$(docker ps -q --filter label=io.x-k8s.kind.cluster 2>/dev/null | grep -c .)"
  if [ "$max" -lt 512 ] && [ "$nodes" -ge 3 ]; then
    echo "FAIL: $nodes kind nodes already run and fs.inotify.max_user_instances is $max; Calico would crashloop with 'too many open files'. Run this where fewer kind clusters run, or with a higher limit."
    return 1
  fi
}

# cloud_calico_kind_up <cluster> <kind image> <calico version> <work dir>
# Creates the cluster with its kubeconfig at $KUBECONFIG, installs Calico and
# waits until the node is Ready and calico-apiserver serves the API. Prints
# the reason and returns 1 on failure.
cloud_calico_kind_up() {
  local cluster="$1" image="$2" version="$3" dir="$4"
  cat >"$dir/kind.yaml" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/16
EOF
  kind create cluster --name "$cluster" --image "$image" --config "$dir/kind.yaml" --kubeconfig "$KUBECONFIG" >"$dir/kind.log" 2>&1 \
    || { echo "FAIL: kind create cluster"; tail -20 "$dir/kind.log"; return 1; }
  # From 3.32 the chart ships no CRDs; the operator installs them on start
  # (stacks/calico). So the chart installs only the operator, and the
  # Installation and APIServer resources follow once their CRDs exist.
  helm install calico tigera-operator --repo https://docs.tigera.io/calico/charts --version "$version" \
    --namespace tigera-operator --create-namespace --kubeconfig "$KUBECONFIG" \
    --set installation.enabled=false --set apiServer.enabled=false --set goldmane.enabled=false --set whisker.enabled=false >"$dir/helm-calico.log" 2>&1 \
    || { echo "FAIL: helm install tigera-operator $version"; tail -20 "$dir/helm-calico.log"; return 1; }
  for _ in $(seq 1 100); do
    kubectl get crd installations.operator.tigera.io apiservers.operator.tigera.io >/dev/null 2>&1 && break
    sleep 3
  done
  kubectl wait --for=condition=Established crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io --timeout=60s >/dev/null \
    || { echo "FAIL: tigera-operator did not install its CRDs"; kubectl get pods -A; return 1; }
  cat <<'EOF' | kubectl apply -f - >/dev/null || { echo "FAIL: Installation and APIServer"; return 1; }
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - cidr: 10.244.0.0/16
      encapsulation: VXLAN
      natOutgoing: Enabled
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
  for _ in $(seq 1 120); do
    kubectl get tiers.projectcalico.org default >/dev/null 2>&1 \
      && [ "$(kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = "True" ] \
      && [ "$(kubectl get tigerastatus apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = "True" ] && break
    sleep 5
  done
  if ! kubectl get tiers.projectcalico.org default >/dev/null 2>&1; then
    echo "FAIL: Calico $version and its API server did not become available"
    kubectl get tigerastatus 2>&1; kubectl get pods -A 2>&1 | grep -v Running; return 1
  fi
  kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null || { echo "FAIL: node not Ready"; return 1; }
}

# Whether the aggregated projectcalico.org API is Available, the condition
# that drops when calico-apiserver fails its readiness check.
cloud_calico_api_available() {
  [ "$(kubectl get apiservice v3.projectcalico.org -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = "True" ]
}
