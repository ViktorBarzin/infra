#!/usr/bin/env bash
# Checks restore_agent_state, the t3-provision-users.sh step that puts a
# user's ~/.claude and ~/.codex back from the session store on a rebuilt devvm
# (docs/plans/2026-11-11-disposable-devvm.md): it calls
# `homelab claude-sessions restore --user U --rebuild`, logs what a real restore
# did, stays quiet on the hourly no-op, and logs a failure without stopping the
# run.
#
# Run: bash scripts/test-t3-provision-agent-state.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }

extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract restore_agent_state)"
declare -F restore_agent_state >/dev/null || { echo "FAIL: restore_agent_state not found in $SCRIPT"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log() { echo "[t3-provision] $*" >> "$tmp/log"; }
export CALLS="$tmp/calls"
cat > "$tmp/homelab" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$FAKE_OUTCOME" in
  done) echo "claude-sessions restore --rebuild user=$4: already restored" >&2 ;;
  restored) echo "claude-sessions restore --rebuild user=$4 outcome=restored written=12 seeded=12" >&2
            echo "  WARN lines missing from the store, written without them: .claude/x.jsonl (9 bytes missing)" >&2 ;;
  fail) echo "homelab: restore for $4: clickhouse 503" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/homelab"
export HOMELAB_BIN="$tmp/homelab"
DRY_RUN=0

FAKE_OUTCOME=done; export FAKE_OUTCOME
: > "$tmp/log"; restore_agent_state emo; rc=$?
eq "the call" "claude-sessions restore --user emo --rebuild" "$(tail -n 1 "$CALLS")"
eq "an already restored user logs nothing" "" "$(cat "$tmp/log")"
eq "exit 0" 0 "$rc"

FAKE_OUTCOME=restored
: > "$tmp/log"; restore_agent_state ancamilea
eq "a restore logs every line" 2 "$(wc -l < "$tmp/log")"
eq "summary line" "[t3-provision] ancamilea: claude-sessions restore --rebuild user=ancamilea outcome=restored written=12 seeded=12" "$(head -n 1 "$tmp/log")"

FAKE_OUTCOME=fail
: > "$tmp/log"; restore_agent_state wizard; rc=$?
eq "a failure is a warning" "[t3-provision] WARN: agent state restore failed for wizard: homelab: restore for wizard: clickhouse 503" "$(cat "$tmp/log")"
eq "a failure does not stop the run" 0 "$rc"

DRY_RUN=1; : > "$CALLS"
out="$(restore_agent_state emo)"
eq "dry run calls nothing" "" "$(cat "$CALLS")"
eq "dry run says what it would do" "[dry-run] restore ~/.claude and ~/.codex from the session store -> emo" "$out"

HOMELAB_BIN="$tmp/none"; DRY_RUN=0; : > "$tmp/log"
restore_agent_state emo
eq "no binary is a warning" "[t3-provision] WARN: no $tmp/none -> agent state restore skipped for emo" "$(cat "$tmp/log")"

echo "agent-state: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
