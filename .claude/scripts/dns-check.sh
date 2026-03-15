#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
AGENT="dns-check"
DRY_RUN=false

# Internal DNS server (Technitium)
INTERNAL_DNS="10.0.20.100"
# Public DNS
PUBLIC_DNS="1.1.1.1"

# Services to check
SERVICES=(
  "grafana.viktorbarzin.me"
  "prometheus.viktorbarzin.me"
  "nextcloud.viktorbarzin.me"
  "authentik.viktorbarzin.me"
  "viktorbarzin.me"
)

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

check_dns_resolution() {
  if $DRY_RUN; then
    add_check "dns-resolution" "ok" "dry-run: would resolve ${#SERVICES[@]} services via internal and public DNS"
    return
  fi

  local failures=0 mismatches=0 successes=0
  local failure_details="" mismatch_details=""

  for svc in "${SERVICES[@]}"; do
    local internal_result public_result

    internal_result=$(dig +short "$svc" @"$INTERNAL_DNS" A 2>/dev/null | head -1) || internal_result=""
    public_result=$(dig +short "$svc" @"$PUBLIC_DNS" A 2>/dev/null | head -1) || public_result=""

    if [ -z "$internal_result" ] && [ -z "$public_result" ]; then
      failures=$((failures + 1))
      failure_details="${failure_details}${svc} (both resolvers failed); "
    elif [ -z "$internal_result" ]; then
      failures=$((failures + 1))
      failure_details="${failure_details}${svc} (internal DNS failed); "
    elif [ -z "$public_result" ]; then
      # Public might use CNAME/proxy, not necessarily a failure
      successes=$((successes + 1))
    elif [ "$internal_result" != "$public_result" ]; then
      # Mismatch is informational — Cloudflare proxy IPs differ from internal IPs
      mismatches=$((mismatches + 1))
      mismatch_details="${mismatch_details}${svc} (internal=${internal_result} public=${public_result}); "
      successes=$((successes + 1))
    else
      successes=$((successes + 1))
    fi
  done

  if [ "$failures" -gt 0 ]; then
    add_check "dns-resolution" "fail" "${failures} DNS failures: ${failure_details}"
  elif [ "$mismatches" -gt 0 ]; then
    add_check "dns-resolution" "ok" "${successes}/${#SERVICES[@]} resolved. ${mismatches} internal/public mismatches (expected with Cloudflare proxy): ${mismatch_details}"
  else
    add_check "dns-resolution" "ok" "All ${successes}/${#SERVICES[@]} services resolved successfully"
  fi
}

check_technitium_health() {
  if $DRY_RUN; then
    add_check "technitium" "ok" "dry-run: would check Technitium DNS server pod health"
    return
  fi

  local tech_pods
  tech_pods=$($KUBECTL get pods -A -l app.kubernetes.io/name=technitium --no-headers 2>/dev/null) || \
  tech_pods=$($KUBECTL get pods -A --no-headers 2>/dev/null | grep -i technitium || true)

  if [ -z "$tech_pods" ]; then
    add_check "technitium" "warn" "No Technitium pods found"
    return
  fi

  local not_running
  not_running=$(echo "$tech_pods" | grep -v "Running" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "technitium" "fail" "Technitium pod(s) not running"
  else
    add_check "technitium" "ok" "Technitium DNS server pod(s) running"
  fi
}

check_coredns_health() {
  if $DRY_RUN; then
    add_check "coredns" "ok" "dry-run: would check CoreDNS pod health"
    return
  fi

  local coredns_pods
  coredns_pods=$($KUBECTL get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null) || {
    add_check "coredns" "warn" "Failed to query CoreDNS pods"
    return
  }

  if [ -z "$coredns_pods" ]; then
    add_check "coredns" "warn" "No CoreDNS pods found"
    return
  fi

  local total not_running
  total=$(echo "$coredns_pods" | grep -c "." 2>/dev/null || echo "0")
  not_running=$(echo "$coredns_pods" | grep -v "Running" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "coredns" "fail" "${not_running}/${total} CoreDNS pod(s) not running"
  else
    add_check "coredns" "ok" "All ${total} CoreDNS pod(s) running"
  fi
}

check_dns_resolution
check_technitium_health
check_coredns_health

# Output JSON
overall="ok"
for c in "${checks[@]}"; do
  s=$(echo "$c" | jq -r '.status')
  if [ "$s" = "fail" ]; then overall="fail"; break; fi
  if [ "$s" = "warn" ]; then overall="warn"; fi
done

printf '{"status": "%s", "agent": "%s", "checks": [%s]}\n' \
  "$overall" "$AGENT" "$(IFS=,; echo "${checks[*]}")"
