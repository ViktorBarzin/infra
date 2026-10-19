#!/usr/bin/env bash
# Pure-bash tests for the shared t3 update lock (take_update_lock in
# t3-safe-restart.sh). No root, no bats, no Docker.
#
# The lock serialises the three scripts that restart t3-serve@ units or reinstall
# the global t3 binary: t3-autoupdate (whole update + canary + rollback),
# t3-migrate-idle (a drain) and t3-watchdog (a sweep). On 2026-09-28 the watchdog
# restarted emo onto a half-installed build mid-update and both scripts rolled
# back at once; these tests pin that the other two stand aside while one holds it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
TMP="$(mktemp -d)"
holder=""
trap '[ -n "$holder" ] && kill "$holder" 2>/dev/null; rm -rf "$TMP"' EXIT

export T3_SAFE_RESTART_LIB="$HERE/scripts/t3-safe-restart.sh"
export T3_UPDATE_LOCK="$TMP/t3-autoupdate.lock"
export T3_STATE_DIR="$TMP/state" T3_FREEZE_FILE="$TMP/freeze" T3_WD_STATE_DIR="$TMP/wd"

# Stub every command that would touch the real box. Each one records its call, so
# "nothing happened" is a checkable empty file rather than an assumption.
mkdir -p "$TMP/bin"
for c in logger systemctl npm t3 curl runuser sqlite3; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$c" "$TMP" >"$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
done
export PATH="$TMP/bin:$PATH"
: >"$TMP/calls"
calls_except_logger() { grep -v '^logger ' "$TMP/calls" || true; }

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }
has()  { case "$1" in *"$2"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: output lacks '$2' ($3): $1";; esac; }

# shellcheck source=/dev/null
. "$T3_SAFE_RESTART_LIB"

# --- free lock: taken at once ---
ok   bash -c ". '$T3_SAFE_RESTART_LIB'; take_update_lock 0"

# --- hold the lock from another process, as a running t3-autoupdate would ---
mkfifo "$TMP/ready" "$TMP/release"
( flock 9; echo held >"$TMP/ready"; read -r _ <"$TMP/release" ) 9>>"$T3_UPDATE_LOCK" &
holder=$!
read -r _ <"$TMP/ready"

notok bash -c ". '$T3_SAFE_RESTART_LIB'; take_update_lock 0"
start=$(date +%s)
notok bash -c ". '$T3_SAFE_RESTART_LIB'; take_update_lock 1"   # waits, then gives up
ok test $(( $(date +%s) - start )) -ge 1

# watchdog: skips the whole sweep, so it neither counts the expected mid-install
# 404s as failures nor restarts anything
out="$(bash "$HERE/scripts/t3-watchdog.sh" 2>&1)"; rc=$?
eq "$rc" 0 "watchdog exits 0 while the lock is held"
has "$out" "skipping sweep" "watchdog says why it did nothing"
eq "$(calls_except_logger)" "" "watchdog made no systemctl/curl/npm/t3 call"
ok test ! -e "$TMP/wd/emo.fails"

# migrate-idle: a deferred user is waiting, but the drain stands aside
: >"$TMP/calls"; mkdir -p "$TMP/state/deferred"; echo 0.1.0 >"$TMP/state/deferred/emo"
out="$(T3_LOCK_WAIT=1 bash "$HERE/scripts/t3-migrate-idle.sh" 2>&1)"; rc=$?
eq "$rc" 0 "migrate-idle exits 0 while the lock is held"
has "$out" "lock" "migrate-idle says why it did nothing"
eq "$(calls_except_logger)" "" "migrate-idle made no systemctl/npm/t3 call"
ok test -e "$TMP/state/deferred/emo"

# autoupdate: a second run (timer + a person by hand) waits, then gives up
# without reading versions, installing or restarting
: >"$TMP/calls"
out="$(T3_LOCK_WAIT=1 bash "$HERE/scripts/t3-autoupdate.sh" 2>&1)"; rc=$?
eq "$rc" 0 "autoupdate exits 0 when it cannot get the lock"
has "$out" "lock" "autoupdate says why it did nothing"
eq "$(calls_except_logger)" "" "autoupdate made no npm/t3/systemctl call"

# --- released: the next taker gets it at once ---
echo go >"$TMP/release"; wait "$holder"; holder=""
ok   bash -c ". '$T3_SAFE_RESTART_LIB'; take_update_lock 0"

# --- a frozen autoupdate still reports FROZEN once it holds the lock ---
: >"$TMP/calls"; touch "$TMP/freeze"
out="$(bash "$HERE/scripts/t3-autoupdate.sh" 2>&1)"
has "$out" "FROZEN" "freeze gate still runs under the lock"
eq "$(grep -E '^(npm|systemctl) ' "$TMP/calls")" "" "frozen autoupdate installed and restarted nothing"
rm -f "$TMP/freeze"

# --- the throwaway health-check serve must not inherit the lock fd: if it ever
# outlived the script it would hold the lock and silence the watchdog for good ---
grep -q 'serve --host 0.0.0.0 .* 9>&- &' "$HERE/scripts/t3-safe-restart.sh"
eq "$?" 0 "health_check closes fd 9 for the background serve"

echo; echo "t3-update-lock: pass=$pass fail=$fail"
[ "$fail" = 0 ]
