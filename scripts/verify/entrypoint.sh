#!/usr/bin/env bash
# Entrypoint of the verify Job pod. The runner (scripts/verify/run) mounts this
# file, lib.sh and the stack's verify.sh from a ConfigMap at /verify.
#
# Order: floor rollout (wait for convergence), floor ingress, the stack's own
# checks, then the floor alert watch, which runs last so it covers the window
# after everything else has settled.
set -uo pipefail

# shellcheck source=lib.sh
. /verify/lib.sh

VERIFY_NAMESPACES=""
VERIFY_GROUP="app"
# shellcheck disable=SC1091
. /verify/stack.sh

if [ -z "$VERIFY_NAMESPACES" ]; then
  echo "verify.sh for $VERIFY_STACK sets no VERIFY_NAMESPACES"
  echo "VERIFY RESULT: FAIL $VERIFY_STACK"
  exit 1
fi
if ! declare -F verify_component >/dev/null; then
  verify_component() { log "INFO  no component checks for $VERIFY_STACK (floor only)"; }
fi

log "verify stack=$VERIFY_STACK group=$VERIFY_GROUP namespaces=[$VERIFY_NAMESPACES] quick=${VERIFY_QUICK:-0} since=${VERIFY_SINCE:-0}"

section "floor: rollout"
floor_rollout
section "floor: ingress"
floor_ingress
section "component: $VERIFY_STACK"
verify_component
section "floor: alerts"
floor_alerts

summary
