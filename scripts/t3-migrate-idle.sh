#!/usr/bin/env bash
# t3-migrate-idle.sh — drains t3-autoupdate's deferral markers (via the overnight
# t3-migrate-idle.timer). For each deferred t3-serve@<user>, if nothing is actively
# working in that instance (no in-flight turn + a quiet buffer), restart it onto the
# current binary using the shared safe_restart_unit, then clear the marker.
# Why this exists: t3-autoupdate defers a user with an active agent at its single
# daily window; a user busy every night never migrates and their client shows
# "Client and server versions differ". See docs/plans/2026-06-21-t3-idle-migrate-*.
set -uo pipefail

LOG_TAG=t3-migrate-idle
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

QUIET_SECONDS="${T3_MIGRATE_QUIET_SECONDS:-900}"   # required idle before a restart (15 min)
DRY_RUN="${T3_DRY_RUN:-0}"

# pure logic: is it safe given <active_turns> and <idle_seconds>? fail closed.
gate_is_safe() {
  local active="$1" idle="$2"
  case "$active" in ''|*[!0-9]*) return 1;; esac     # unparseable/empty active -> unsafe
  [ "$active" -eq 0 ] || return 1                     # a turn is running -> unsafe
  [ -z "$idle" ] && return 0                          # no threads at all -> safe
  case "$idle" in ''|*[!0-9-]*) return 1;; esac       # non-numeric -> unsafe
  [ "$idle" -ge "$QUIET_SECONDS" ]                    # negative or < quiet -> unsafe
}

# query a state.sqlite (path or file: URI). Echoes "<active_turns>|<idle_seconds>".
# idle_seconds is empty when there are no rows. Normalizes ISO 'T'/'Z' for julianday.
gate_query() {
  local db="$1"
  sqlite3 -batch -noheader -separator '|' "$db" \
    "SELECT
       (SELECT count(*) FROM projection_thread_sessions WHERE active_turn_id IS NOT NULL),
       CAST((julianday('now') - julianday(replace(replace(max(updated_at),'T',' '),'Z',''))) * 86400 AS INT)
     FROM projection_thread_sessions;"
}

# safe_to_restart <user>: wire runuser + the user's DB into gate_query/gate_is_safe.
safe_to_restart() {
  local u="$1" db row
  db="/home/$u/.t3/userdata/state.sqlite"; [ -f "$db" ] || return 1
  row="$(runuser -u "$u" -- sqlite3 -batch -noheader -separator '|' "file:$db?mode=ro" \
    "SELECT
       (SELECT count(*) FROM projection_thread_sessions WHERE active_turn_id IS NOT NULL),
       CAST((julianday('now') - julianday(replace(replace(max(updated_at),'T',' '),'Z',''))) * 86400 AS INT)
     FROM projection_thread_sessions;" 2>/dev/null)" || return 1
  gate_is_safe "${row%%|*}" "${row##*|}"
}

main() {
  # a frozen build must not be auto-migrated (shared switch with t3-autoupdate)
  if [ -e "$FREEZE_FILE" ]; then LOG "FROZEN: $FREEZE_FILE present — not draining deferrals"; exit 0; fi
  [ -d "$DEFER_DIR" ] || exit 0                       # nothing deferred
  last_good="$(tr -d '[:space:]' <"$LAST_GOOD_FILE" 2>/dev/null)"   # rollback target for the helper

  local marker u unit started mwritten migrated=0 skipped=0
  for marker in "$DEFER_DIR"/*; do
    [ -e "$marker" ] || continue                      # empty-dir glob
    u="$(basename "$marker")"; unit="t3-serve@$u.service"
    if ! systemctl is-active --quiet "$unit"; then
      LOG "clearing marker for $u: $unit not active"; rm -f "$marker"; continue
    fi
    started="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)" +%s 2>/dev/null || echo 0)"
    mwritten="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"
    if [ "$started" -gt "$mwritten" ]; then
      LOG "clearing marker for $u: $unit already restarted $((started-mwritten))s after the deferral"; rm -f "$marker"; continue
    fi
    if ! safe_to_restart "$u"; then skipped=$((skipped+1)); continue; fi

    target="$(tr -d '[:space:]' <"$marker" 2>/dev/null)"; [ -n "$target" ] || target="$(ver)"
    if [ "$DRY_RUN" = "1" ]; then LOG "DRY_RUN: would migrate $unit -> $target (idle gate satisfied)"; continue; fi
    if ! backup_user "$u" >/dev/null; then
      LOG "WARN: pre-restart backup failed for $u — skipping (fail closed)"; skipped=$((skipped+1)); continue
    fi
    if safe_restart_unit "$unit" "$u"; then
      LOG "migrated $unit -> $target (idle restart)"; rm -f "$marker"; migrated=$((migrated+1))
    else
      LOG "migrate FAILED for $unit — recovery+freeze handled by safe_restart_unit; stopping drain"; exit 1
    fi
  done
  LOG "idle-migrate pass complete (migrated=$migrated skipped=$skipped)"
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
