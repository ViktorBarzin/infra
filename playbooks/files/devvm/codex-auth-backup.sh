#!/usr/bin/env bash
# Snapshot the shared codex OAuth login to Vault whenever it changes, so the
# credential survives a devvm rebuild (codex ROTATES tokens, so a one-time backup
# goes stale). Triggered by systemd .path (on change) + .timer (daily fallback).
# Root has no Vault token -> source wizard's periodic vault-admin token (devvm pattern).
set -euo pipefail
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AUTH=/opt/codex-shared/auth.json
MARKER=/opt/codex-shared/.vault-backup.sha256
export VAULT_ADDR=https://vault.viktorbarzin.me
VTOKEN=/home/wizard/.vault-token
[ -r "$AUTH" ] || { echo "$(date -Is) auth.json missing/unreadable — skip"; exit 0; }
cur=$(sha256sum "$AUTH" | awk '{print $1}')
prev=$(cat "$MARKER" 2>/dev/null || true)
if [ "$cur" = "$prev" ]; then echo "$(date -Is) unchanged — skip"; exit 0; fi
[ -r "$VTOKEN" ] || { echo "$(date -Is) wizard vault token unreadable" >&2; exit 1; }
VAULT_TOKEN=$(cat "$VTOKEN"); export VAULT_TOKEN
if vault kv patch secret/workstation codex_shared_auth_json=@"$AUTH" >/dev/null 2>&1; then
  printf '%s' "$cur" > "$MARKER"
  echo "$(date -Is) backed up to vault (sha ${cur:0:12}…)"
else
  echo "$(date -Is) VAULT WRITE FAILED (token clobbered/read-only?)" >&2; exit 1
fi
