#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
AGENT="tls-check"
DRY_RUN=false
WARN_DAYS=14

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

check_tls_secrets() {
  if $DRY_RUN; then
    add_check "tls-secrets" "ok" "dry-run: would scan all kubernetes.io/tls secrets for expiry"
    return
  fi

  local secrets_json
  secrets_json=$($KUBECTL get secrets -A -o json 2>/dev/null) || {
    add_check "tls-secrets" "fail" "Failed to list secrets"
    return
  }

  local tls_secrets
  tls_secrets=$(echo "$secrets_json" | jq -r '.items[] | select(.type=="kubernetes.io/tls") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null) || {
    add_check "tls-secrets" "fail" "Failed to parse secrets JSON"
    return
  }

  if [ -z "$tls_secrets" ]; then
    add_check "tls-secrets" "warn" "No TLS secrets found"
    return
  fi

  local total=0 expiring=0 expired=0 healthy=0 errors=0
  local now_epoch
  now_epoch=$(date +%s)
  local warn_epoch=$((now_epoch + WARN_DAYS * 86400))
  local expiring_list=""

  while IFS= read -r secret; do
    total=$((total + 1))
    local ns="${secret%%/*}"
    local name="${secret##*/}"

    local cert_pem
    cert_pem=$($KUBECTL get secret "$name" -n "$ns" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null) || {
      errors=$((errors + 1))
      continue
    }

    local expiry_str
    expiry_str=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//') || {
      errors=$((errors + 1))
      continue
    }

    local expiry_epoch
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_str" +%s 2>/dev/null || date -d "$expiry_str" +%s 2>/dev/null) || {
      errors=$((errors + 1))
      continue
    }

    if [ "$expiry_epoch" -lt "$now_epoch" ]; then
      expired=$((expired + 1))
      expiring_list="${expiring_list}EXPIRED: ${ns}/${name}; "
    elif [ "$expiry_epoch" -lt "$warn_epoch" ]; then
      local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      expiring=$((expiring + 1))
      expiring_list="${expiring_list}${days_left}d: ${ns}/${name}; "
    else
      healthy=$((healthy + 1))
    fi
  done <<< "$tls_secrets"

  if [ "$expired" -gt 0 ]; then
    add_check "tls-secrets" "fail" "${expired} expired, ${expiring} expiring soon, ${healthy} healthy out of ${total} certs. ${expiring_list}"
  elif [ "$expiring" -gt 0 ]; then
    add_check "tls-secrets" "warn" "${expiring} expiring within ${WARN_DAYS}d, ${healthy} healthy out of ${total} certs. ${expiring_list}"
  else
    add_check "tls-secrets" "ok" "All ${healthy} TLS certs healthy (${errors} decode errors skipped)"
  fi
}

check_cert_manager() {
  if $DRY_RUN; then
    add_check "cert-manager" "ok" "dry-run: would check cert-manager pod health and certificate CRDs"
    return
  fi

  local cm_pods
  cm_pods=$($KUBECTL get pods -n cert-manager -l app.kubernetes.io/instance=cert-manager --no-headers 2>/dev/null) || {
    add_check "cert-manager" "fail" "Failed to query cert-manager pods"
    return
  }

  local not_running
  not_running=$(echo "$cm_pods" | grep -v "Running" | grep -v "Completed" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "cert-manager" "fail" "${not_running} cert-manager pod(s) not running"
    return
  fi

  # Check for failed certificates
  local failed_certs
  failed_certs=$($KUBECTL get certificates -A -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null) || {
    add_check "cert-manager" "warn" "Could not query certificate CRDs"
    return
  }

  if [ -n "$failed_certs" ]; then
    local count
    count=$(echo "$failed_certs" | wc -l | tr -d ' ')
    add_check "cert-manager" "warn" "${count} certificate(s) not ready: $(echo "$failed_certs" | head -5 | tr '\n' ', ')"
  else
    add_check "cert-manager" "ok" "cert-manager healthy, all certificates ready"
  fi
}

check_tls_secrets
check_cert_manager

# Output JSON
overall="ok"
for c in "${checks[@]}"; do
  s=$(echo "$c" | jq -r '.status')
  if [ "$s" = "fail" ]; then overall="fail"; break; fi
  if [ "$s" = "warn" ]; then overall="warn"; fi
done

printf '{"status": "%s", "agent": "%s", "checks": [%s]}\n' \
  "$overall" "$AGENT" "$(IFS=,; echo "${checks[*]}")"
