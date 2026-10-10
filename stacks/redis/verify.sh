# shellcheck shell=bash
# Verify checks for stacks/redis (docs/runbooks/verify-jobs.md). Redis runs
# without requirepass behind a namespace allowlist that includes verify.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="redis"
VERIFY_ALERTNAMES="^Redis"

RH=redis-master.redis.svc.cluster.local

_scratch() {
  local k out
  k="verify:probe:$(date +%s)"
  out=$(redis_session "$RH" 6379 "SELECT 15" "SET $k ok EX 60" "GET $k" "DEL $k") || { echo "$out"; return 1; }
  echo "$out" | tr '\n' ';'
  grep -q "GET $k => ok" <<<"$out" && grep -q "DEL $k => 1" <<<"$out"
}

_persistence() {
  local out
  out=$(redis_session "$RH" 6379 "INFO persistence") || return 1
  grep -oE '(loading|aof_enabled|aof_last_write_status|rdb_last_bgsave_status):[a-z0-9]+' <<<"$out" | tr '\n' ' '
  grep -q 'loading:0' <<<"$out" && grep -q 'aof_last_write_status:ok' <<<"$out" && grep -q 'rdb_last_bgsave_status:ok' <<<"$out"
}

_server() {
  local out
  out=$(redis_session "$RH" 6379 "INFO server" "INFO clients") || return 1
  grep -oE '(redis_version|connected_clients):[0-9.]+' <<<"$out" | tr '\n' ' '
  [ "$(grep -oE 'connected_clients:[0-9]+' <<<"$out" | cut -d: -f2)" -gt 20 ]
}

verify_component() {
  check "redis-v2 converged" retry 300 10 workload_ready redis statefulset/redis-v2
  check "PING" bash -c "exec 3<>/dev/tcp/$RH/6379 && printf 'PING\r\n' >&3 && read -r -t 5 r <&3 && echo \"\$r\" && [ \"\${r%\$'\r'}\" = '+PONG' ]"
  check "scratch key written, read, deleted in db 15" _scratch
  check "AOF and RDB persistence healthy" _persistence
  check "server answers and clients are connected" _server
  check "redis_exporter sees redis up" expect_prom 'max(redis_up{namespace="redis"})' -eq 1
  check "an Anubis-fronted site (Redis challenge store) answers" expect_ingress forgejo.viktorbarzin.me /api/healthz '200'
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "redis-backup Job completes" run_cronjob redis redis-backup 900
  fi
}
