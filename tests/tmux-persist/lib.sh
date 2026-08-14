#!/usr/bin/env bash
# Shared assertions + fixture helpers for the tmux-persist tests.
#
# Every test drives the REAL /usr/local/bin source (scripts/tmux-persist.sh)
# against a throwaway STATE_DIR, a throwaway user map, and — when it needs live
# sessions — a PRIVATE tmux socket. The socket is per-test-process so a
# teardown can never reach a sibling lane's sessions (a `tmux -L <shared>
# kill-server` in a finally block has killed sibling sessions before).
#
# Seams the script honours (test-only; production reads the real paths):
#   TMUX_PERSIST_STATE_DIR   where manifests/snapshots live
#   TMUX_PERSIST_MAP         the ttyd-user-map to read users from
#   TMUX_PERSIST_TEST_SOCKET run tmux directly on this -L socket instead of
#                            runuser-ing into the target user (tests are not root)
#   TMUX_PERSIST_NOW         fixed epoch, so snapshot timestamps are deterministic

set -uo pipefail

SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/tmux-persist.sh}"

TESTS_RUN=0
TESTS_FAILED=0

_pass() { printf '  ok   %s\n' "$1"; }
_fail() { printf '  FAIL %s\n' "$1" >&2; TESTS_FAILED=$((TESTS_FAILED + 1)); }

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$got" == "$want" ]]; then _pass "$msg"; else _fail "$msg
         expected: '$want'
         got:      '$got'"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then _pass "$msg"; else _fail "$msg
         expected to contain: '$needle'
         got:                 '$haystack'"; fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then _pass "$msg"; else _fail "$msg
         expected NOT to contain: '$needle'
         got:                      '$haystack'"; fi
}

assert_file_exists() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$1" ]]; then _pass "${2:-}"; else _fail "${2:-} — missing file: $1"; fi
}

assert_file_missing() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ ! -e "$1" ]]; then _pass "${2:-}"; else _fail "${2:-} — file should not exist: $1"; fi
}

# --- fixtures -----------------------------------------------------------------

TEST_USER="$(id -un)"

setup_env() {
  TEST_TMP="$(mktemp -d)"
  export TMUX_PERSIST_STATE_DIR="$TEST_TMP/state"
  export TMUX_PERSIST_MAP="$TEST_TMP/ttyd-user-map"
  export TMUX_PERSIST_TEST_SOCKET="tlp-t$$-${RANDOM}"
  mkdir -p "$TMUX_PERSIST_STATE_DIR"
  printf 'testauth=%s\n' "$TEST_USER" > "$TMUX_PERSIST_MAP"
  # Restored panes must not launch a REAL claude against a fixture uuid; `true`
  # swallows the flags and the pane falls through to its `exec bash -l`.
  export TMUX_PERSIST_CLAUDE_BIN=true
  unset TMUX_PERSIST_NOW
}

teardown_env() {
  if [[ -n "${TMUX_PERSIST_TEST_SOCKET:-}" ]]; then
    tmux -L "$TMUX_PERSIST_TEST_SOCKET" kill-server 2>/dev/null || true
  fi
  [[ -n "${TEST_TMP:-}" ]] && rm -rf "$TEST_TMP"
}

tp() { bash "$SCRIPT_UNDER_TEST" "$@"; }

# Test tmux on the private socket.
tt() { tmux -L "$TMUX_PERSIST_TEST_SOCKET" "$@"; }

# Create a detached session running a bare shell that will not exit on its own.
mk_session() {
  local name="$1" dir="${2:-$TEST_TMP}"
  mkdir -p "$dir"
  tt new-session -d -s "$name" -c "$dir" 'exec sleep 3600' 2>/dev/null
}

at_time() { export TMUX_PERSIST_NOW="$1"; }

snap_dir() { echo "$TMUX_PERSIST_STATE_DIR/snapshots/$TEST_USER"; }

# Write a snapshot file directly (for tests that need rows the fixture tmux
# cannot produce, e.g. rows carrying a claude uuid).
seed_snapshot() {
  local ts="$1"; shift
  mkdir -p "$(snap_dir)"
  local f; f="$(snap_dir)/$ts.tsv"
  : > "$f"
  local row
  for row in "$@"; do printf '%s\n' "$row" >> "$f"; done
}

seed_pointer() {
  local ts="$1"
  ln -sfn "snapshots/$TEST_USER/$ts.tsv" "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv"
}

snap_count() { ls -1 "$(snap_dir)"/*.tsv 2>/dev/null | wc -l | tr -d ' '; }

newest_snap() { ls -1 "$(snap_dir)"/*.tsv 2>/dev/null | sort | tail -1; }

finish() {
  echo
  if (( TESTS_FAILED > 0 )); then
    printf '%s: %d/%d assertions FAILED\n' "$(basename "$0")" "$TESTS_FAILED" "$TESTS_RUN" >&2
    exit 1
  fi
  printf '%s: %d assertions passed\n' "$(basename "$0")" "$TESTS_RUN"
}
