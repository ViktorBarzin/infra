#!/bin/bash
# Tests for scripts/cloud-drain-handoff.sh. kubectl is a stub that answers
# the pod list and Deployment reads from fixtures and records every call.
# Run: bash scripts/cloud-drain-handoff.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
export WORK
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

pod() { # <ns> <deployment> <hash> [owner kind]
  jq -n --arg ns "$1" --arg d "$2" --arg h "$3" --arg k "${4:-ReplicaSet}" \
    '{metadata:{namespace:$ns,name:"\($d)-\($h)-x1",labels:{"pod-template-hash":$h},
      ownerReferences:[{kind:$k,name:"\($d)-\($h)"}]}}'
}
deploy() { # <ns> <name> <replicas> <strategy> [available] [updated]
  jq -n --arg ns "$1" --arg n "$2" --argjson r "$3" --arg s "$4" --argjson a "${5:-$3}" --argjson u "${6:-$3}" \
    '{metadata:{namespace:$ns,name:$n},spec:{replicas:$r,strategy:{type:$s}},
      status:{availableReplicas:$a,updatedReplicas:$u}}' >"$WORK/deploy-$1-$2.json"
}

# node5 runs: a Project's App, edge and oauth2-proxy (one pod each), a second
# pod of the same App (a rollout in flight), the console (2 pods), the
# reconciler (Recreate), a homelab Deployment, a p-* pod with no
# Deployment and a terminating App pod of another Project.
{
  pod p-shop app-shop 7c9f
  pod p-shop app-shop 7c9f
  pod p-shop edge-shop 5d4b
  pod p-shop auth-shop 6f8a
  pod cloud cloud 76c5
  pod cloud cloud-reconciler 647b
  pod immich immich-server 1a2b
  pod p-shop seed-job-x 9z9z Job
  pod p-gone app-gone 3e3e | jq '.metadata.deletionTimestamp = "2026-11-16T02:00:00Z"'
  pod p-down app-down 4d4d
  pod p-roll app-roll 8e8e
} | jq -s '{items: .}' >"$WORK/pods.json"
deploy p-shop app-shop 1 RollingUpdate
deploy p-shop edge-shop 1 RollingUpdate
deploy p-shop auth-shop 1 RollingUpdate
deploy cloud cloud 2 RollingUpdate
deploy cloud cloud-reconciler 1 Recreate
deploy immich immich-server 1 RollingUpdate
deploy p-gone app-gone 1 RollingUpdate
# Down (no pod available), and mid-rollout (the new pod not updated yet).
deploy p-down app-down 1 RollingUpdate 0 1
deploy p-roll app-roll 1 RollingUpdate 1 0

cat >"$WORK/kubectl" <<'STUB'
#!/bin/bash
echo "$*" >>"$CALLS"
if [ "$1 $2 $3" = "get pods -A" ]; then
  [ "$4 $5" = "--field-selector spec.nodeName=k8s-node5" ] && cat "$WORK/pods.json" || echo '{"items":[]}'
  exit 0
fi
ns=$2
case "$3 $4" in
  "get deployment") f="$WORK/deploy-$ns-$5.json"; [ -f "$f" ] && cat "$f" || exit 1 ;;
  "rollout restart") exit 0 ;;
  "rollout status") case " $NOT_READY " in *" $ns/${5#deployment/} "*) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/kubectl"

run() { # <expr> -> output; calls in $WORK/calls
  : >"$WORK/calls"
  CALLS="$WORK/calls" NOT_READY="${NOT_READY:-}" KUBECTL="$WORK/kubectl" \
    bash -c ". '$HERE/cloud-drain-handoff.sh'; $1"
}

out=$(run 'cloud_drain_targets k8s-node5')
want=$'p-shop app-shop\np-shop auth-shop\np-shop edge-shop'
[ "$out" = "$want" ] && ok "targets are the one-pod RollingUpdate Deployments in cloud and p-*, once each" \
  || bad "targets: got [$out]"

out=$(run 'cloud_drain_handoff k8s-node5 30'); rc=$?
[ $rc -eq 0 ] && ok "handoff succeeds when every new pod is Ready" || bad "handoff rc=$rc: $out"
restarts=$(grep -c "rollout restart" "$WORK/calls")
[ "$restarts" -eq 3 ] && ok "three restarts" || bad "restarts=$restarts: $(cat "$WORK/calls")"
grep -q "^-n p-shop rollout restart deployment/app-shop$" "$WORK/calls" && ok "the App restarts" || bad "no App restart"
! grep -q "cloud-reconciler\|immich\|deployment/cloud$\|app-gone\|seed-job" <(grep "rollout" "$WORK/calls") \
  && ok "console, reconciler, homelab, Job and terminating pods are left alone" || bad "touched: $(grep rollout "$WORK/calls")"
! grep -q "app-down\|app-roll" <(grep "rollout" "$WORK/calls") \
  && ok "a Deployment that is down or mid-rollout is left alone" || bad "touched: $(grep rollout "$WORK/calls")"
last_restart=$(grep -n "rollout restart" "$WORK/calls" | tail -1 | cut -d: -f1)
first_status=$(grep -n "rollout status" "$WORK/calls" | head -1 | cut -d: -f1)
[ "$last_restart" -lt "$first_status" ] && ok "all restarts start before the first wait" || bad "order: $(cat "$WORK/calls")"
grep -q "rollout status deployment/edge-shop --timeout=[0-9]*s" "$WORK/calls" && ok "waits carry a timeout" || bad "no timeout"

out=$(NOT_READY="p-shop/edge-shop" run 'cloud_drain_handoff k8s-node5 30'); rc=$?
[ $rc -eq 1 ] && ok "a Deployment not ready in time fails the handoff" || bad "rc=$rc"
grep -q "rollout status deployment/auth-shop" "$WORK/calls" && ok "the others are still waited for" || bad "stopped early"
echo "$out" | grep -q "p-shop/edge-shop not ready in time" && ok "says which one" || bad "message: $out"

out=$(run 'cloud_drain_handoff k8s-node1 30'); rc=$?
[ $rc -eq 0 ] && ! grep -q rollout "$WORK/calls" && ok "a node with no Cloud pod restarts nothing" || bad "empty node rc=$rc"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
