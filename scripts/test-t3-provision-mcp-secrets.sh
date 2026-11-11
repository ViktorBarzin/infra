#!/usr/bin/env bash
# Checks fill_mcp_secrets, the t3-provision-users.sh step that puts a user's
# MCP server secrets back from Vault into the redacted ~/.claude.json and
# ~/.codex/config.toml the session store restored
# (docs/plans/2026-11-11-disposable-devvm.md): it runs only with an admin
# Vault token, only once the user's agent state is restored and only once per
# user (a marker), hands the token in the environment and never on the
# command line, stays quiet when there is nothing to fill, and logs a failure
# without stopping the run or marking the user.
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
CLAUDE_SESSIONS_MCP_FILLED_DIR="$tmp/filled"
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

FAKE_OUTCOME=fail; : > "$tmp/log"
fill_mcp_secrets emo; rc=$?
eq "a failure is a warning" "[t3-provision] WARN: MCP secret fill failed for emo: homelab: vault kv get secret/workstation/emo/mcp: permission denied" "$(cat "$tmp/log")"
eq "a failure does not stop the run" 0 "$rc"
[[ -e "$CLAUDE_SESSIONS_MCP_FILLED_DIR/emo" ]]; eq "a failure leaves no marker" 1 "$?"

FAKE_OUTCOME=nothing; : > "$tmp/log"; : > "$CALLS"
fill_mcp_secrets emo
eq "the call, token in the environment only" "claude-sessions mcp-secrets fill --user emo token=set" "$(tail -n 1 "$CALLS")"
eq "nothing to fill logs nothing" "" "$(cat "$tmp/log")"
grep -q "hvs.test-admin" "$CALLS"; eq "the token is not on the command line" 1 "$?"
[[ -s "$CLAUDE_SESSIONS_MCP_FILLED_DIR/emo" ]]; eq "a fill that ran marks the user" 0 "$?"

: > "$CALLS"
fill_mcp_secrets emo
eq "a marked user is not filled again" "" "$(cat "$CALLS")"

rm -f "$CLAUDE_SESSIONS_MCP_FILLED_DIR/emo"
FAKE_OUTCOME=filled; : > "$tmp/log"
fill_mcp_secrets emo
eq "a fill is logged" "[t3-provision] emo: mcp-secrets fill user=emo: secrets put back: .claude.json mcpServers.paperless" "$(cat "$tmp/log")"
rm -f "$CLAUDE_SESSIONS_MCP_FILLED_DIR/emo"

DRY_RUN=1; : > "$CALLS"
out="$(fill_mcp_secrets emo)"
eq "dry run calls nothing" "" "$(cat "$CALLS")"
eq "dry run says what it would do" "[dry-run] fill MCP server secrets from Vault -> emo" "$out"

grep -q 'fill_mcp_secrets "$u"' "$SCRIPT"; eq "the step runs for every roster user" 0 "$?"

# install_mcp_tools: the home-local programs a restored MCP config starts.
eval "$(extract install_mcp_tools)"
declare -F install_mcp_tools >/dev/null || { echo "FAIL: install_mcp_tools not found in $SCRIPT"; exit 1; }
eval "$(grep -E '^MCP_(UV|PHPIPAM)_[A-Z0-9_]+=' "$SCRIPT")"
H="$tmp/home/emo"; mkdir -p "$H/.codex"
getent() { echo "emo:x:1002:1002::$H:/bin/zsh"; }
runuser() { echo "runuser $*" >> "$CALLS"; [[ "${FAKE_RUNUSER:-ok}" == ok ]]; }
DRY_RUN=0; : > "$tmp/log"; : > "$CALLS"
echo '{"mcpServers":{"pl":{"command":"npx"}}}' > "$H/.claude.json"
install_mcp_tools emo
eq "a config without home-local programs installs nothing" "" "$(cat "$CALLS")"
echo '{"mcpServers":{"gw":{"command":"'"$H"'/.local/bin/uvx","args":["workspace-mcp"]}}}' > "$H/.claude.json"
printf '[mcp_servers.phpipam]\ncommand = "%s/.local/share/phpipam-mcp/bin/phpipam-mcp-server"\n' "$H" > "$H/.codex/config.toml"
install_mcp_tools emo
eq "uv, then the phpipam venv, both as the user" 2 "$(grep -c "^runuser -u emo -- env -i " "$CALLS")"
grep -q "/$MCP_UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz $MCP_UV_SHA256\$" "$CALLS"; eq "uv is pinned by version and checksum" 0 "$?"
grep -q " _ phpipam-mcp-server==$MCP_PHPIPAM_VERSION .*mcp==1.14.1 .*starlette==" "$CALLS"; eq "phpipam and what it pulls in are pinned" 0 "$?"
eq "both installs are logged" 2 "$(grep -c 'emo: installed' "$tmp/log")"
mkdir -p "$H/.local/bin" "$H/.local/share/phpipam-mcp/bin"
touch "$H/.local/bin/uvx" "$H/.local/share/phpipam-mcp/bin/phpipam-mcp-server"; chmod +x "$H/.local/bin/uvx" "$H/.local/share/phpipam-mcp/bin/phpipam-mcp-server"
: > "$CALLS"; install_mcp_tools emo
eq "programs already there are left alone" "" "$(cat "$CALLS")"
rm -f "$H/.local/bin/uvx"; FAKE_RUNUSER=fail; : > "$tmp/log"; install_mcp_tools emo; rc=$?
eq "a failed install is a warning" 1 "$(grep -c 'WARN: could not install uv' "$tmp/log")"
eq "a failed install does not stop the run" 0 "$rc"
FAKE_RUNUSER=ok; rm -f "$CLAUDE_SESSIONS_RESTORED_DIR/emo"; : > "$CALLS"; install_mcp_tools emo
eq "not restored yet: nothing installed" "" "$(cat "$CALLS")"
grep -q 'install_mcp_tools "$u"' "$SCRIPT"; eq "the tools step runs for every roster user" 0 "$?"

echo "mcp-secrets: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
