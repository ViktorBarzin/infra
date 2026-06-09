#!/usr/bin/env bash
#
# Setup script for the Forgejo task ingestion pipeline.
# Creates Authentik OAuth2 provider/application, configures Forgejo OAuth2 auth source,
# creates "tasks" repo, and sets up webhook to n8n.
#
# Prerequisites:
#   - Authentik admin API token
#   - Forgejo admin API token (create at https://forgejo.viktorbarzin.me/user/settings/applications)
#
# Usage:
#   AUTHENTIK_TOKEN="..." FORGEJO_TOKEN="..." bash scripts/setup-task-pipeline.sh

set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-https://authentik.viktorbarzin.me}"
FORGEJO_URL="${FORGEJO_URL:-https://forgejo.viktorbarzin.me}"
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-https://n8n.viktorbarzin.me/webhook/forgejo-tasks}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-viktor}"

: "${AUTHENTIK_TOKEN:?Set AUTHENTIK_TOKEN (Authentik admin API token)}"
: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN (Forgejo admin API token)}"

ak_api() { curl -sf -H "Authorization: Bearer $AUTHENTIK_TOKEN" -H "Content-Type: application/json" "$@"; }
fg_api() { curl -sf -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" "$@"; }

echo "=== Step 1: Create Authentik group 'Task Submitters' ==="
GROUP_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/core/groups/" -d '{
  "name": "Task Submitters",
  "is_superuser": false,
  "parent": null
}' 2>/dev/null) || {
  echo "  Group may already exist, checking..."
  GROUP_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/core/groups/?name=Task+Submitters" | python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(json.dumps(r[0]) if r else '')")
  if [ -z "$GROUP_RESP" ]; then echo "ERROR: Failed to create or find group"; exit 1; fi
}
GROUP_PK=$(echo "$GROUP_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
echo "  Group PK: $GROUP_PK"

echo ""
echo "=== Step 2: Create Authentik OAuth2 Provider for Forgejo ==="
# Find the explicit consent authorization flow
AUTH_FLOW=$(ak_api "$AUTHENTIK_URL/api/v3/flows/instances/?designation=authorization&search=explicit" | \
  python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['pk'] if r else '')")
if [ -z "$AUTH_FLOW" ]; then
  echo "  WARNING: Could not find explicit consent flow, using implicit"
  AUTH_FLOW=$(ak_api "$AUTHENTIK_URL/api/v3/flows/instances/?designation=authorization" | \
    python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['pk'] if r else '')")
fi
echo "  Authorization flow: $AUTH_FLOW"

PROVIDER_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/providers/oauth2/" -d "{
  \"name\": \"Forgejo\",
  \"authorization_flow\": \"$AUTH_FLOW\",
  \"client_type\": \"confidential\",
  \"redirect_uris\": \"$FORGEJO_URL/user/oauth2/Authentik/callback\",
  \"property_mappings\": [],
  \"sub_mode\": \"hashed_user_id\",
  \"include_claims_in_id_token\": true,
  \"access_code_validity\": \"minutes=1\",
  \"access_token_validity\": \"minutes=5\",
  \"refresh_token_validity\": \"days=30\"
}" 2>/dev/null) || {
  echo "  Provider may already exist, checking..."
  PROVIDER_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/providers/oauth2/?name=Forgejo" | \
    python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(json.dumps(r[0]) if r else '')")
  if [ -z "$PROVIDER_RESP" ]; then echo "ERROR: Failed to create or find provider"; exit 1; fi
}
PROVIDER_PK=$(echo "$PROVIDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
CLIENT_ID=$(echo "$PROVIDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
CLIENT_SECRET=$(echo "$PROVIDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret','<already-created>'))")
echo "  Provider PK: $PROVIDER_PK"
echo "  Client ID: $CLIENT_ID"
echo "  Client Secret: $CLIENT_SECRET"

echo ""
echo "=== Step 3: Create Authentik Application for Forgejo ==="
APP_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/core/applications/" -d "{
  \"name\": \"Forgejo\",
  \"slug\": \"forgejo\",
  \"provider\": $PROVIDER_PK,
  \"meta_launch_url\": \"$FORGEJO_URL\",
  \"policy_engine_mode\": \"any\"
}" 2>/dev/null) || {
  echo "  Application may already exist, checking..."
  APP_RESP=$(ak_api "$AUTHENTIK_URL/api/v3/core/applications/?slug=forgejo" | \
    python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(json.dumps(r[0]) if r else '')")
}
APP_SLUG=$(echo "$APP_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['slug'])")
echo "  Application slug: $APP_SLUG"

echo ""
echo "=== Step 4: Bind 'Task Submitters' group to Forgejo application ==="
# Create a policy binding that restricts access to the Task Submitters group
ak_api "$AUTHENTIK_URL/api/v3/policies/bindings/" -d "{
  \"target\": \"$(echo "$APP_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")\",
  \"group\": \"$GROUP_PK\",
  \"enabled\": true,
  \"order\": 0,
  \"negate\": false,
  \"timeout\": 30
}" > /dev/null 2>&1 || echo "  Binding may already exist (OK)"
echo "  Group binding created"

echo ""
echo "=== Step 5: Add users to 'Task Submitters' group ==="
echo "  Adding Viktor Barzin..."
VIKTOR_PK=$(ak_api "$AUTHENTIK_URL/api/v3/core/users/?search=vbarzin" | \
  python3 -c "import sys,json; r=json.load(sys.stdin)['results']; print(r[0]['pk'] if r else '')")
if [ -n "$VIKTOR_PK" ]; then
  ak_api "$AUTHENTIK_URL/api/v3/core/groups/$GROUP_PK/" -X PATCH -d "{}" > /dev/null 2>&1 || true
  ak_api -X POST "$AUTHENTIK_URL/api/v3/core/groups/$GROUP_PK/add_user/" -d "{\"pk\": $VIKTOR_PK}" > /dev/null 2>&1 || true
  echo "  Added Viktor (PK: $VIKTOR_PK)"
fi

echo ""
echo "=== Step 6: Configure Forgejo OAuth2 authentication source ==="
fg_api "$FORGEJO_URL/api/v1/admin/identity-sources" -d "{
  \"authentication_source\": {
    \"name\": \"Authentik\",
    \"type\": \"oauth2\",
    \"is_active\": true,
    \"is_sync_enabled\": false,
    \"oauth2\": {
      \"provider\": \"openidConnect\",
      \"client_id\": \"$CLIENT_ID\",
      \"client_secret\": \"$CLIENT_SECRET\",
      \"open_id_connect_auto_discovery_url\": \"$AUTHENTIK_URL/application/o/forgejo/.well-known/openid-configuration\",
      \"scopes\": [\"openid\", \"profile\", \"email\"],
      \"required_claim_name\": \"\",
      \"required_claim_value\": \"\",
      \"group_claim_name\": \"\",
      \"admin_group\": \"\",
      \"restricted_group\": \"\",
      \"icon_url\": \"\",
      \"skip_local_2fa\": true,
      \"attribute_ssn\": \"\"
    }
  }
}" > /dev/null 2>&1 && echo "  OAuth2 source created" || {
  echo "  Forgejo identity-sources API may not be available."
  echo "  Falling back to legacy authentication-source API..."
  fg_api "$FORGEJO_URL/api/v1/admin/auths" -d "{
    \"name\": \"Authentik\",
    \"type\": 6,
    \"is_active\": true,
    \"is_sync_enabled\": false,
    \"cfg\": {
      \"Provider\": \"openidConnect\",
      \"ClientID\": \"$CLIENT_ID\",
      \"ClientSecret\": \"$CLIENT_SECRET\",
      \"OpenIDConnectAutoDiscoveryURL\": \"$AUTHENTIK_URL/application/o/forgejo/.well-known/openid-configuration\",
      \"Scopes\": [\"openid\", \"profile\", \"email\"],
      \"SkipLocalTwoFA\": true
    }
  }" > /dev/null 2>&1 && echo "  OAuth2 source created (legacy API)" || {
    echo "  ERROR: Could not create OAuth2 source via API."
    echo "  Please create it manually in Forgejo admin panel:"
    echo "    1. Go to $FORGEJO_URL/-/admin/auths/new"
    echo "    2. Auth Type: OAuth2"
    echo "    3. Name: Authentik"
    echo "    4. OAuth2 Provider: OpenID Connect"
    echo "    5. Client ID: $CLIENT_ID"
    echo "    6. Client Secret: $CLIENT_SECRET"
    echo "    7. Discovery URL: $AUTHENTIK_URL/application/o/forgejo/.well-known/openid-configuration"
    echo "    8. Scopes: openid profile email"
  }
}

echo ""
echo "=== Step 7: Create 'tasks' repository in Forgejo ==="
REPO_RESP=$(fg_api "$FORGEJO_URL/api/v1/user/repos" -d '{
  "name": "tasks",
  "description": "Task queue for OpenClaw AI agent. Create an issue to submit a task.",
  "private": false,
  "auto_init": true,
  "default_branch": "main"
}' 2>/dev/null) && echo "  Repository created" || {
  echo "  Repository may already exist (OK)"
  REPO_RESP=$(fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_ADMIN_USER/tasks")
}
echo "  Repo: $FORGEJO_URL/$FORGEJO_ADMIN_USER/tasks"

echo ""
echo "=== Step 8: Disable non-issue features on tasks repo ==="
fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_ADMIN_USER/tasks" -X PATCH -d '{
  "has_pull_requests": false,
  "has_wiki": false,
  "has_projects": false,
  "has_releases": false,
  "has_packages": false,
  "has_actions": false
}' > /dev/null 2>&1 && echo "  Disabled PRs, wiki, projects, releases, packages, actions" || echo "  Some features may not be disableable (OK)"

echo ""
echo "=== Step 9: Create issue labels ==="
for label_data in \
  '{"name":"pending","color":"#0075ca","description":"Task waiting to be processed"}' \
  '{"name":"processing","color":"#e4e669","description":"Task currently being processed by OpenClaw"}' \
  '{"name":"completed","color":"#0e8a16","description":"Task completed successfully"}' \
  '{"name":"failed","color":"#d73a4a","description":"Task failed during processing"}'; do
  fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_ADMIN_USER/tasks/labels" -d "$label_data" > /dev/null 2>&1 || true
done
echo "  Labels created: pending, processing, completed, failed"

echo ""
echo "=== Step 10: Create webhook on tasks repo → n8n ==="
fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_ADMIN_USER/tasks/hooks" -d "{
  \"type\": \"gitea\",
  \"config\": {
    \"url\": \"$N8N_WEBHOOK_URL\",
    \"content_type\": \"json\",
    \"secret\": \"\"
  },
  \"events\": [\"issues\"],
  \"active\": true
}" > /dev/null 2>&1 && echo "  Webhook created → $N8N_WEBHOOK_URL" || echo "  Webhook may already exist (OK)"

echo ""
echo "=========================================="
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Add SOPS secrets:"
echo "     forgejo_authentik_client_id = \"$CLIENT_ID\""
echo "     forgejo_authentik_client_secret = \"$CLIENT_SECRET\""
echo "  2. Run: scripts/tg apply -target=module.forgejo"
echo "  3. Create n8n workflow (webhook trigger → OpenClaw exec → Forgejo comment)"
echo "  4. Add more users to 'Task Submitters' group in Authentik"
echo "  5. Test: Create an issue at $FORGEJO_URL/$FORGEJO_ADMIN_USER/tasks/issues/new"
echo "=========================================="
