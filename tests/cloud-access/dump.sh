#!/usr/bin/env bash
# Run by cloud-access.test.sh from inside `tofu test` (a terraform_data
# local-exec that depends on every module), after Cloud's modules have
# written a Project into the kind cluster and before the test destroys it.
# Waits until each Deployment's ReplicaSet has had the chance to create its
# pod, then saves every object in the Project namespace, the namespace and
# the namespace's events as admin.
#
# Environment: ADMIN_KUBECONFIG, CLOUD_NAMESPACE, CLOUD_DUMP_DIR.
set -uo pipefail
k() { kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"; }
ns="$CLOUD_NAMESPACE"
want="$(k get deployments -n "$ns" -o name | wc -l)"
for _ in $(seq 1 60); do
  have="$(k get pods -n "$ns" -o name | wc -l)"
  failed="$(k get events -n "$ns" --field-selector reason=FailedCreate -o name | wc -l)"
  [ "$have" -ge "$want" ] && break
  [ "$failed" -gt 0 ] && break
  sleep 1
done
k get namespace "$ns" -o json >"$CLOUD_DUMP_DIR/namespace.json"
k get deployments,services,ingresses,configmaps,serviceaccounts,rolebindings,resourcequotas,limitranges,externalsecrets,secretstores,networkpolicies.projectcalico.org,pods \
  -n "$ns" -o json >"$CLOUD_DUMP_DIR/objects.json"
k get events -n "$ns" -o json >"$CLOUD_DUMP_DIR/events.json"
