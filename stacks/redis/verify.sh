# shellcheck shell=bash
# Verify checks for stacks/redis (docs/runbooks/verify-jobs.md). Redis runs
# without requirepass behind a namespace allowlist that includes verify.
# Run it as a Job from the devvm: scripts/verify/run redis.
#
# ACL users (B40, modules/redis/acl.tf, docs/runbooks/redis-acl.md): the
# scratch check logs in as the verify user (REDIS_VERIFY_PASSWORD, from the
# verify-app-creds ExternalSecret in stacks/verify). The ACL checks read
# ACL LIST as the default user until R4, and the metrics redis-acl-sync
# pushes. The Job holds no other user's password: the sync job, which holds
# every one, proves each minute that every user can AUTH and PING, and this
# script reads that result from Prometheus. The user list is the
# redis-acl-sync ConfigMap's users.json, written from acl_users.json.
VERIFY_GROUP="db"
VERIFY_NAMESPACES="redis"
VERIFY_ALERTNAMES="^Redis"

RH=redis-master.redis.svc.cluster.local

# As the verify user; redis_session prints the AUTH line without the password.
_scratch() {
  local k out
  [ -n "${REDIS_VERIFY_PASSWORD:-}" ] || { echo "REDIS_VERIFY_PASSWORD unset (verify-app-creds)"; return 1; }
  k="verify:probe:$(date +%s)"
  out=$(redis_session "$RH" 6379 "AUTH verify $REDIS_VERIFY_PASSWORD" "SELECT 15" "SET $k ok EX 60" "GET $k" "DEL $k") || { echo "$out"; return 1; }
  echo "$out" | tr '\n' ';'
  grep -q "AUTH verify \*\*\* => OK" <<<"$out" && grep -q "GET $k => ok" <<<"$out" && grep -q "DEL $k => 1" <<<"$out"
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

_acl_users() {
  k get configmap redis-acl-sync -n redis -o jsonpath='{.data.users\.json}' | jq -r 'keys[]'
}

# ACL LIST on one connection, one user per line. As the default user, which
# holds +@all until B40 R4 locks it; R4 moves this to the verify user.
_acl_list() {
  local reply n i line
  exec 3<>"/dev/tcp/$RH/6379" || return 1
  printf 'ACL LIST\r\n' >&3
  IFS= read -r -t 10 reply <&3 || { echo "no reply to ACL LIST"; exec 3>&-; return 1; }
  reply=${reply%$'\r'}
  case "$reply" in
    '*'*) n=${reply#\*} ;;
    *) echo "ACL LIST => $reply"; exec 3>&-; return 1 ;;
  esac
  for ((i = 0; i < n; i++)); do
    # A bulk string: its length line, then the text.
    if ! IFS= read -r -t 10 line <&3 || ! IFS= read -r -t 10 line <&3; then
      echo "short ACL LIST reply"; exec 3>&-; return 1
    fi
    printf '%s\n' "${line%$'\r'}"
  done
  exec 3>&-
}

_acl_every_user() {
  local users list u missing=()
  users=$(_acl_users) && [ -n "$users" ] || { echo "cannot read users.json from configmap redis-acl-sync"; return 1; }
  list=$(_acl_list) || { echo "$list"; return 1; }
  for u in default $users; do
    grep -q "^user $u " <<<"$list" || missing+=("$u")
  done
  echo "acl_users=$(grep -c '^user ' <<<"$list") expected=$(($(wc -l <<<"$users") + 1)) missing=[${missing[*]}]"
  [ "${#missing[@]}" -eq 0 ]
}

# Until B40 R4 the default user keeps exactly today's rule, so every client
# that sends no password keeps working.
_acl_default_open() {
  local list
  list=$(_acl_list) || { echo "$list"; return 1; }
  grep -x 'user default on.*' <<<"$list"
  grep -qxF 'user default on nopass sanitize-payload ~* &* +@all' <<<"$list"
}

_acl_auth_every_user() {
  local users got bad
  users=$(_acl_users) && [ -n "$users" ] || { echo "cannot read users.json from configmap redis-acl-sync"; return 1; }
  got=$(prom_json 'redis_acl_user_auth_ok{job="redis-acl-sync"}') || { echo "query failed"; return 1; }
  bad=$(jq -rn --argjson got "$got" --arg users "$users" '
    ($got | map({(.metric.user): .value[1]}) | add // {}) as $v
    | [$users | split("\n")[] | select(. != "") | select(($v[.] // "missing") != "1") | "\(.)=\($v[.] // "missing")"]
    | join(" ")')
  echo "users=$(wc -l <<<"$users") not_ok=[$bad]"
  [ -z "$bad" ]
}

verify_component() {
  check "redis-v2 converged" retry 300 10 workload_ready redis statefulset/redis-v2
  check "PING as the default user, no password" bash -c "exec 3<>/dev/tcp/$RH/6379 && printf 'PING\r\n' >&3 && read -r -t 5 r <&3 && echo \"\$r\" && [ \"\${r%\$'\r'}\" = '+PONG' ]"
  check "as the verify user: scratch key written, read, deleted in db 15" _scratch
  check "AOF and RDB persistence healthy" _persistence
  check "server answers and clients are connected" _server
  check "redis_exporter sees redis up" expect_prom 'max(redis_up{namespace="redis"})' -eq 1
  check "ACL LIST holds default and every user of acl_users.json" _acl_every_user
  check "default user still open (no password, +@all) until B40 R4" _acl_default_open
  check "redis-acl-sync succeeded in the last 3 minutes" expect_prom 'time() - max(redis_acl_sync_last_success_timestamp_seconds{job="redis-acl-sync"})' -lt 180
  check "every named user can AUTH and PING (redis-acl-sync's last check)" _acl_auth_every_user
  check "an Anubis-fronted site (Redis challenge store) answers" expect_ingress forgejo.viktorbarzin.me /api/healthz '200'
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "redis-backup Job completes" run_cronjob redis redis-backup 900
  fi
}
