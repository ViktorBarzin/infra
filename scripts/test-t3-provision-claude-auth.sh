#!/usr/bin/env bash
# Checks install_claude_auth_sync in t3-provision-users.sh: when the admin run
# mints a user's Claude-auth Vault token, it also starts that user's
# claude-auth-sync once, so Claude is logged in right after the run instead of
# up to 6 h later at the timer's next tick (round-3 drill, 2026-11-12: both
# users printed "Not logged in" after the admin run).
#   - a fresh mint starts claude-auth-sync@<user>.service once, without blocking
#   - a run that finds the token already there does not start it
#   - a mint that could not be written does not start it
#   - claude_auth: false never starts it
#
# Run: bash scripts/test-t3-provision-claude-auth.sh
#
# Pulls the function and its helpers out of the script by name and runs it
# against a temp home, with stand-ins for getent, systemctl and the Vault and
# write helpers that record what they were asked to do.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"
pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }
extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract install_claude_auth_sync)"
declare -F install_claude_auth_sync >/dev/null || { echo "FAIL: install_claude_auth_sync not found in $SCRIPT"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
CALLS="$tmp/calls"
HOME_DIR="$tmp/home/alice"
mkdir -p "$HOME_DIR"

DRY_RUN=0
log() { echo "[t3-provision] $*" >> "$CALLS"; }
run() { "$@"; }
getent() { echo "alice:x:1001:1001::$HOME_DIR:/bin/bash"; }
systemctl() { echo "systemctl $*" >> "$CALLS"; }
mkdir_as() { local _u=$1 _m=$2; shift 2; mkdir -p "$@"; }
write_as() { [[ "${WRITE_FAILS:-0}" == 1 ]] && return 1; cat > "$3"; }
vault_admin() {
  case "$*" in
    "token lookup") return 0 ;;
    token\ create*) echo "hvs.FAKE-TEST-TOKEN" ;;
  esac
}
token_file="$HOME_DIR/.config/claude-auth-sync/vault-token"
started() { grep -q "systemctl start --no-block claude-auth-sync@alice.service" "$CALLS"; }

# 1. fresh mint starts the sync once
: > "$CALLS"; rm -f "$token_file"
install_claude_auth_sync alice true
ok "fresh mint writes the token" test -s "$token_file"
ok "fresh mint starts claude-auth-sync once" started
ok "the timer is still enabled" grep -q "systemctl enable --now claude-auth-sync@alice.timer" "$CALLS"
no "the token never reaches a command or log line" grep -q "FAKE-TEST-TOKEN" "$CALLS"

# 2. token already there: no start (the hourly run must not re-run the sync)
: > "$CALLS"
install_claude_auth_sync alice true
no "an existing token does not start the sync" started

# 3. mint that could not be written: no start
: > "$CALLS"; rm -f "$token_file"
WRITE_FAILS=1 install_claude_auth_sync alice true
no "a failed write does not start the sync" started

# 4. claude_auth: false
: > "$CALLS"; rm -f "$token_file"
install_claude_auth_sync alice false
no "claude_auth false does not start the sync" started

echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
