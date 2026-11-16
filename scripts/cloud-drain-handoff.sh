#!/usr/bin/env bash
# cloud-drain-handoff — before a node drain evicts pods, start the next pod of
# each one-pod Cloud Deployment on another node (Cloud backlog B10).
#
# A drain evicts a pod first; only then does its Deployment start another.
# For a Deployment with one pod, such as a Cloud App, its edge or its
# oauth2-proxy, that is a gap as long as the new pod's start. A rollout
# restart on a cordoned node goes the other way round: RollingUpdate with
# maxSurge 1 and maxUnavailable 0 (what Cloud renders for all three) starts
# the new pod on a schedulable node and stops the old one once the new one
# is Ready. The drain that follows finds nothing of theirs left to evict.
#
# Scope: namespace `cloud` and every `p-*` namespace, Deployments with one
# replica and the RollingUpdate strategy. A Deployment with 2 or more pods
# (the console) keeps serving through its PodDisruptionBudget. A Recreate
# one (the reconciler) stops before it starts again, so a restart gains
# nothing. Pods with no Deployment are left to the drain.
#
# The caller cordons the node first, so the new pods cannot land on it.
# Cloud's App module ignores the restartedAt annotation, so the next apply
# of the Project does not roll the pods again.
#
# Sourced by the kured-sentinel-gate DaemonSet (stacks/kured, mounted at
# /scripts/cloud-drain-handoff.sh) and by stacks/k8s-version-upgrade's
# upgrade-step.sh. Tests: scripts/cloud-drain-handoff.test.sh.

KUBECTL=${KUBECTL:-kubectl}

# cloud_drain_targets <node> -> "<namespace> <deployment>" lines, one per
# one-pod RollingUpdate Cloud Deployment with a pod on <node>.
cloud_drain_targets() {
  local node="$1" ns name
  $KUBECTL get pods -A --field-selector "spec.nodeName=$node" -o json | jq -r '
    .items[]
    | select(.metadata.namespace == "cloud" or (.metadata.namespace | startswith("p-")))
    | select(.metadata.deletionTimestamp == null)
    | (.metadata.labels["pod-template-hash"] // "") as $hash
    | select($hash != "")
    | .metadata.namespace as $ns
    | (.metadata.ownerReferences // [])[]
    | select(.kind == "ReplicaSet" and (.name | endswith("-" + $hash)))
    | "\($ns) \(.name | .[0:(length - ($hash | length) - 1)])"' | sort -u |
    while read -r ns name; do
      [ -n "$name" ] || continue
      $KUBECTL -n "$ns" get deployment "$name" -o json 2>/dev/null | jq -r --arg ns "$ns" '
        select((.spec.replicas // 1) == 1 and (.spec.strategy.type // "RollingUpdate") == "RollingUpdate")
        | "\($ns) \(.metadata.name)"'
    done
}

# cloud_drain_handoff <node> [timeout seconds] -> 0 when every new pod is
# Ready in time, 1 otherwise. A Deployment that does not finish keeps its old
# pod; the drain then evicts it as it would have without this step.
cloud_drain_handoff() {
  local node="$1" timeout="${2:-240}" ns name left rc=0
  local -a targets=()
  while read -r ns name; do
    [ -n "$name" ] && targets+=("$ns $name")
  done < <(cloud_drain_targets "$node")
  if [ "${#targets[@]}" -eq 0 ]; then
    echo "cloud-drain-handoff: no one-pod Cloud Deployment on $node"
    return 0
  fi
  for t in "${targets[@]}"; do
    read -r ns name <<<"$t"
    echo "cloud-drain-handoff: restarting $ns/$name off $node"
    $KUBECTL -n "$ns" rollout restart "deployment/$name" || rc=1
  done
  local deadline=$((SECONDS + timeout))
  for t in "${targets[@]}"; do
    read -r ns name <<<"$t"
    left=$((deadline - SECONDS))
    [ "$left" -lt 1 ] && left=1
    if ! $KUBECTL -n "$ns" rollout status "deployment/$name" --timeout="${left}s"; then
      echo "cloud-drain-handoff: $ns/$name not ready in time; the drain evicts its old pod"
      rc=1
    fi
  done
  return $rc
}
