#!/usr/bin/env bash
# Pure-bash unit tests for the t3-migrate-idle gate. No root, no bats, no Docker.
# Sources t3-migrate-idle.sh (main-guarded) with the lib path pointed at the worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
export T3_SAFE_RESTART_LIB="$HERE/scripts/t3-safe-restart.sh"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-migrate-idle.sh"        # defines functions; main-guard prevents the drain from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }

# --- gate_is_safe <active> <idle_seconds> with QUIET_SECONDS=900 ---
QUIET_SECONDS=900
ok    gate_is_safe 0 1000      # idle, quiet long enough -> safe
notok gate_is_safe 1 1000      # a turn in flight -> unsafe
notok gate_is_safe 0 100       # idle but not quiet enough -> unsafe
ok    gate_is_safe 0 ""        # no threads at all (NULL idle) -> safe
notok gate_is_safe x 1000      # unparseable active -> unsafe
notok gate_is_safe 0 -30       # negative idle (clock skew) -> unsafe

# --- gate_query <db> against fixture SQLite DBs ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkfix() { # mkfix <file> ; reads rows "active_turn_id|updated_at" on stdin
  local f="$1"; sqlite3 "$f" "CREATE TABLE projection_thread_sessions(active_turn_id TEXT, updated_at TEXT NOT NULL);"
  while IFS='|' read -r a u; do sqlite3 "$f" "INSERT INTO projection_thread_sessions VALUES ($([ "$a" = NULL ] && echo NULL || echo "'$a'"), '$u');"; done
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
OLD="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"

# active turn present -> "1|<small idle>"
printf '%s\n' "abc|$NOW" "NULL|$OLD" | mkfix "$TMP/active.db"
res="$(gate_query "$TMP/active.db")"; ok test "${res%%|*}" = "1"

# all idle, last activity 1h ago -> "0|>=3500"
printf '%s\n' "NULL|$OLD" "NULL|$OLD" | mkfix "$TMP/idle.db"
res="$(gate_query "$TMP/idle.db")"; ok test "${res%%|*}" = "0"; ok test "${res##*|}" -ge 3500

# empty table -> "0|" (NULL idle)
sqlite3 "$TMP/empty.db" "CREATE TABLE projection_thread_sessions(active_turn_id TEXT, updated_at TEXT NOT NULL);"
res="$(gate_query "$TMP/empty.db")"; ok test "${res%%|*}" = "0"

echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
