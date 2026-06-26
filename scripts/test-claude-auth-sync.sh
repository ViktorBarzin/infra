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

# --- Regression: cas_backup must MERGE into the shared Vault path, preserving
# sibling keys that other tools co-locate there (e.g. `homelab vault`'s
# vaultwarden_* creds) — NOT overwrite the whole KV document. A blind `kv put`
# wiped them every 6h (claude-auth-sync clobber, 2026-06-26).
fakebin="$tmp/bin"; mkdir -p "$fakebin"
store="$tmp/vault-store.json"
cat > "$fakebin/vault" <<'FAKE'
#!/usr/bin/env bash
# Minimal KV-v2 fake backed by $VAULT_FAKE_STORE (a flat JSON object).
[[ "$1" == kv ]] || { echo '{}'; exit 0; }   # token lookup etc. -> ignore
op="$2"; shift 2
store="$VAULT_FAKE_STORE"
case "$op" in
  get)
    for a in "$@"; do [[ "$a" == -field=* ]] && field="${a#-field=}"; done
    if [[ "$*" == *-format=json* ]]; then
      [[ -f "$store" ]] || { echo "No value found"; exit 2; }
      jq -n --argjson d "$(cat "$store")" '{data:{data:$d}}'; exit 0
    fi
    [[ -f "$store" ]] || exit 2                # bare get == existence check
    if [[ -n "${field:-}" ]]; then
      v="$(jq -r --arg k "$field" '.[$k] // empty' "$store")"; [[ -n "$v" ]] || exit 1
      printf '%s' "$v"; exit 0
    fi
    exit 0 ;;
  put)   echo '{}' > "$store" ;;                          # full replace
  patch) [[ -f "$store" ]] || { echo "No value found"; exit 2; } ;;  # merge (rw)
  *) exit 1 ;;
esac
for a in "$@"; do
  case "$a" in
    -*|secret/*) continue ;;                  # flags + the path arg
    *=*) k="${a%%=*}"; v="${a#*=}"
         t="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$store" > "$t" && mv "$t" "$store" ;;
  esac
done
exit 0
FAKE
chmod +x "$fakebin/vault"

CAS_VAULT_PATH="secret/workstation/claude-users/test"
CAS_CREDENTIALS="$tmp/credentials.json"
CAS_STATE_DIR="$tmp/state"
_oldpath="$PATH"; PATH="$fakebin:$PATH"; export VAULT_FAKE_STORE="$store"

printf '{"vaultwarden_master_password":"keep-me"}\n' > "$store"   # pretend `homelab vault setup` ran
ok "backup succeeds (existing doc)"   cas_backup
eq "merge preserves sibling key"      keep-me "$(jq -r '.vaultwarden_master_password' "$store")"
eq "merge writes claude oauth"        access  "$(jq -r '.claude_ai_oauth_json|fromjson|.accessToken' "$store")"

rm -f "$store"                                                    # fresh user: no doc yet
ok "backup succeeds (creates doc)"    cas_backup
eq "create writes claude oauth"       access  "$(jq -r '.claude_ai_oauth_json|fromjson|.accessToken' "$store")"

PATH="$_oldpath"; unset VAULT_FAKE_STORE

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
