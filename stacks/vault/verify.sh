# shellcheck shell=bash
# Verify checks for stacks/vault (docs/runbooks/verify-jobs.md).
# Vault rolls by hand (OnDelete), so convergence here means every pod is
# ready; the per-pod health below shows each one unsealed.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="vault"
VERIFY_ALERTNAMES="^Vault"

_pod_health() {
  local i code all=0
  for i in 0 1 2; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      "http://vault-$i.vault-internal.vault.svc.cluster.local:8200/v1/sys/health?standbyok=true&perfstandbyok=true")
    echo -n "vault-$i=$code "
    [ "$code" = 200 ] || all=1
  done
  echo
  return "$all"
}

_one_active() {
  local out
  out=$(curl -sS --max-time 10 http://vault-active.vault.svc.cluster.local:8200/v1/sys/health)
  echo "active: sealed=$(jq -r .sealed <<<"$out") standby=$(jq -r .standby <<<"$out") version=$(jq -r .version <<<"$out")"
  [ "$(jq -r .sealed <<<"$out")" = false ] && [ "$(jq -r .standby <<<"$out")" = false ]
}

_eso_reads_vault() {
  local t age
  t=$(kubectl get externalsecret -n verify verify-db-creds -o jsonpath='{.status.refreshTime}')
  age=$(age_seconds "$t")
  echo "ESO read database/static-creds via Vault ${age}s ago"
  [ "$age" -lt 300 ]
}

_stores_ready() {
  local s
  s=$(kubectl get clustersecretstores -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status} {end}')
  echo "stores: $s"
  ! grep -q '=False' <<<"$s" && grep -q 'vault-kv=True' <<<"$s" && grep -q 'vault-database=True' <<<"$s"
}

verify_component() {
  check "vault StatefulSet ready" retry 300 10 workload_ready vault statefulset/vault
  check "every pod initialised and unsealed" retry 300 15 _pod_health
  check "the active node answers" _one_active
  check "exactly one active node" expect_prom 'sum(vault_core_active)' -eq 1
  check "raft autopilot healthy" expect_prom 'max(vault_autopilot_healthy)' -eq 1
  check "raft tolerates one node loss" expect_prom 'max(vault_autopilot_failure_tolerance)' -ge 1
  check "ESO stores still Valid" _stores_ready
  check "ESO refreshed a Vault database credential recently" retry 300 30 _eso_reads_vault
  check "public endpoint answers health" expect_ingress vault.viktorbarzin.me /v1/sys/health '200|429|473'
}
