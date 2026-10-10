# shellcheck shell=bash
# Verify checks for stacks/sealed-secrets (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="sealed-secrets"
VERIFY_ALERTNAMES="^SealedSecrets"

_cert_served() {
  local pem
  pem=$(curl -sS --max-time 10 http://sealed-secrets.sealed-secrets.svc.cluster.local:8080/v1/cert.pem)
  printf '%s\n' "$pem" | openssl x509 -noout -subject -enddate 2>&1 | tr '\n' ' '
  printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1
}

_keys_loaded() {
  local pod logs n
  pod=$(pod_of sealed-secrets app.kubernetes.io/name=sealed-secrets)
  logs=$(kubectl logs -n sealed-secrets "$pod")
  n=$(grep -c 'registered private key' <<<"$logs")
  echo "registered private keys at startup: $n"
  [ "$n" -ge 1 ] && ! grep -q 'level=ERROR' <<<"$logs"
}

_build_info() {
  curl -sS --max-time 10 http://sealed-secrets-metrics.sealed-secrets.svc.cluster.local:8081/metrics | grep '^sealed_secrets_controller_build_info'
}

_unseal_count_stable() {
  # Every SealedSecret in the cluster still unseals (Synced=True).
  kubectl get sealedsecrets -A -o json | jq -r '
    [.items[] | {n: "\(.metadata.namespace)/\(.metadata.name)", s: ([.status.conditions[]? | select(.type=="Synced")][0].status // "Unknown")}] as $a
    | "sealedsecrets=\($a|length) not synced=\([$a[] | select(.s != "True") | .n])", (if ([$a[] | select(.s != "True")] | length) == 0 then 0 else 1 end)' | {
    read -r msg; read -r code; echo "$msg"; return "$code"; }
}

verify_component() {
  check "controller deployment converged" retry 300 10 workload_ready sealed-secrets deployment/sealed-secrets
  check "controller serves a valid sealing certificate" _cert_served
  check "controller loaded its private keys without errors" _keys_loaded
  check "controller metrics answer" _build_info
  check "every SealedSecret is synced" _unseal_count_stable
}
