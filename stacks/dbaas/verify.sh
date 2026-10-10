# shellcheck shell=bash
# Verify checks for stacks/dbaas: the CNPG pg-cluster and mysql-standalone
# (docs/runbooks/verify-jobs.md; software-currency design, Verification
# contract, Databases row). Probes log in as verify_probe with the Vault
# static-role passwords in secret verify-db-creds; they write only to the
# verify_probe scratch database.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="dbaas"
VERIFY_ALERTNAMES="^(CNPG.*|PostgreSQL.*|PgCluster.*|Mysql.*|MySQL.*)$"

PG_IMAGE=docker.io/library/postgres:16.15-trixie
MYSQL_IMAGE=docker.io/library/mysql:8.4.8
# Apps on MySQL (Vault static roles and the static users in stacks/dbaas).
MYSQL_APP_NAMESPACES="forgejo mailserver nextcloud monitoring speedtest realestate-crawler hackmd technitium phpipam"

_cluster_healthy() {
  local j
  j=$(kubectl get clusters.postgresql.cnpg.io -n dbaas pg-cluster -o json) || return 1
  jq -r '"phase=\(.status.phase) ready=\(.status.readyInstances)/\(.spec.instances) primary=\(.status.currentPrimary) image=\(.spec.imageName)"' <<<"$j"
  [ "$(jq -r '.status.phase' <<<"$j")" = "Cluster in healthy state" ] &&
    [ "$(jq -r '.status.readyInstances == .spec.instances' <<<"$j")" = true ]
}

# One client pod runs the whole pg probe so the scratch write, the replica
# read-back and the drop share one session timeline.
PG_PROBE='
set -eu
export PGUSER=verify_probe PGPASSWORD="$PG_VERIFY_PASSWORD" PGCONNECT_TIMEOUT=10
RW=pg-cluster-rw.dbaas.svc.cluster.local
RO=pg-cluster-ro.dbaas.svc.cluster.local
q() { psql -X -v ON_ERROR_STOP=1 -h "$1" -d "$2" -Atc "$3"; }
echo "server: $(q $RW verify_probe "show server_version")"
want=$(q $RW verify_probe "select count(*) from pg_stat_replication where state = '"'"'streaming'"'"'")
echo "streaming replicas: $want"
[ "$want" -ge 1 ]
T=probe_$(date +%s)
q $RW verify_probe "create table $T (id int primary key, v text)"
q $RW verify_probe "insert into $T values (1, '"'"'ok'"'"')"
lsn=$(q $RW verify_probe "select pg_current_wal_lsn()")
i=0
until [ "$(q $RW verify_probe "select count(*) from pg_stat_replication where replay_lsn >= '"'"'$lsn'"'"'")" -ge "$want" ]; do
  i=$((i+1)); [ $i -lt 30 ] || { echo "replicas did not replay $lsn within 30s"; q $RW verify_probe "drop table $T"; exit 1; }
  sleep 1
done
echo "all $want replicas replayed $lsn after ${i}s (lag 0)"
v=$(q $RO verify_probe "select v from $T where id = 1")
echo "read back on a replica: $v"
q $RW verify_probe "drop table $T"
[ "$v" = ok ]
echo "scratch table written, read on replica, dropped"
d=$(q $RW dawarich "select postgis_lib_version() || '"'"' '"'"' || round(ST_Distance('"'"'SRID=4326;POINT(0 51.5)'"'"'::geography, '"'"'SRID=4326;POINT(-0.12 51.5)'"'"'::geography))")
echo "postgis (dawarich): $d"
case "$d" in *" 83"[0-9][0-9]) ;; *) echo "unexpected ST_Distance"; exit 1;; esac
vv=$(q $RW claude_memory "select '"'"'[1,2,3]'"'"'::vector <-> '"'"'[1,2,4]'"'"'::vector")
echo "pgvector (claude_memory): distance $vv"
[ "$vv" = 1 ]
'

MYSQL_PROBE='
set -eu
m() { MYSQL_PWD="$MYSQL_VERIFY_PASSWORD" mysql -h mysql.dbaas.svc.cluster.local -u verify_probe --connect-timeout=10 -N -B verify_probe -e "$1"; }
echo "server: $(m "select version()")"
T=probe_$(date +%s)
m "create table $T (id int primary key, v varchar(8))"
m "insert into $T values (1, '"'"'ok'"'"')"
v=$(m "select v from $T where id = 1")
m "drop table $T"
echo "scratch table written, read back ($v), dropped"
[ "$v" = ok ]
'

_pg_probe() { run_pod pg-probe "$PG_IMAGE" "$PG_PROBE" secret=verify-db-creds timeout=240 memory=96Mi; }
_mysql_probe() { run_pod mysql-probe "$MYSQL_IMAGE" "$MYSQL_PROBE" secret=verify-db-creds timeout=300 memory=256Mi; }

_pg_apps() {
  # Namespaces named after pg-cluster databases (underscores as dashes), plus
  # apps whose namespace differs from the database name.
  local dbs
  dbs=$(kubectl get clusters.postgresql.cnpg.io -n dbaas pg-cluster >/dev/null && \
    run_pod pg-dblist "$PG_IMAGE" 'PGPASSWORD="$PG_VERIFY_PASSWORD" psql -X -h pg-cluster-rw.dbaas.svc.cluster.local -U verify_probe -d verify_probe -Atc "select datname from pg_database where datallowconn and not datistemplate"' secret=verify-db-creds timeout=120 memory=96Mi) || { echo "cannot list databases"; return 1; }
  # shellcheck disable=SC2046
  apps_healthy $(printf '%s\n' "$dbs" | grep -Ev '^(postgres|verify_probe|immich|terraform_state)$' | tr '_' '-') trading-bot
}

_backups() {
  # The backup job runs successfully on the running version: one PostgreSQL
  # and one MySQL dump, started together (about 14 and 16 minutes).
  local pg_out my_out pg_rc my_rc
  pg_out=$(mktemp); my_out=$(mktemp)
  run_cronjob dbaas postgresql-backup 2400 >"$pg_out" 2>&1 & local p1=$!
  run_cronjob dbaas mysql-backup 2400 >"$my_out" 2>&1 & local p2=$!
  wait "$p1"; pg_rc=$?
  wait "$p2"; my_rc=$?
  if [ "$pg_rc" -eq 0 ]; then pass "postgresql-backup Job completed" "$(tail -c 300 "$pg_out" | _oneline 250)"; else fail "postgresql-backup Job" "$(tail -c 600 "$pg_out" | _oneline 500)"; fi
  if [ "$my_rc" -eq 0 ]; then pass "mysql-backup Job completed" "$(tail -c 300 "$my_out" | _oneline 250)"; else fail "mysql-backup Job" "$(tail -c 600 "$my_out" | _oneline 500)"; fi
}

verify_component() {
  check "pg-cluster healthy with every instance ready" retry 900 30 _cluster_healthy
  check "every instance's metrics exporter is up" expect_prom 'min(cnpg_collector_up{cluster="pg-cluster"})' -eq 1
  check "pg: scratch write, replica read-back at lag 0, PostGIS and pgvector answer" _pg_probe
  check "mysql-standalone converged" retry 300 10 workload_ready dbaas statefulset/mysql-standalone
  check "mysqld_exporter sees MySQL up" expect_prom 'max(mysql_up)' -eq 1
  check "mysql: scratch write, read back, drop" _mysql_probe
  check "apps on pg-cluster are healthy" _pg_apps
  # shellcheck disable=SC2086
  check "apps on MySQL are healthy" apps_healthy $MYSQL_APP_NAMESPACES
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    _backups
  fi
}
