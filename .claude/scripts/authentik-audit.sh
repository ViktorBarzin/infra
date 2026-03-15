#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
AGENT="authentik-audit"
DRY_RUN=false
NAMESPACE="authentik"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

checks=()

add_check() {
  local name="$1" status="$2" message="$3"
  checks+=("{\"name\": \"$name\", \"status\": \"$status\", \"message\": \"$message\"}")
}

find_authentik_pod() {
  local pod
  pod=$($KUBECTL get pods -n "$NAMESPACE" -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || \
  pod=$($KUBECTL get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -i "goauthentik-server\|authentik-server" | grep "Running" | head -1 | awk '{print $1}') || true
  echo "$pod"
}

check_server_health() {
  if $DRY_RUN; then
    add_check "authentik-server" "ok" "dry-run: would check goauthentik-server pod health"
    return
  fi

  local pods
  pods=$($KUBECTL get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -i "authentik") || {
    add_check "authentik-server" "fail" "No Authentik pods found in namespace ${NAMESPACE}"
    return
  }

  local not_running
  not_running=$(echo "$pods" | grep -v "Running" | grep -v "Completed" | grep -c "." 2>/dev/null || echo "0")

  local total
  total=$(echo "$pods" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "authentik-server" "warn" "${not_running}/${total} Authentik pod(s) not running"
  else
    add_check "authentik-server" "ok" "All ${total} Authentik pod(s) running"
  fi
}

check_outposts() {
  if $DRY_RUN; then
    add_check "authentik-outposts" "ok" "dry-run: would check Authentik outpost pods"
    return
  fi

  local outpost_pods
  outpost_pods=$($KUBECTL get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=goauthentik.io --no-headers 2>/dev/null) || \
  outpost_pods=$($KUBECTL get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -i "outpost" || true)

  if [ -z "$outpost_pods" ]; then
    add_check "authentik-outposts" "warn" "No outpost pods found"
    return
  fi

  local total not_running
  total=$(echo "$outpost_pods" | grep -c "." 2>/dev/null || echo "0")
  not_running=$(echo "$outpost_pods" | grep -v "Running" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "authentik-outposts" "warn" "${not_running}/${total} outpost pod(s) not running"
  else
    add_check "authentik-outposts" "ok" "All ${total} outpost pod(s) running"
  fi
}

check_user_count() {
  if $DRY_RUN; then
    add_check "authentik-users" "ok" "dry-run: would check user count via ak CLI"
    return
  fi

  local pod
  pod=$(find_authentik_pod)

  if [ -z "$pod" ]; then
    add_check "authentik-users" "warn" "No Authentik server pod found to query users"
    return
  fi

  # Use the ak CLI to get user count
  local user_output
  user_output=$($KUBECTL exec -n "$NAMESPACE" "$pod" -- ak user list 2>/dev/null) || {
    # Fallback: try management command
    user_output=$($KUBECTL exec -n "$NAMESPACE" "$pod" -- python -c "
import django; django.setup()
from authentik.core.models import User
print(f'total={User.objects.count()} active={User.objects.filter(is_active=True).count()}')
" 2>/dev/null) || {
      add_check "authentik-users" "warn" "Could not query user count from Authentik"
      return
    }
  }

  local user_count
  if echo "$user_output" | grep -q "total="; then
    user_count=$(echo "$user_output" | grep "total=" | sed 's/.*total=\([0-9]*\).*/\1/')
    local active_count
    active_count=$(echo "$user_output" | grep "active=" | sed 's/.*active=\([0-9]*\).*/\1/')
    add_check "authentik-users" "ok" "${user_count} total users, ${active_count} active"
  else
    # Count lines of output as fallback
    user_count=$(echo "$user_output" | wc -l | tr -d ' ')
    add_check "authentik-users" "ok" "User query returned ${user_count} lines of output"
  fi
}

check_server_health
check_outposts
check_user_count

# Output JSON
overall="ok"
for c in "${checks[@]}"; do
  s=$(echo "$c" | jq -r '.status')
  if [ "$s" = "fail" ]; then overall="fail"; break; fi
  if [ "$s" = "warn" ]; then overall="warn"; fi
done

printf '{"status": "%s", "agent": "%s", "checks": [%s]}\n' \
  "$overall" "$AGENT" "$(IFS=,; echo "${checks[*]}")"
