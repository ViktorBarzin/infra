# shellcheck shell=bash
# Verify checks for stacks/external-secrets (docs/runbooks/verify-jobs.md).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="external-secrets"
VERIFY_ALERTNAMES="^(ExternalSecret.*|ESO.*)$"

_stores_ready() {
  local out
  out=$(kubectl get clustersecretstores -o json | jq -r '
    [.items[] | {n:.metadata.name, r:([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown")}] as $a
    | "stores: \($a | map("\(.n)=\(.r)") | join(" "))", (if ($a|length) >= 2 and all($a[]; .r=="True") then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_all_synced() {
  local out
  out=$(kubectl get externalsecrets -A -o json | jq -r '
    [.items[] | {n:"\(.metadata.namespace)/\(.metadata.name)", r:([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown")}] as $a
    | [$a[] | select(.r != "True") | .n] as $bad
    | "externalsecrets=\($a|length) not ready=\($bad)", (if ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_fresh_sync() {
  # verify-db-creds refreshes every 2 minutes from the Vault database engine,
  # so a refresh newer than 5 minutes proves the controller is syncing now.
  local t age
  t=$(kubectl get externalsecret -n verify verify-db-creds -o jsonpath='{.status.refreshTime}')
  age=$(age_seconds "$t")
  echo "verify/verify-db-creds refreshed $t (${age}s ago)"
  [ "$age" -lt 300 ]
}

_webhook_admits() {
  local out
  out=$(jq -n '{apiVersion:"external-secrets.io/v1",kind:"ExternalSecret",
    metadata:{name:"verify-webhook-probe",namespace:"verify"},
    spec:{refreshInterval:"1h",secretStoreRef:{name:"vault-kv",kind:"ClusterSecretStore"},
          target:{name:"verify-webhook-probe"},data:[{secretKey:"x",remoteRef:{key:"immich",property:"db_password"}}]}}' |
    kubectl create --dry-run=server -f - 2>&1)
  # The validating webhook has failurePolicy Fail, so admission proves it answered.
  echo "$out"
  grep -q 'created (server dry run)' <<<"$out"
}

_no_provider_errors() {
  # Errors other than API-server write conflicts and etcd timeouts, which
  # come from pre-existing etcd latency on k8s-master, not from ESO.
  local hits
  hits=$(kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --since=15m --tail=5000 2>/dev/null |
    grep '"level":"error"' | grep -Ev 'etcdserver: request timed out|the object has been modified|context deadline exceeded.*status' | sed -n 1,3p)
  if [ -n "$hits" ]; then echo "$hits" | cut -c1-300; return 1; fi
  echo "no provider errors in 15m"
}

verify_component() {
  check "controller converged" retry 300 10 workload_ready external-secrets deployment/external-secrets
  check "webhook converged" retry 300 10 workload_ready external-secrets deployment/external-secrets-webhook
  check "cert-controller converged" retry 300 10 workload_ready external-secrets deployment/external-secrets-cert-controller
  check "ClusterSecretStores vault-kv and vault-database Ready" _stores_ready
  check "every ExternalSecret is Ready" retry 300 30 _all_synced
  check "a 2-minute ExternalSecret refreshed from Vault recently" retry 300 30 _fresh_sync
  check "validating webhook admits a valid ExternalSecret (dry run)" _webhook_admits
  check "no provider or Vault errors in controller logs (15m)" _no_provider_errors
}
