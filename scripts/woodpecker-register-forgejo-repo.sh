#!/usr/bin/env bash
# Programmatically register a Forgejo repo in Woodpecker without needing the
# Web UI's OAuth flow.
#
# Earlier we believed only the OAuth login could create a working webhook
# because the webhook URL contains a JWT signed with a server-side key.
# That's true for the JWT, BUT the webhook is created server-side when the
# repo is activated through POST /api/repos — Woodpecker handles the JWT
# generation internally. We just need to call that endpoint as the right
# user (the one whose forge OAuth token can read the repo).
#
# The Woodpecker admin token (mine, ViktorBarzin@github) is a session JWT
# of the form `{"type":"user","user-id":"1"}` signed with the user's
# `hash` column (per-user, stored in the `users` table). Forge-API calls
# made on behalf of that user use the user's stored OAuth `access_token`
# from the same row. My GitHub admin can't read Forgejo repos, so the
# admin token can't activate Forgejo repos.
#
# The fix: mint a session JWT for the Forgejo `viktor` user (user_id=2)
# using `viktor`'s `hash`. Then POST /api/repos as viktor — viktor's
# stored Forgejo OAuth token has the access needed.
#
# Usage:
#   ./woodpecker-register-forgejo-repo.sh <forgejo-org/repo> [<forgejo-org/repo> ...]
# Example:
#   ./woodpecker-register-forgejo-repo.sh viktor/broker-sync viktor/freedify
#
# Requires:
# - vault CLI logged in (oidc or token), with read access to
#   secret/database/static-creds/pg-woodpecker AND a Forgejo PAT in
#   secret/viktor/forgejo_admin_token (or pass FORGEJO_TOKEN env var)
# - kubectl with cluster access (for the temporary psql pod)
# - openssl

set -euo pipefail

NS=${NS:-woodpecker}
WP_URL=${WP_URL:-https://ci.viktorbarzin.me}
FORGEJO_URL=${FORGEJO_URL:-https://forgejo.viktorbarzin.me}
FORGEJO_USER_LOGIN=${FORGEJO_USER_LOGIN:-viktor}

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <org/repo> [<org/repo> ...]" >&2
  exit 1
fi

# Pull viktor's `hash` from the woodpecker DB (used to sign the session JWT)
# and OAuth access_token (sanity check it exists).
WP_DB_USER=$(vault read -format=json database/static-creds/pg-woodpecker | jq -r .data.username)
WP_DB_PASS=$(vault read -format=json database/static-creds/pg-woodpecker | jq -r .data.password)

PG_POD=tmp-wp-register-$$
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $PG_POD, namespace: $NS }
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:15
    env: [{name: PGPASSWORD, value: "$WP_DB_PASS"}]
    command: ["sleep", "300"]
EOF
trap "kubectl delete pod -n $NS $PG_POD --wait=false >/dev/null 2>&1 || true" EXIT
for _ in $(seq 1 30); do
  PHASE=$(kubectl get pod -n $NS $PG_POD -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 1
done

VIKTOR_HASH=$(kubectl exec -n $NS $PG_POD -- psql -h pg-cluster-rw.dbaas -U "$WP_DB_USER" -d woodpecker -tA -c \
  "SELECT hash FROM users WHERE login='$FORGEJO_USER_LOGIN' AND forge_id=2" | tr -d '[:space:]')

if [ -z "$VIKTOR_HASH" ]; then
  echo "ERROR: no woodpecker user found for forge_id=2 login=$FORGEJO_USER_LOGIN" >&2
  echo "       (have they ever logged in via Forgejo OAuth?)" >&2
  exit 1
fi

# Mint a session JWT (HS256) for that user.
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
HEADER=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64)
PAYLOAD=$(printf '{"type":"user","user-id":"%s"}' \
  "$(kubectl exec -n $NS $PG_POD -- psql -h pg-cluster-rw.dbaas -U "$WP_DB_USER" -d woodpecker -tA -c \
       "SELECT id FROM users WHERE login='$FORGEJO_USER_LOGIN' AND forge_id=2" | tr -d '[:space:]')" | b64)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -hmac "$VIKTOR_HASH" -binary | b64)
TOKEN="$HEADER.$PAYLOAD.$SIG"

# Sanity check: am I really logged in as viktor?
ME=$(curl -sf "$WP_URL/api/user" -H "Authorization: Bearer $TOKEN" | jq -r '.login')
if [ "$ME" != "$FORGEJO_USER_LOGIN" ]; then
  echo "ERROR: minted token authenticates as '$ME', not '$FORGEJO_USER_LOGIN'" >&2
  exit 1
fi
echo "Authenticated as: $ME"

# Activate each repo via POST /api/repos?forge_remote_id=N
# Forgejo repo ID is fetched via the Forgejo API.
FORGEJO_AUTH="${FORGEJO_TOKEN:-$(vault kv get -field=forgejo_admin_token secret/viktor 2>/dev/null || true)}"
if [ -z "$FORGEJO_AUTH" ]; then
  echo "ERROR: set FORGEJO_TOKEN env or seed secret/viktor/forgejo_admin_token in vault" >&2
  exit 1
fi

for repo in "$@"; do
  FRID=$(curl -sf "$FORGEJO_URL/api/v1/repos/$repo" -H "Authorization: token $FORGEJO_AUTH" | jq -r .id 2>/dev/null || true)
  if [ -z "$FRID" ] || [ "$FRID" = "null" ]; then
    echo "  $repo: ERROR resolving Forgejo repo id" >&2
    continue
  fi
  HTTP=$(curl -s -X POST "$WP_URL/api/repos?forge_remote_id=$FRID" \
    -H "Authorization: Bearer $TOKEN" \
    -o /tmp/wp-add-$FRID.json -w "%{http_code}")
  case "$HTTP" in
    200) echo "  $repo: activated (id=$(jq -r .id /tmp/wp-add-$FRID.json))" ;;
    409) echo "  $repo: already active" ;;
    *)   echo "  $repo: HTTP $HTTP — $(cat /tmp/wp-add-$FRID.json)" ;;
  esac
  rm -f /tmp/wp-add-$FRID.json
done
