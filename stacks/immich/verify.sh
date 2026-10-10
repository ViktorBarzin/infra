# shellcheck shell=bash
# Verify checks for stacks/immich, whose Immich Postgres (vectorchord) is one
# of the database components (docs/runbooks/verify-jobs.md). The probe logs in
# with the Immich DB password from secret verify-app-creds and writes only to
# a scratch schema it drops.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="immich"
VERIFY_ALERTNAMES="^Immich"

PG_IMAGE=docker.io/library/postgres:16.15-trixie

PG_PROBE='
set -eu
export PGUSER=immich PGPASSWORD="$IMMICH_DB_PASSWORD" PGCONNECT_TIMEOUT=10 PGHOST=immich-postgresql.immich.svc.cluster.local PGDATABASE=immich
q() { psql -X -v ON_ERROR_STOP=1 -Atc "$1"; }
echo "server: $(q "show server_version")"
echo "extensions: $(q "select string_agg(extname || '"'"' '"'"' || extversion, '"'"', '"'"' order by extname) from pg_extension where extname in ('"'"'vchord'"'"', '"'"'vector'"'"')")"
[ "$(q "select count(*) from pg_extension where extname in ('"'"'vchord'"'"', '"'"'vector'"'"')")" = 2 ]
spl=$(q "show shared_preload_libraries"); echo "shared_preload_libraries: $spl"
case "$spl" in *vchord*) ;; *) echo "vchord not preloaded"; exit 1;; esac
idx=$(q "select string_agg(indexname, '"'"','"'"' order by indexname) from pg_indexes where indexdef ilike '"'"'%vchordrq%'"'"'")
echo "vchordrq indexes: $idx"
case "$idx" in *clip_index*) ;; *) echo "clip_index missing"; exit 1;; esac
n=$(q "select count(*) from (select 1 from smart_search order by embedding <=> (select embedding from smart_search limit 1) limit 5) x")
echo "ANN query over smart_search returned $n rows"
[ "$n" = 5 ]
S=verify_probe_$(date +%s)
q "create schema $S; create table $S.t (id int primary key, v text); insert into $S.t values (1, '"'"'ok'"'"')"
v=$(q "select v from $S.t where id = 1")
q "drop schema $S cascade"
echo "scratch schema written, read back ($v), dropped"
[ "$v" = ok ]
'

_pg_probe() { run_pod immich-pg-probe "$PG_IMAGE" "$PG_PROBE" secret=verify-app-creds timeout=240 memory=96Mi; }

_server_ping() { expect_body http://immich-server.immich.svc.cluster.local:2283/api/server/ping '"pong"'; }
_ml_ping() { expect_body http://immich-machine-learning.immich.svc.cluster.local:3003/ping 'pong'; }

_ml_textual() {
  # One CLIP textual inference (the smart-search path); the model name must
  # match MACHINE_LEARNING_PRELOAD__CLIP__TEXTUAL (stacks/immich/main.tf).
  local out
  out=$(curl -sS --max-time 120 -F 'entries={"clip":{"textual":{"modelName":"ViT-B-16-SigLIP2__webli"}}}' -F 'text=verify probe' \
    http://immich-machine-learning.immich.svc.cluster.local:3003/predict)
  echo "predict: $(printf '%s' "$out" | head -c 120)"
  grep -q '"clip"' <<<"$out"
}

verify_component() {
  check "immich-postgresql converged" retry 300 10 workload_ready immich deployment/immich-postgresql
  check "Postgres: vchord + vector loaded, vchordrq index answers ANN, scratch write/read/drop" _pg_probe
  check "immich-server answers ping" _server_ping
  check "machine-learning answers ping" _ml_ping
  check "machine-learning runs a CLIP textual inference" _ml_textual
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "postgresql-backup Job completes" run_cronjob immich postgresql-backup 1200
  fi
}
