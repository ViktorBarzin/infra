#!/bin/sh
# meshcentral's fix-config init container (stacks/meshcentral/main.tf): owns
# config.json on the data volume and patches it before MeshCentral starts.
# Test: sh stacks/meshcentral/files/fix-config_test.sh
set -e
CONFIG="${CONFIG:-/opt/meshcentral/meshcentral-data/config.json}"

# sessionKey signs MeshCentral's web session cookie, so whoever holds it can
# forge a login. It comes from Vault secret/meshcentral (field session_key)
# through the meshcentral-secrets ExternalSecret, which means a fresh volume
# gets the same key and no copy has to live anywhere else. Checked before any
# edit: a missing or odd key stops the pod with config.json untouched. Only
# letters and digits, so the value never needs escaping.
case "$SESSION_KEY" in
  "" | *[!A-Za-z0-9]*)
    echo "fix-config: SESSION_KEY is empty or holds characters other than letters and digits" >&2
    exit 1
    ;;
esac

# DB_KEY_GENERATION (a plain label in main.tf, not a secret) rotates the keys
# MeshCentral keeps in meshcentral.db rather than in config.json:
# LoginCookieEncryptionKey (whoever holds it can forge a login cookie for any
# user, admin included, and /control.ashx sits on the auth=none ingress),
# InvitationLinkEncryptionKey (invitation, agent download and guest sharing
# links) and dbconfig's amtWsEventSecret (Intel AMT event passwords). When
# the label differs from the one in db-key-generation on the volume, those
# records are dropped before the server starts, and MeshCentral writes fresh
# random ones on start. Logins and links made with the old keys stop working.
# Agents are not affected: they use the mesh certificates. Rollback is
# MeshCentral's nightly autobackup zip on the backups volume.
case "${DB_KEY_GENERATION:-}" in
  *[!A-Za-z0-9.-]*)
    echo "fix-config: DB_KEY_GENERATION holds characters other than letters, digits, dot and dash" >&2
    exit 1
    ;;
esac
DATA_DIR=$(dirname "$CONFIG")
DB="$DATA_DIR/meshcentral.db"
MARKER="$DATA_DIR/db-key-generation"
if [ -n "${DB_KEY_GENERATION:-}" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" != "$DB_KEY_GENERATION" ]; then
  if [ -f "$DB" ]; then
    grep -v -e '"_id":"LoginCookieEncryptionKey"' -e '"_id":"InvitationLinkEncryptionKey"' "$DB" |
      sed '/"_id":"dbconfig"/{s/,"amtWsEventSecret":"[0-9A-Fa-f]*"//;s/"amtWsEventSecret":"[0-9A-Fa-f]*",//;}' > "$DB.new"
    cat "$DB.new" > "$DB"
    rm -f "$DB.new"
    echo "fix-config: dropped the meshcentral.db keys for generation $DB_KEY_GENERATION; MeshCentral generates new ones"
  fi
  echo "$DB_KEY_GENERATION" > "$MARKER"
fi

if [ -f "$CONFIG" ]; then
  # Disable certUrl when using Traefik reverse proxy with TLS offload
  sed -i 's/"certUrl":/"_certUrl":/g' "$CONFIG"

  # Fix WebRTC value from string to boolean
  sed -i 's/"WebRTC": "[^"]*"/"WebRTC": false/g' "$CONFIG"

  # Ensure TLSOffload is enabled (Traefik terminates TLS, MeshCentral serves HTTP on 443)
  sed -i 's/"_TLSOffload":/"TLSOffload":/g' "$CONFIG"
  sed -i 's/"TLSOffload": "[^"]*"/"TLSOffload": true/g' "$CONFIG"
  sed -i 's/"TLSOffload": false/"TLSOffload": true/g' "$CONFIG"

  # Keep self-service sign-up off. The image's generated config carried
  # "NewAccounts": "true" (a string, which MeshCentral reads as on), and the
  # first-run template below only applies to a fresh volume. Found live on
  # 2026-10-09 while enrolling Milka's phone.
  sed -i 's/"NewAccounts": *"true"/"NewAccounts": false/g; s/"NewAccounts": *true/"NewAccounts": false/g' "$CONFIG"

  # ignoreAgentHashCheck: stop pinning the OUTER (Traefik) TLS cert hash on the
  # agent handshake. With TLS offload, the agent sees Traefik's Let's Encrypt
  # cert (which also differs between the internal .203 LB and the external
  # Cloudflare path, and rotates ~monthly), not MeshCentral's own webserver
  # cert — so the default cert-pin fails with "Agent bad web cert hash" and
  # holds EVERY agent connection (the whole fleet went offline). With this set,
  # MeshCentral echoes back whatever cert hash the agent reports, so the
  # pin succeeds on any path/cert. The agent's separate mesh-certificate
  # handshake (ServerID) still authenticates the server — this only drops the
  # redundant outer-TLS pin, which is safe behind our trusted-network Traefik.
  # Insert the key right after TLSOffload (guaranteed present post-patch) if not
  # already there. MeshCentral lowercases settings keys, so casing is flexible.
  if ! grep -qi '"ignoreAgentHashCheck"' "$CONFIG"; then
    sed -i 's/"TLSOffload": true/"TLSOffload": true,\n    "ignoreAgentHashCheck": true/' "$CONFIG"
  fi
else
  # First run: create config from template before MeshCentral starts, so the
  # image's own template (no TLSOffload, NewAccounts on) is never used.
  cat > "$CONFIG" <<'CONF'
{
  "$schema": "http://info.meshcentral.com/downloads/meshcentral-config-schema.json",
  "settings": {
    "cert": "meshcentral.viktorbarzin.me",
    "_WANonly": true,
    "_LANonly": true,
    "port": 443,
    "redirPort": 80,
    "AgentPong": 300,
    "TLSOffload": true,
    "ignoreAgentHashCheck": true,
    "SelfUpdate": false,
    "AllowFraming": false,
    "WebRTC": false
  },
  "domains": {
    "": {
      "NewAccounts": false
    }
  }
}
CONF
fi

# Write the sessionKey: replace the value in place, or add it as the first
# setting. awk takes the key from its environment, not its arguments, so it
# never shows in a process list. The result is written back through the same
# file, which keeps config.json owned by the node user.
awk '
  BEGIN { key = ENVIRON["SESSION_KEY"]; done = 0 }
  !done && /"sessionKey"[ ]*:/ {
    sub(/"sessionKey"[ ]*:[ ]*"[^"]*"/, "\"sessionKey\": \"" key "\"")
    done = 1
  }
  { print }
  !done && !has && /"settings"[ ]*:[ ]*\{[ ]*$/ { print "    \"sessionKey\": \"" key "\","; done = 1 }
' has="$(grep -c '"sessionKey"' "$CONFIG" || true)" "$CONFIG" > "$CONFIG.new"
cat "$CONFIG.new" > "$CONFIG"
rm -f "$CONFIG.new"
