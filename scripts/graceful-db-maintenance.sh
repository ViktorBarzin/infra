#!/usr/bin/env bash
# graceful-db-maintenance.sh — Scale down/up dependents of a service
# based on the dependency.kyverno.io/wait-for pod annotation.
#
# Usage:
#   ./scripts/graceful-db-maintenance.sh shutdown mysql.dbaas
#   # ... perform maintenance ...
#   ./scripts/graceful-db-maintenance.sh startup mysql.dbaas
#
# The shutdown action saves original replica counts to a state file
# so startup can restore them exactly.

set -euo pipefail

ACTION="${1:-}"
SERVICE="${2:-}"
STATE_DIR="/tmp"

usage() {
  echo "Usage: $0 <shutdown|startup> <service>"
  echo ""
  echo "Examples:"
  echo "  $0 shutdown mysql.dbaas      # Scale down all MySQL dependents"
  echo "  $0 startup  mysql.dbaas      # Restore all MySQL dependents"
  echo "  $0 shutdown postgresql.dbaas  # Scale down all PostgreSQL dependents"
  echo "  $0 shutdown redis.redis       # Scale down all Redis dependents"
  exit 1
}

[[ -z "$ACTION" || -z "$SERVICE" ]] && usage
[[ "$ACTION" != "shutdown" && "$ACTION" != "startup" ]] && usage

STATE_FILE="${STATE_DIR}/dep-maintenance-$(echo "$SERVICE" | tr '.' '-').json"
KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/../config}"
export KUBECONFIG

# Find all pods with the dependency annotation containing our service
find_dependent_owners() {
  local service="$1"
  kubectl get pods --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.annotations.dependency\.kyverno\.io/wait-for}{"\t"}{.metadata.ownerReferences[0].kind}{"\t"}{.metadata.ownerReferences[0].name}{"\n"}{end}' \
    2>/dev/null | \
    grep "$service" | \
    while IFS=$'\t' read -r ns annotation owner_kind owner_name; do
      [[ -z "$owner_kind" || -z "$owner_name" ]] && continue
      # Resolve ReplicaSet -> Deployment
      if [[ "$owner_kind" == "ReplicaSet" ]]; then
        deploy_name=$(kubectl get replicaset "$owner_name" -n "$ns" \
          -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
        if [[ -n "$deploy_name" ]]; then
          echo "Deployment/${deploy_name}/${ns}"
        fi
      elif [[ "$owner_kind" == "StatefulSet" ]]; then
        echo "StatefulSet/${owner_name}/${ns}"
      fi
    done | sort -u
}

do_shutdown() {
  echo "Finding dependents of $SERVICE..."
  local owners
  owners=$(find_dependent_owners "$SERVICE")

  if [[ -z "$owners" ]]; then
    echo "No dependents found for $SERVICE"
    exit 0
  fi

  echo "Dependents found:"
  echo "$owners" | while IFS='/' read -r kind name ns; do
    echo "  $ns/$kind/$name"
  done

  # Save current replica counts
  local state="[]"
  while IFS='/' read -r kind name ns; do
    replicas=$(kubectl get "$kind" "$name" -n "$ns" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    state=$(echo "$state" | jq --arg kind "$kind" --arg name "$name" \
      --arg ns "$ns" --argjson replicas "${replicas:-1}" \
      '. + [{"kind": $kind, "name": $name, "namespace": $ns, "replicas": $replicas}]')
  done <<< "$owners"

  echo "$state" > "$STATE_FILE"
  echo "Saved replica state to $STATE_FILE"

  # Scale down
  while IFS='/' read -r kind name ns; do
    echo "Scaling $ns/$kind/$name to 0..."
    kubectl scale "$kind" "$name" -n "$ns" --replicas=0
  done <<< "$owners"

  echo ""
  echo "Waiting for pods to terminate..."
  while IFS='/' read -r kind name ns; do
    kubectl rollout status "$kind" "$name" -n "$ns" --timeout=120s 2>/dev/null || true
  done <<< "$owners"

  echo ""
  echo "All dependents of $SERVICE scaled to 0."
  echo "Run '$0 startup $SERVICE' after maintenance to restore."
}

do_startup() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "Error: No state file found at $STATE_FILE"
    echo "Did you run '$0 shutdown $SERVICE' first?"
    exit 1
  fi

  echo "Restoring dependents of $SERVICE from $STATE_FILE..."

  local count
  count=$(jq length "$STATE_FILE")

  for ((i = 0; i < count; i++)); do
    kind=$(jq -r ".[$i].kind" "$STATE_FILE")
    name=$(jq -r ".[$i].name" "$STATE_FILE")
    ns=$(jq -r ".[$i].namespace" "$STATE_FILE")
    replicas=$(jq -r ".[$i].replicas" "$STATE_FILE")

    echo "Scaling $ns/$kind/$name to $replicas..."
    kubectl scale "$kind" "$name" -n "$ns" --replicas="$replicas"
  done

  echo ""
  echo "Waiting for rollouts..."
  for ((i = 0; i < count; i++)); do
    kind=$(jq -r ".[$i].kind" "$STATE_FILE")
    name=$(jq -r ".[$i].name" "$STATE_FILE")
    ns=$(jq -r ".[$i].namespace" "$STATE_FILE")
    kubectl rollout status "$kind" "$name" -n "$ns" --timeout=300s 2>/dev/null || true
  done

  rm -f "$STATE_FILE"
  echo ""
  echo "All dependents of $SERVICE restored."
}

case "$ACTION" in
  shutdown) do_shutdown ;;
  startup)  do_startup ;;
esac
