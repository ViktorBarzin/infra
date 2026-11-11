#!/usr/bin/env bash
# Checks fill_mcp_secrets, the t3-provision-users.sh step that puts a user's
# MCP server secrets back from Vault into the redacted ~/.claude.json and
# ~/.codex/config.toml the session store restored
# (docs/plans/2026-11-11-disposable-devvm.md): it runs only with an admin
# Vault token and only once the user's agent state is restored, hands the
# token in the environment and never on the command line, stays quiet when
# there is nothing to fill, and logs a failure without stopping the run.
#
# Run: bash scripts/test-t3-provision-mcp-secrets.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }

extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract fill_mcp_secrets)"
eval "$(extract agent_state_restored)"
declare -F fill_mcp_secrets >/dev/null || { echo "FAIL: fill_mcp_secrets not found in $SCRIPT"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log() { echo "[t3-provision] $*" >> "$tmp/log"; }
export CALLS="$tmp/calls"
cat > "$tmp/homelab" <<'STUB'
#!/usr/bin/env bash
echo "$* token=${VAULT_TOKEN:+set}" >> "$CALLS"
case "$FAKE_OUTCOME" in
  nothing) ;;
  filled) echo "mcp-secrets fill user=$5: secrets put back: .claude.json mcpServers.paperless" >&2 ;;
  fail) echo "homelab: vault kv get secret/workstation/$5/mcp: permission denied" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/homelab"
export HOMELAB_BIN="$tmp/homelab"
CLAUDE_SESSIONS_RESTORED_DIR="$tmp/restored"; mkdir -p "$CLAUDE_SESSIONS_RESTORED_DIR"
touch "$CLAUDE_SESSIONS_RESTORED_DIR/emo"
ADMIN_VAULT_TOKEN="hvs.test-admin"
token_ok=0
vault_admin() { [[ "$token_ok" == 1 ]]; }
DRY_RUN=0

: > "$tmp/log"; : > "$CALLS"; FAKE_OUTCOME=nothing; export FAKE_OUTCOME
fill_mcp_secrets emo; rc=$?
eq "no admin token: no call" "" "$(cat "$CALLS")"
eq "no admin token: quiet" "" "$(cat "$tmp/log")"
eq "exit 0" 0 "$rc"

token_ok=1
fill_mcp_secrets wizard
eq "not restored yet: no call" "" "$(cat "$CALLS")"

fill_mcp_secrets emo
eq "the call, token in the environment only" "claude-sessions mcp-secrets fill --user emo token=set" "$(tail -n 1 "$CALLS")"
eq "nothing to fill logs nothing" "" "$(cat "$tmp/log")"
grep -q "hvs.test-admin" "$CALLS"; eq "the token is not on the command line" 1 "$?"

FAKE_OUTCOME=filled; : > "$tmp/log"
fill_mcp_secrets emo
eq "a fill is logged" "[t3-provision] emo: mcp-secrets fill user=emo: secrets put back: .claude.json mcpServers.paperless" "$(cat "$tmp/log")"

FAKE_OUTCOME=fail; : > "$tmp/log"
fill_mcp_secrets emo; rc=$?
eq "a failure is a warning" "[t3-provision] WARN: MCP secret fill failed for emo: homelab: vault kv get secret/workstation/emo/mcp: permission denied" "$(cat "$tmp/log")"
eq "a failure does not stop the run" 0 "$rc"

DRY_RUN=1; : > "$CALLS"
out="$(fill_mcp_secrets emo)"
eq "dry run calls nothing" "" "$(cat "$CALLS")"
eq "dry run says what it would do" "[dry-run] fill MCP server secrets from Vault -> emo" "$out"

grep -q 'fill_mcp_secrets "$u"' "$SCRIPT"; eq "the step runs for every roster user" 0 "$?"

echo "mcp-secrets: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
