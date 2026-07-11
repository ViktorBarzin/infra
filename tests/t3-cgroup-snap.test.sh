#!/usr/bin/env bash
# Pure-bash unit tests for t3-cgroup-snap. No root, no bats, no Docker.
# Sources t3-cgroup-snap.sh (main-guarded) and exercises pure functions against
# a fixture /proc-shaped directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-cgroup-snap.sh"          # defines functions; main-guard prevents the loop from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture builder: fake /proc/<pid> ---
mkproc() { # mkproc <pid> <rss_kb> <comm> <exe_target> <cmdline_NUL_sep> <ppid>
  local pid="$1" rss="$2" comm="$3" exe="$4" cmd="$5" ppid="${6:-1}"
  local d="$TMP/proc/$pid"
  mkdir -p "$d"
  printf 'Name:\t%s\nVmRSS:\t%s kB\nUid:\t1000\t1000\t1000\t1000\nPPid:\t%s\n' "$comm" "$rss" "$ppid" >"$d/status"
  printf '%s\n' "$comm" >"$d/comm"
  ln -sf "$exe" "$d/exe"
  printf '%b' "$cmd" >"$d/cmdline"
}

# --- read_pid_status <procroot> <pid> ---
mkproc 100 5394176 '2.1.205' '/usr/bin/python3' 'python3\0/tmp/tool\0--verbose\0'
RES="$(read_pid_status "$TMP/proc" 100 | jq -c '{pid,uid,rss_kb,comm}')"
eq "$RES" '{"pid":100,"uid":1000,"rss_kb":5394176,"comm":"2.1.205"}' "read_pid_status basics"

# short-lived proc: partial fixture (no status file) -> silent skip (empty stdout, rc 0)
mkdir -p "$TMP/proc/999"; printf 'gone\n' >"$TMP/proc/999/comm"
RES="$(read_pid_status "$TMP/proc" 999)"; eq "$RES" "" "missing status -> empty"

# --- emit_line <procroot> <user> <pid> [ts_override] ---
mkproc 200 128 'claude' '/usr/bin/node' 'node\0/usr/bin/claude\0--output-format\0stream-json\0' 100
LINE="$(emit_line "$TMP/proc" wizard 200 '2026-07-09T22:26:40Z')"
eq "$(printf '%s' "$LINE" | jq -r .user)" "wizard" "emit_line user"
eq "$(printf '%s' "$LINE" | jq -r .ts)" "2026-07-09T22:26:40Z" "emit_line ts"
eq "$(printf '%s' "$LINE" | jq -r .comm)" "claude" "emit_line comm"
eq "$(printf '%s' "$LINE" | jq -r .exe)" "/usr/bin/node" "emit_line exe"
eq "$(printf '%s' "$LINE" | jq -r .argv)" "node /usr/bin/claude --output-format stream-json" "argv NUL->space"
eq "$(printf '%s' "$LINE" | jq -r .ppid)" "100" "emit_line ppid"
ok  test "$LINE" = "${LINE%$'\n'*}"                                    # no embedded newlines (JSONL invariant)

# argv > 512 bytes -> truncated near cap
LONG=$(printf 'X%.0s' $(seq 1 800))
mkproc 300 64 'bash' '/bin/bash' "bash\0-c\0$LONG\0"
LINE="$(emit_line "$TMP/proc" wizard 300 t)"
ARGV="$(printf '%s' "$LINE" | jq -r .argv)"
ok test "${#ARGV}" -le 512  &&  ok test "${#ARGV}" -ge 500     # truncated near the cap, not empty

# JSON-poisoning argv: quotes, backslashes, newlines survive as VALID JSON
mkproc 400 32 'sh' '/bin/sh' 'sh\0-c\0echo "hi"\nrm\\-rf\0'
LINE="$(emit_line "$TMP/proc" wizard 400 t)"
ok  printf '%s' "$LINE" | jq -e . >/dev/null                   # parses cleanly = escaping works

# missing pid -> empty stdout, rc 0
RES="$(emit_line "$TMP/proc" wizard 9999 t)"
eq "$RES" "" "emit_line missing pid -> empty"

# --- rotate_if_needed <path> <max_bytes> ---
F="$TMP/log.jsonl"; : >"$F"
head -c 100 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200   # under threshold: rc 0, no rename
ok test ! -e "$F.1"                                              # no rotation happened
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200   # over threshold: rotates
ok test -e "$F.1"  &&  ok test ! -s "$F"                         # .1 exists, current is empty
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
ok test -e "$F.3"; ok test ! -e "$F.4"                          # ring is bounded to 3 rotations

echo; echo "t3-cgroup-snap: pass=$pass fail=$fail"
[ "$fail" = 0 ]
