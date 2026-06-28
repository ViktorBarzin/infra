#!/usr/bin/env bash
# Keep one Workstation user's Claude subscription OAuth credentials recoverable.
# Claude owns access/refresh-token rotation in ~/.claude/.credentials.json. This
# helper validates auth with real inference, stores only the claudeAiOauth object
# in the user's isolated Vault path, and attempts one restore on failure.
set -euo pipefail

CAS_USER="${CLAUDE_AUTH_USER:-$(id -un)}"
CAS_HOME="${HOME:?HOME must be set}"
CAS_CREDENTIALS="${CLAUDE_CREDENTIALS_FILE:-$CAS_HOME/.claude/.credentials.json}"
CAS_CONFIG_DIR="${CLAUDE_AUTH_CONFIG_DIR:-$CAS_HOME/.config/claude-auth-sync}"
CAS_VAULT_TOKEN_FILE="${CLAUDE_AUTH_VAULT_TOKEN_FILE:-$CAS_CONFIG_DIR/vault-token}"
CAS_VAULT_PATH="${CLAUDE_AUTH_VAULT_PATH:-secret/workstation/claude-users/$CAS_USER}"
CAS_STATE_DIR="${CLAUDE_AUTH_STATE_DIR:-$CAS_HOME/.local/state/claude-auth-sync}"
CAS_LOG="$CAS_STATE_DIR/sync.log"
# Where a long-lived per-user setup-token is materialized as an env file
# (KEY=VALUE) for start-claude.sh + t3-serve@.service to load. Lives under the
# already-ReadWritePaths config dir so the sandboxed service may write it.
CAS_TOKEN_ENV_FILE="${CLAUDE_AUTH_TOKEN_ENV_FILE:-$CAS_CONFIG_DIR/claude-oauth.env}"

cas_log() {
  mkdir -p "$CAS_STATE_DIR"
  printf '%s %s\n' "$(date -Is)" "$*" >> "$CAS_LOG"
  logger -t claude-auth-sync -- "user=$CAS_USER $*" 2>/dev/null || true
}

# Print the Claude OAuth object, or fail without exposing any token material.
cas_oauth_from_credentials() {
  jq -ce '.claudeAiOauth
    | select((.accessToken | type) == "string" and (.accessToken | length) > 0)
    | select((.refreshToken | type) == "string" and (.refreshToken | length) > 0)
    | select((.expiresAt | type) == "number")' "$1"
}

# Merge a recovered OAuth object while preserving unrelated credentials (MCP OAuth).
cas_merge_oauth() {
  local credentials="$1" oauth="$2"
  jq -ce --argjson oauth "$oauth" '.claudeAiOauth = $oauth' "$credentials"
}

cas_vault_identity_ok() {
  local display_name="$1" policies_csv="$2"
  [[ "$display_name" == "token-devvm-claude-auth-$CAS_USER" ]] || return 1
  printf ',%s,' "$policies_csv" | grep -q ",workstation-claude-$CAS_USER,"
}

cas_prepare_vault() {
  [[ -s "$CAS_VAULT_TOKEN_FILE" ]] || {
    cas_log "FAIL missing scoped Vault token; admin must run workstation provisioning"
    return 1
  }
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"
  VAULT_TOKEN="$(<"$CAS_VAULT_TOKEN_FILE")"; export VAULT_TOKEN

  local info display_name policies
  info="$(vault token lookup -format=json 2>/dev/null)" || {
    cas_log "FAIL scoped Vault token lookup failed"
    return 1
  }
  display_name="$(jq -r '.data.display_name // ""' <<<"$info")"
  policies="$(jq -r '((.data.policies // []) + (.data.identity_policies // [])) | join(",")' <<<"$info")"
  cas_vault_identity_ok "$display_name" "$policies" || {
    cas_log "FAIL scoped Vault token drift detected; refusing foreign token"
    return 1
  }
  vault token renew -format=json >/dev/null 2>&1 || {
    cas_log "FAIL scoped Vault token renewal failed"
    return 1
  }
}

# auth status is not authoritative: it reported loggedIn=true during a real 401
# on 2026-06-20. A tiny, non-persistent inference is the feedback loop.
cas_live_auth_ok() {
  local out
  out="$(timeout 60 claude -p 'Reply with exactly AUTH_OK and nothing else.' \
    --model haiku --max-turns 1 --no-session-persistence --tools "" \
    --disable-slash-commands --setting-sources "" 2>/dev/null)" || return 1
  [[ "$out" == "AUTH_OK" ]]
}

cas_backup() {
  local oauth expires
  oauth="$(cas_oauth_from_credentials "$CAS_CREDENTIALS")" || {
    cas_log "FAIL local Claude OAuth credential is absent or malformed"
    return 1
  }
  expires="$(jq -r '.expiresAt' <<<"$oauth")"
  # MERGE into the shared path so sibling keys other tools co-locate there
  # (e.g. `homelab vault`'s vaultwarden_* creds) survive. `kv patch -method=rw`
  # is read+update (needs no `patch` capability) but requires the secret to
  # already exist, so create it with `kv put` on the very first backup only.
  local -a write_cmd
  if vault kv get "$CAS_VAULT_PATH" >/dev/null 2>&1; then
    write_cmd=(vault kv patch -method=rw "$CAS_VAULT_PATH")
  else
    write_cmd=(vault kv put "$CAS_VAULT_PATH")
  fi
  "${write_cmd[@]}" \
    claude_ai_oauth_json="$oauth" \
    credential_expires_at_ms="$expires" \
    backed_up_at="$(date -Is)" >/dev/null || {
      cas_log "FAIL Vault credential backup failed"
      return 1
    }
  cas_log "OK Claude auth valid; refreshed OAuth state backed up to Vault"
}

cas_restore() {
  local oauth base tmp
  oauth="$(vault kv get -field=claude_ai_oauth_json "$CAS_VAULT_PATH" 2>/dev/null)" || {
    cas_log "FAIL no recoverable Claude OAuth credential in Vault"
    return 1
  }
  jq -e 'select((.accessToken | type) == "string" and (.accessToken | length) > 0)
    | select((.refreshToken | type) == "string" and (.refreshToken | length) > 0)
    | select((.expiresAt | type) == "number")' <<<"$oauth" >/dev/null || {
      cas_log "FAIL Vault Claude OAuth credential is malformed"
      return 1
    }

  mkdir -p "$(dirname "$CAS_CREDENTIALS")"
  if jq -e 'type == "object"' "$CAS_CREDENTIALS" >/dev/null 2>&1; then
    base="$CAS_CREDENTIALS"
  else
    base="$(mktemp)"; printf '{}\n' > "$base"
  fi
  tmp="$(mktemp "${CAS_CREDENTIALS}.XXXXXX")"
  if ! cas_merge_oauth "$base" "$oauth" > "$tmp"; then
    rm -f "$tmp"; [[ "$base" == "$CAS_CREDENTIALS" ]] || rm -f "$base"
    cas_log "FAIL could not merge Vault Claude OAuth credential"
    return 1
  fi
  chmod 0600 "$tmp"
  mv "$tmp" "$CAS_CREDENTIALS"
  [[ "$base" == "$CAS_CREDENTIALS" ]] || rm -f "$base"
  cas_log "RECOVERED restored Claude OAuth state from Vault"
}

# A user-scoped, long-lived setup-token (`sk-ant-oat01-…`, ~1y, NON-rotating) may
# be stored in this user's OWN Vault path (field `setup_token`). When present it
# is the authoritative credential: it bypasses the shared
# ~/.claude/.credentials.json OAuth refresh-token rotation entirely — the fix for
# users running many concurrent Claude sessions (interactive + t3-serve + always-on
# agents) that otherwise race on refresh and wipe each other's refresh token.
# We materialize it to a user-owned env file that start-claude.sh and
# t3-serve@.service load as CLAUDE_CODE_OAUTH_TOKEN. This is the user's OWN
# Enterprise identity, NOT the forbidden legacy SHARED token — it never crosses
# OS users. Returns 0 when a token is active, so the caller skips the
# rotating-credential validate/backup/restore (probing the now-vestigial
# credential would otherwise emit false WorkstationClaudeAuthInvalid alerts).
cas_sync_setup_token() {
  local token desired tmp
  token="$(vault kv get -field=setup_token "$CAS_VAULT_PATH" 2>/dev/null)" || token=""
  if [[ "$token" != sk-ant-oat01-* ]]; then
    if [[ -e "$CAS_TOKEN_ENV_FILE" ]]; then
      rm -f "$CAS_TOKEN_ENV_FILE"
      cas_log "removed stale CLAUDE_CODE_OAUTH_TOKEN env (no setup-token in Vault)"
    fi
    return 1
  fi
  desired="CLAUDE_CODE_OAUTH_TOKEN=$token"
  if [[ -r "$CAS_TOKEN_ENV_FILE" && "$(<"$CAS_TOKEN_ENV_FILE")" == "$desired" ]]; then
    cas_log "OK long-lived setup-token active (CLAUDE_CODE_OAUTH_TOKEN current); credential checks skipped"
    return 0
  fi
  tmp="$(mktemp "${CAS_TOKEN_ENV_FILE}.XXXXXX")" || { cas_log "FAIL could not stage token env file"; return 1; }
  printf '%s\n' "$desired" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$CAS_TOKEN_ENV_FILE"
  cas_log "OK long-lived setup-token active; CLAUDE_CODE_OAUTH_TOKEN materialized; credential checks skipped"
  return 0
}

cas_main() {
  umask 077
  for bin in jq vault claude timeout flock; do
    command -v "$bin" >/dev/null || { cas_log "FAIL missing dependency: $bin"; return 1; }
  done
  mkdir -p "$CAS_STATE_DIR"
  exec 9>"$CAS_STATE_DIR/lock"
  flock -n 9 || { cas_log "SKIP another sync is already running"; return 0; }

  cas_prepare_vault || return 1
  # A long-lived per-user setup-token, if provisioned, is authoritative and
  # non-rotating — materialize it and skip the rotating-credential dance.
  if cas_sync_setup_token; then
    return 0
  fi
  if cas_live_auth_ok; then
    cas_backup
    return
  fi

  cas_log "WARN live Claude auth failed; attempting one Vault restore"
  cas_restore || return 1
  if cas_live_auth_ok; then
    cas_backup
    return
  fi
  cas_log "FAIL Claude auth still invalid after Vault restore; interactive SSO login required"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cas_main "$@"
fi
