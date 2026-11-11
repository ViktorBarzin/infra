#!/usr/bin/env bash
# Stage each person's hub config for the devvm provisioner.
#
# One hub per person (docs/architecture/chrome-service.md "One hub per person"):
# a cluster Chrome holding that person's logins. chrome-hubs.json beside this
# script maps an OS user to their hub's Vault path, host and namespace. For each
# entry this writes /etc/t3-serve/chrome-hub-<user>.json (root, 0600), the exact
# ~/.config/chrome-hub/hub.json that t3-provision-users (install_chrome_hub)
# copies to that user whenever it differs.
#
# Needs root and an admin Vault token in VAULT_TOKEN. Run by setup-devvm.sh
# section 8c, or alone after a token rotation, reading the token inside sudo
# (sudo logs a VAULT_TOKEN= or --preserve-env value to auth.log and Loki):
#   sudo bash -c 'VAULT_TOKEN="$(cat "/home/$SUDO_USER/.vault-token")" exec bash scripts/workstation/stage-chrome-hubs.sh'
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP="${CHROME_HUBS_MAP:-$HERE/chrome-hubs.json}"
OUT_DIR="${CHROME_HUBS_OUT:-/etc/t3-serve}"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"

log() { echo "[stage-chrome-hubs] $*"; }

install -d -m 0755 "$OUT_DIR"
for user in $(jq -r 'keys[]' "$MAP"); do
  path="$(jq -r --arg u "$user" '.[$u].vault_path' "$MAP")"
  host="$(jq -r --arg u "$user" '.[$u].host' "$MAP")"
  ns="$(jq -r --arg u "$user" '.[$u].namespace' "$MAP")"
  if ! secret="$(vault kv get -format=json "secret/$path" 2>/dev/null)"; then
    log "WARN: secret/$path unreadable -> $user's hub not staged"
    continue
  fi
  read_token="$(jq -r '.data.data.api_bearer_token // empty' <<<"$secret")"
  write_token="$(jq -r '.data.data.api_write_token // empty' <<<"$secret")"
  if [[ -z "$read_token" || -z "$write_token" ]]; then
    log "WARN: secret/$path lacks api_bearer_token or api_write_token -> $user skipped"
    continue
  fi
  jq -n --arg user "$user" --arg ns "$ns" --arg host "$host" \
        --arg read "$read_token" --arg write "$write_token" '{
      user: $user,
      namespace: $ns,
      snapshot_url: "https://\($host)/api/snapshot",
      cookies_url: "https://\($host)/api/cookies",
      broker_url: "https://chrome-fleet-api.viktorbarzin.me",
      read_token: $read,
      write_token: $write
    }' | install -m 0600 /dev/stdin "$OUT_DIR/chrome-hub-$user.json"
  log "staged $OUT_DIR/chrome-hub-$user.json"
done

# The old single token, which every user received and which read Viktor's hub.
# Nothing reads it once every user has a hub file.
if [[ -e "$OUT_DIR/chrome-service-token" ]]; then
  rm -f "$OUT_DIR/chrome-service-token"
  log "removed the legacy shared $OUT_DIR/chrome-service-token"
fi
