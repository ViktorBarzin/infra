#!/usr/bin/env bash
# Pure-bash unit tests for the t3-watchdog gate. No root, no bats, no Docker.
# Sources t3-watchdog.sh (main-guarded) with the lib path pointed at the worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
export T3_SAFE_RESTART_LIB="$HERE/scripts/t3-safe-restart.sh"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-watchdog.sh"            # defines functions; main-guard prevents the sweep from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }

WD_GRACE_SECONDS=120 WD_FAILS_REQUIRED=3 WD_MAX_RESTARTS=3 WD_WINDOW_SECONDS=1800

# --- gate_should_restart <active_state> <uptime_s> <fails> <restarts_in_window> ---
# rc 0 = restart, rc 1 = hold off, rc 2 = at flap cap (caller logs EXHAUSTED)
ok    gate_should_restart active 300 3 0        # golden path
ok    gate_should_restart active 300 5 2        # more fails, under cap
notok gate_should_restart active 300 2 0        # not enough consecutive fails
notok gate_should_restart active 60  3 0        # inside startup grace
notok gate_should_restart active 120 3 0        # grace boundary: must be STRICTLY past it
notok gate_should_restart inactive 300 3 0      # unit not active -> systemd's problem
notok gate_should_restart failed 300 3 0
notok gate_should_restart active "" 3 0         # unparseable uptime -> fail closed
notok gate_should_restart active -5 3 0         # negative uptime (clock skew) -> fail closed
notok gate_should_restart active 300 x 0        # unparseable fails -> fail closed
notok gate_should_restart active 300 3 junk     # unparseable ledger count -> fail closed
gate_should_restart active 300 3 3; eq "$?" 2 "at cap returns rc 2"
gate_should_restart active 300 9 7; eq "$?" 2 "over cap returns rc 2"

# --- parse_port: extract T3_PORT from env-file text on stdin ---
eq "$(printf 'NODE_ENV=production\nT3_PORT=3773\n' | parse_port)" "3773" "plain assignment"
eq "$(printf 'T3_PORT="3774"\n' | parse_port)" "3774" "double-quoted"
eq "$(printf "T3_PORT='3775'\n" | parse_port)" "3775" "single-quoted"
eq "$(printf '# T3_PORT=9999\nT3_PORT=3773\n' | parse_port)" "3773" "comment line ignored"
eq "$(printf 'T3_PORT=3773\nT3_PORT=3999\n' | parse_port)" "3999" "last assignment wins"
eq "$(printf 'T3_PORT=abc\n' | parse_port)" "" "non-numeric -> empty"
eq "$(printf 'no port here\n' | parse_port)" "" "absent -> empty"

# --- restarts_in_window <now_epoch> (ledger epochs on stdin, one per line) ---
NOW=1000000   # window = (NOW-1800, NOW]
eq "$(printf '999000\n999500\n' | restarts_in_window $NOW)" "2" "both inside window"
eq "$(printf '990000\n999500\n' | restarts_in_window $NOW)" "1" "old entry pruned"
eq "$(printf '998200\n' | restarts_in_window $NOW)" "0" "boundary epoch is outside (strict >)"
eq "$(printf 'garbage\n999500\n' | restarts_in_window $NOW)" "1" "garbage line ignored"
eq "$(printf '' | restarts_in_window $NOW)" "0" "empty ledger"

echo; echo "t3-watchdog-gate: pass=$pass fail=$fail"
[ "$fail" = 0 ]
