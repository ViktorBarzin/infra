#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=workstation/claude-auth-sync.sh
source "$DIR/workstation/claude-auth-sync.sh"

pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
valid='{"mcpOAuth":{"server":{"accessToken":"mcp-secret"}},"claudeAiOauth":{"accessToken":"access","refreshToken":"refresh","expiresAt":123,"scopes":["user:inference"]}}'
printf '%s\n' "$valid" > "$tmp/credentials.json"

oauth="$(cas_oauth_from_credentials "$tmp/credentials.json")"
eq "extract OAuth object" 'access' "$(jq -r .accessToken <<<"$oauth")"
printf '{"claudeAiOauth":{"accessToken":"access","expiresAt":123}}\n' > "$tmp/bad.json"
no "reject missing refresh token" cas_oauth_from_credentials "$tmp/bad.json"

replacement='{"accessToken":"new-access","refreshToken":"new-refresh","expiresAt":456}'
merged="$(cas_merge_oauth "$tmp/credentials.json" "$replacement")"
eq "replace Claude access token" new-access "$(jq -r .claudeAiOauth.accessToken <<<"$merged")"
eq "preserve MCP OAuth" mcp-secret "$(jq -r '.mcpOAuth.server.accessToken' <<<"$merged")"

export CAS_USER=emo
ok "accept own scoped Vault token" cas_vault_identity_ok token-devvm-claude-auth-emo default,workstation-claude-emo
no "reject another user's token" cas_vault_identity_ok token-devvm-claude-auth-anca default,workstation-claude-anca
no "reject wrong policy" cas_vault_identity_ok token-devvm-claude-auth-emo default,workstation-claude-anca

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
