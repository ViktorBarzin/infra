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

LOG() { logger -t "$LOG_TAG" "$*"; echo "$LOG_TAG: $*"; }
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

# roll the GLOBAL binary back to last-good. In the idle path last_good==installed,
# so this is a harmless no-op reinstall (does NOT downgrade other users).
rollback_binary() {
  LOG "rolling back binary $target -> $last_good"
  if npm i -g "t3@$last_good" >/dev/null 2>&1; then LOG "rolled back to $last_good"; return 0; fi
  LOG "ROLLBACK FAILED — could not reinstall t3@$last_good (t3 may be broken; manual fix per runbook)"; return 1
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
