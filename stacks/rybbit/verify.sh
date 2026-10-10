# shellcheck shell=bash
# Verify checks for stacks/rybbit, whose ClickHouse is one of the database
# components (docs/runbooks/verify-jobs.md). The probe uses the HTTP interface
# with the password from secret verify-app-creds (in the Job's environment)
# and writes only to a scratch database it drops.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="rybbit"
VERIFY_ALERTNAMES="^(ClickHouse.*|Rybbit.*)$"

CH="http://clickhouse.rybbit.svc.cluster.local:8123"

ch() { curl -sS --fail-with-body --max-time 60 -u "default:$CLICKHOUSE_PASSWORD" "$CH/" --data-binary "$1"; }

_version() { echo "version $(ch 'SELECT version()')"; }

_data() {
  local n d
  n=$(ch 'SELECT count() FROM clickhouse.events') || return 1
  d=$(ch 'SELECT count() FROM system.detached_parts') || return 1
  echo "events=$n detached_parts=$d"
  [ "$n" -gt 0 ] && [ "$d" -eq 0 ]
}

_scratch() {
  local t r
  t="verify_probe.t_$(date +%s)"
  ch 'CREATE DATABASE IF NOT EXISTS verify_probe' >/dev/null || return 1
  ch "CREATE TABLE $t (t DateTime, m Map(String, String), s LowCardinality(String)) ENGINE = MergeTree ORDER BY t" >/dev/null || return 1
  ch "INSERT INTO $t VALUES (now(), map('a','b'), 'p'), (now(), map('a','b'), 'q')" >/dev/null || return 1
  ch "OPTIMIZE TABLE $t FINAL" >/dev/null || return 1
  r=$(ch "SELECT count(), any(m['a']) FROM $t FORMAT TSV")
  ch "DROP TABLE $t SYNC" >/dev/null
  ch 'DROP DATABASE IF EXISTS verify_probe SYNC' >/dev/null
  echo "scratch MergeTree: $r (want 2 b), dropped"
  [ "$(printf '%s' "$r" | tr '\t' ' ')" = "2 b" ]
}

verify_component() {
  check "clickhouse converged" retry 300 10 workload_ready rybbit deployment/clickhouse
  check "ClickHouse answers" _version
  check "events table readable, no detached parts" _data
  check "scratch table written, merged, read, dropped" _scratch
  check "ClickHouse metrics reach Prometheus" expect_series 'ClickHouseMetrics_Query' 1
  check "rybbit backend healthy against ClickHouse" expect_http http://rybbit.rybbit.svc.cluster.local/api/health '200'
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "clickhouse-backup Job completes" run_cronjob rybbit clickhouse-backup 900
  fi
}
