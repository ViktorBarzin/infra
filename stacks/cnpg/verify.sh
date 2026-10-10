# shellcheck shell=bash
# Verify checks for stacks/cnpg, the CloudNativePG operator
# (docs/runbooks/verify-jobs.md). pg-cluster itself is checked by
# stacks/dbaas/verify.sh; here the operator must keep it healthy.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="cnpg-system"
VERIFY_ALERTNAMES="^(CNPG.*|PostgreSQL.*|PgCluster.*)$"

_cluster_healthy() {
  local j
  j=$(kubectl get clusters.postgresql.cnpg.io -n dbaas pg-cluster -o json) || return 1
  jq -r '"phase=\(.status.phase) ready=\(.status.readyInstances)/\(.spec.instances) primary=\(.status.currentPrimary)"' <<<"$j"
  [ "$(jq -r '.status.phase' <<<"$j")" = "Cluster in healthy state" ] &&
    [ "$(jq -r '.status.readyInstances == .spec.instances' <<<"$j")" = true ]
}

_webhook_validates() {
  expect_dry_run_denied '{"apiVersion":"postgresql.cnpg.io/v1","kind":"Cluster","metadata":{"name":"verify-webhook-probe","namespace":"verify"},
    "spec":{"instances":1,"storage":{"size":"1Gi"},"postgresql":{"parameters":{"wal_level":"minimal"}}}}' 'wal_level'
}

verify_component() {
  check "operator converged" retry 300 10 workload_ready cnpg-system deployment/cnpg-cloudnative-pg
  check "pg-cluster healthy with every instance ready" retry 900 30 _cluster_healthy
  check "every instance's metrics exporter is up" expect_prom 'min(cnpg_collector_up{cluster="pg-cluster"})' -eq 1
  check "primary streams to every replica" expect_prom 'max(cnpg_pg_replication_streaming_replicas{cnpg_cluster="pg-cluster",cnpg_role="primary"}) - (count(cnpg_collector_up{cluster="pg-cluster"}) - 1)' -eq 0
  check "replication lag under 5 s" expect_prom 'max(cnpg_pg_replication_lag{cnpg_cluster="pg-cluster"})' -lt 5
  check "validating webhook refuses an invalid Cluster (dry run)" _webhook_validates
  check "no webhook or certificate errors in operator logs (15m)" expect_no_log_errors cnpg-system app.kubernetes.io/name=cloudnative-pg 'x509|webhook.*(error|fail)|panic'
}
