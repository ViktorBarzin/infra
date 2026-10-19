#!/usr/bin/env bash
# t3-safe-restart.sh — SOURCED library (not executed). Shared by t3-autoupdate.sh
# (daily gated tracker) and t3-migrate-idle.sh (overnight deferral drainer).
#
# Holds the per-unit "dangerous" routine — backup -> restart -> verify pairing ->
# recover (restore DB + roll global binary back to last-good + freeze) — extracted
# verbatim from t3-autoupdate.sh step 6, plus the small helpers it depends on.
# The only change from the inline original: safe_restart_unit RETURNS non-zero on
# failure (after performing recovery+freeze) instead of `exit 1`, so the CALLER
# decides what to do (the daily job exits; the idle job stops draining).
#
# Callers must set, before calling safe_restart_unit: $target (version being moved
# TO, for log lines + the prebump filename) and $last_good (rollback target).
# Set $LOG_TAG before sourcing to tag syslog ("t3-autoupdate" / "t3-migrate-idle").

# ---- shared config defaults (honour the original T3_* override names) -----------
: "${LOG_TAG:=t3-safe-restart}"
: "${FREEZE_FILE:=${T3_FREEZE_FILE:-/etc/t3-autoupdate.freeze}}"
: "${STATE_DIR:=${T3_STATE_DIR:-/var/lib/t3-autoupdate}}"
: "${LAST_GOOD_FILE:=$STATE_DIR/last-good}"
: "${DEFER_DIR:=$STATE_DIR/deferred}"
: "${BACKUP_DIR:=${T3_BACKUP_DEST:-/var/backups/t3-state}}"
: "${DISPATCH:=${T3_DISPATCH:-127.0.0.1:3780}}"
: "${USER_MAP:=${T3_USER_MAP:-/etc/ttyd-user-map}}"
: "${T3_BACKUP_TIMEOUT:=900}"
: "${UPDATE_LOCK:=${T3_UPDATE_LOCK:-/run/t3-autoupdate.lock}}"
# Versioned installs (2026-10-19). Each build goes to its own npm prefix under
# T3_VERSIONS_DIR and T3_LINK (what t3-serve@ ExecStart and t3-mint run) is
# swapped to it with one rename. `npm i -g` rewrote the files under the running
# serves, which answered 404 for the whole install (2026-09-28).
: "${T3_VERSIONS_DIR:=/usr/local/lib/t3}"
: "${T3_LINK:=/usr/bin/t3}"
: "${T3_LEGACY_DIR:=/usr/lib/node_modules/t3}"   # the npm -g install every build before this used
: "${T3_KEEP_VERSIONS:=3}"
: "${SMOKE_PORT:=${T3_SMOKE_PORT:-3799}}"
# A first start of 0.1.0 on wizard's 2.5 GB state.sqlite runs a data import; the
# old fixed 30s wait failed it on 2026-10-19 with no error in the log. The wait
# ends early when the serve exits or logs a migration error.
: "${SMOKE_READY_TIMEOUT:=${T3_SMOKE_READY_TIMEOUT:-1200}}"
: "${TMPROOT:=${T3_TMPDIR:-/var/tmp}}"   # health-check scratch on DISK: /tmp is a 2G tmpfs and a populated state.sqlite overflows it
MIGERR_RE='migration failed|failed to migrate|no column named|NOT NULL constraint failed|PersistenceSqlError'

LOG() { logger -t "$LOG_TAG" "$*"; echo "$LOG_TAG: $*"; }

# take_update_lock <wait_seconds>: take the exclusive lock shared by every script
# that restarts t3-serve@ units or reinstalls the global binary (t3-autoupdate for
# its whole update + canary + rollback, t3-migrate-idle for a drain, t3-watchdog
# for a sweep). Held on fd 9 until the caller exits. Returns non-zero if another
# holder kept it for <wait_seconds> (0 = do not wait).
# Why: on 2026-09-28 the npm install made the running serves answer 404, the
# watchdog restarted emo onto the half-installed build, failed pairing, rolled the
# binary back and froze, while t3-autoupdate was rolling back at the same moment.
# Background children that may outlive the caller must close it (`9>&-`).
take_update_lock() {
  exec 9>>"$UPDATE_LOCK" || return 1
  if [ "${1:-0}" -gt 0 ]; then flock -w "$1" 9; else flock -n 9; fi
}
ver() { t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//'; }
# OS users owning a ~/.t3 (RHS of each non-comment "authentik=os_user" map line).
osusers() { awk -F= '!/^[[:space:]]*#/&&NF==2{gsub(/[[:space:]]/,"",$2);print $2}' "$USER_MAP" 2>/dev/null | sort -u; }
# authentik username for an OS user (reverse map; first match) — for dispatch verify.
ak_for() { awk -F= -v u="$1" '!/^[[:space:]]*#/&&NF==2{gsub(/[[:space:]]/,"",$1);gsub(/[[:space:]]/,"",$2);if($2==u){print $1;exit}}' "$USER_MAP" 2>/dev/null; }

# Online consistent snapshot of ONE user's state.sqlite (run AS the owner so the
# WAL stays owned; never stops the serve). Uses global $target for the filename.
# Echoes the backup path on success; non-zero on failure.
backup_user() {
  local u="$1" src out dst ts
  src="/home/$u/.t3/userdata/state.sqlite"; [ -f "$src" ] || return 1
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/$u"; dst="$out/state-prebump-$target-$ts.sqlite"
  install -d -o "$u" -g "$u" -m700 "$out" 2>/dev/null || mkdir -p "$out"
  if runuser -u "$u" -- timeout "$T3_BACKUP_TIMEOUT" sqlite3 "$src" "VACUUM INTO '$dst'" 2>/dev/null && [ -s "$dst" ]; then
    printf '%s\n' "$dst"; return 0
  fi
  rm -f "$dst"; return 1
}

# newest pre-bump backup for a user taken for the current $target (restore source).
prebump_of() { ls -1t "$BACKUP_DIR/$1/state-prebump-$target-"*.sqlite 2>/dev/null | head -1; }

# version string from an installed t3 package.json (no node needed).
pkg_version() { sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1/package.json" 2>/dev/null | head -1; }

# version_entry <ver>: absolute path of the launcher installed for <ver> (a
# versioned prefix, or the legacy npm -g install if it holds <ver>); non-zero if absent.
version_entry() {
  local e
  e="$(readlink -f "$T3_VERSIONS_DIR/$1/node_modules/.bin/t3" 2>/dev/null)"
  if [ -n "$e" ] && [ -x "$e" ]; then printf '%s\n' "$e"; return 0; fi
  if [ "$(pkg_version "$T3_LEGACY_DIR")" = "$1" ]; then
    e="$(readlink -f "$(dirname "$T3_LEGACY_DIR")/.bin/t3" 2>/dev/null)"
    [ -n "$e" ] && [ -x "$e" ] || e="$(readlink -f "$T3_LEGACY_DIR/dist/bin.mjs" 2>/dev/null)"
    if [ -n "$e" ] && [ -x "$e" ]; then printf '%s\n' "$e"; return 0; fi
  fi
  return 1
}

# install_version <ver>: npm-install t3@<ver> into its own prefix, invisible to
# every running serve. Staged then renamed, so a half-finished install never
# looks complete. Reuses an existing complete install.
install_version() {
  local v="$1" stage
  [ -x "$(readlink -f "$T3_VERSIONS_DIR/$v/node_modules/.bin/t3" 2>/dev/null)" ] && return 0
  mkdir -p "$T3_VERSIONS_DIR" || return 1
  stage="$T3_VERSIONS_DIR/.staging-$v-$$"; rm -rf "$stage"
  if npm i --prefix "$stage" "t3@$v" >/dev/null 2>&1 && [ -x "$(readlink -f "$stage/node_modules/.bin/t3" 2>/dev/null)" ]; then
    rm -rf "${T3_VERSIONS_DIR:?}/$v" && mv -T "$stage" "$T3_VERSIONS_DIR/$v" && return 0
  fi
  rm -rf "$stage"; return 1
}

# activate_version <ver>: point T3_LINK at <ver>'s launcher with one rename.
# Running serves keep their own files; only new execs (restarts, mints) see it.
activate_version() {
  local e tmp
  e="$(version_entry "$1")" || return 1
  tmp="$T3_LINK.new-$$"
  ln -sfn "$e" "$tmp" && mv -Tf "$tmp" "$T3_LINK" && return 0
  rm -f "$tmp"; return 1
}

# roll the binary back to last-good: a symlink swap when that build is still on
# disk (the normal case), npm -g only as a fallback. In the idle path
# last_good==installed, so this is a no-op (does NOT downgrade other users).
rollback_binary() {
  LOG "rolling back binary $target -> $last_good"
  if activate_version "$last_good"; then LOG "rolled back to $last_good"; return 0; fi
  if npm i -g "t3@$last_good" >/dev/null 2>&1; then LOG "rolled back to $last_good (npm -g fallback)"; return 0; fi
  LOG "ROLLBACK FAILED — could not reinstall t3@$last_good (t3 may be broken; manual fix per runbook)"; return 1
}

# prune_versions <keep...>: delete versioned installs beyond the newest
# T3_KEEP_VERSIONS, never one named in <keep...> (active, last-good, target) and
# never one a running process still uses (a deferred busy serve on an old build).
prune_versions() {
  local d v k n=0 keep
  for d in $(ls -1dt "$T3_VERSIONS_DIR"/*/ 2>/dev/null); do
    d="${d%/}"; v="${d##*/}"; n=$((n+1)); keep=0
    [ "$n" -le "$T3_KEEP_VERSIONS" ] && keep=1
    for k in "$@"; do [ "$k" = "$v" ] && keep=1; done
    [ "$keep" = 1 ] && continue
    if pgrep -f "$d/" >/dev/null 2>&1 || grep -qsF "$d/" /proc/[0-9]*/maps 2>/dev/null; then
      LOG "keeping $v: a running process still uses it"; continue
    fi
    rm -rf "$d" && LOG "pruned old t3 install $v"
  done
}

# stop_group <pid>: stop <pid> and everything in its process group. Since 0.1.0
# the npm launcher is a node wrapper that spawns the native server and does not
# forward signals, so killing only <pid> orphaned the server on SMOKE_PORT.
stop_group() {
  local pid="$1" pg _
  pg="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -n "$pg" ] && [ "$pg" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
    kill -TERM -- "-$pg" 2>/dev/null
    for _ in $(seq 1 20); do pgrep -g "$pg" >/dev/null 2>&1 || break; sleep 0.5; done
    kill -KILL -- "-$pg" 2>/dev/null
  else
    pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null
  return 0
}

# health_check <t3bin> [seed_db]: start a throwaway serve (seeded with a copy of a
# real populated DB if given, so the forward migration runs on real data), then do
# the real mint -> credential-exchange -> t3_session pairing handshake with the
# dispatch's endpoint fallback, and sniff the serve log for a migration failure.
health_check() {
  local t3bin="$1" seed="${2:-}" dir logf pid live=0 pair=0 migerr=0 cred ep hdr code seeded=fresh deadline why=timeout
  dir="$(mktemp -d -p "$TMPROOT")"; mkdir -p "$dir/userdata"; logf="$dir/serve.log"
  if [ -n "$seed" ] && [ -f "$seed" ]; then cp "$seed" "$dir/userdata/state.sqlite"; seeded=populated; fi
  # --host 0.0.0.0 MUST match how t3-serve@.service binds in production, and is
  # not merely cosmetic: resolveSessionCookieName() (apps/server/src/auth/utils.ts)
  # returns the plain `t3_session` ONLY for a remote-reachable host, and
  # `t3_session_<port>_<instanceHash>` for a loopback one. Smoke-testing on
  # 127.0.0.1 therefore produced an instance-scoped cookie that the pair grep
  # below could never match — a FALSE NEGATIVE that silently pinned the fleet at
  # 0.0.29 for 17 days while every daily run "correctly" rolled 0.0.34 back
  # (found 2026-08-13, when the mobile app could not hold a session against the
  # stale server). Binding like production also keeps this gate honest about the
  # cookie NAME, which is exactly what t3-dispatch hardcodes.
  # setsid: its own process group, so stop_group takes the native server too.
  # 9>&-: the throwaway serve must not inherit the update lock (see take_update_lock).
  setsid "$t3bin" serve --host 0.0.0.0 --port "$SMOKE_PORT" --base-dir "$dir" >"$logf" 2>&1 9>&- &
  pid=$!
  deadline=$(( $(date +%s) + SMOKE_READY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SMOKE_PORT/" 2>/dev/null)" = "200" ] && { live=1; break; }
    kill -0 "$pid" 2>/dev/null || { why=exited; break; }
    grep -qiE "$MIGERR_RE" "$logf" 2>/dev/null && { why=migration-error; break; }
    sleep 2
  done
  if [ "$live" = "1" ]; then
    LOG "candidate serve answered after $(( $(date +%s) - deadline + SMOKE_READY_TIMEOUT ))s"
    cred="$("$t3bin" auth pairing create --base-dir "$dir" --ttl 5m --json 2>/dev/null | tr -d '\n ' | sed -n 's/.*"credential":"\([^"]*\)".*/\1/p')"
    if [ -n "$cred" ]; then
      for ep in /api/auth/browser-session /api/auth/bootstrap; do
        hdr="$(curl -s -i --max-time 5 -X POST -H 'Content-Type: application/json' -d "{\"credential\":\"$cred\"}" "http://127.0.0.1:$SMOKE_PORT$ep" 2>/dev/null)"
        code="$(printf '%s' "$hdr" | sed -n '1s#.* \([0-9][0-9][0-9]\).*#\1#p')"
        [ "$code" = "404" ] && continue
        printf '%s' "$hdr" | grep -qi '^set-cookie:[[:space:]]*t3_session=' && pair=1
        break
      done
    fi
  fi
  grep -qiE "$MIGERR_RE" "$logf" 2>/dev/null && migerr=1
  stop_group "$pid"
  if [ "$live" = "1" ] && [ "$pair" = "1" ] && [ "$migerr" = "0" ]; then
    LOG "health OK ($seeded: live + pairing handshake + clean migration)"
    rm -rf "$dir"; return 0
  fi
  [ "$live" = "1" ] && why=ready
  LOG "HEALTH-CHECK FAILED ($seeded: live=$live pair=$pair migerr=$migerr wait=$why/${SMOKE_READY_TIMEOUT}s); serve log: $(tail -3 "$logf" 2>/dev/null | tr '\n' '|')"
  rm -rf "$dir"; return 1
}

# unit_busy <unit>: is an agent (claude/codex/opencode) running anywhere in the
# unit's cgroup? Never restart those. Since 0.1.0 MainPID is the node launcher and
# the agents hang off the native server below it, so direct children of MainPID
# (the check before 2026-10-19) would always look idle.
unit_busy() {
  local cg p
  cg="$(systemctl show -p ControlGroup --value "$1" 2>/dev/null)"; [ -n "$cg" ] || return 1
  for p in $(find "${T3_CGROUP_ROOT:-/sys/fs/cgroup}$cg" -name cgroup.procs -exec cat {} + 2>/dev/null); do
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -v ' serve ' | grep -qiE 'claude|codex|opencode' && return 0
  done
  return 1
}

# verify a user's pairing through the REAL dispatch (mint -> exchange -> cookie).
verify_pairing() {
  local u="$1" ak out; ak="$(ak_for "$u")"; [ -n "$ak" ] || { LOG "no authentik mapping for $u — skipping dispatch verify"; return 0; }
  out="$(curl -s -i --max-time 10 -H "X-authentik-username: $ak" -H 'Sec-Fetch-Dest: document' "http://$DISPATCH/" 2>/dev/null)"
  printf '%s' "$out" | grep -qi '^set-cookie:[[:space:]]*t3_session='
}

# safe_restart_unit <unit> <user>: restart the unit, verify pairing; on failure
# restore the user's DB from its pre-restart backup, roll the binary back, freeze.
# Assumes a pre-restart backup already exists for <user> at the current $target
# (the daily job's backup_all, or the idle job's backup_user, takes it first).
# Returns 0 on verified success, non-zero after recovery+freeze on failure.
safe_restart_unit() {
  local unit="$1" u="$2" ok=0 _ bak
  systemctl restart "$unit" || LOG "WARN: systemctl restart $unit returned non-zero"
  for _ in $(seq 1 15); do
    if verify_pairing "$u"; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" = "1" ]; then
    LOG "restarted $unit -> $target (pairing verified via dispatch)"; return 0
  fi
  LOG "HEALTH-CHECK FAILED: $u pairing broken AFTER restart onto $target — rolling back + restoring its DB"
  rollback_binary
  bak="$(prebump_of "$u")"
  if [ -n "$bak" ]; then
    systemctl stop "$unit" 2>/dev/null
    if install -o "$u" -g "$u" -m600 "$bak" "/home/$u/.t3/userdata/state.sqlite" 2>/dev/null; then
      rm -f "/home/$u/.t3/userdata/state.sqlite-wal" "/home/$u/.t3/userdata/state.sqlite-shm"
      LOG "restored $u state.sqlite from $bak"
    fi
    systemctl start "$unit" 2>/dev/null
  fi
  touch "$FREEZE_FILE" 2>/dev/null
  LOG "FROZEN ($FREEZE_FILE) after $u failed on $target; last_good stays $last_good — investigate, then remove the freeze file to resume"
  return 1
}
