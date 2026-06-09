#!/usr/bin/env bash
set -euo pipefail

# Authentik Invitation Management Script
# Usage:
#   ./authentik-invite.sh create "Group Name"            # Single-use, no expiry
#   ./authentik-invite.sh create "Group Name" --days 7   # Expires in 7 days
#   ./authentik-invite.sh assign <username> "Group Name" # Add user to group
#   ./authentik-invite.sh list                           # Show pending invitations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

API="https://authentik.viktorbarzin.me/api/v3"
FLOW_SLUG="invitation-enrollment"

get_token() {
    grep authentik_api_token "$INFRA_DIR/terraform.tfvars" | cut -d'"' -f2
}

api_get() {
    curl -sf -H "Authorization: Bearer $(get_token)" "$API/$1"
}

api_post() {
    curl -sf -X POST \
        -H "Authorization: Bearer $(get_token)" \
        -H "Content-Type: application/json" \
        "$API/$1" -d "$2"
}

api_patch() {
    curl -sf -X PATCH \
        -H "Authorization: Bearer $(get_token)" \
        -H "Content-Type: application/json" \
        "$API/$1" -d "$2"
}

cmd_create() {
    local group_name="${1:?Usage: create <group-name> [--days N]}"
    local days=""

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) days="$2"; shift 2 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Build invitation payload
    # Get flow PK
    local flow_pk
    flow_pk=$(api_get "flows/instances/$FLOW_SLUG/" | python3 -c "import json,sys; print(json.load(sys.stdin)['pk'])")

    local payload
    payload=$(python3 -c "
import json, sys, re
from datetime import datetime, timedelta, timezone

slug = re.sub(r'[^a-z0-9-]', '-', '$group_name'.lower()).strip('-')
data = {
    'name': 'invite-' + slug + '-' + datetime.now(timezone.utc).strftime('%Y%m%d-%H%M'),
    'single_use': True,
    'fixed_data': {'group': '$group_name'},
    'flow': '$flow_pk'
}

days = '$days'
if days:
    expires = datetime.now(timezone.utc) + timedelta(days=int(days))
    data['expires'] = expires.isoformat()

print(json.dumps(data))
")

    local result
    result=$(api_post "stages/invitation/invitations/" "$payload")
    local token
    token=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['pk'])")

    echo ""
    echo "Invitation created for group: $group_name"
    if [[ -n "$days" ]]; then
        echo "Expires in: $days days"
    else
        echo "Expires: never"
    fi
    echo "Single-use: yes"
    echo ""
    echo "Share this link:"
    echo "  https://authentik.viktorbarzin.me/if/flow/$FLOW_SLUG/?itoken=$token"
    echo ""
}

cmd_assign() {
    local username="${1:?Usage: assign <username> <group-name>}"
    local group_name="${2:?Usage: assign <username> <group-name>}"

    # Find user PK
    local user_pk
    user_pk=$(api_get "core/users/?search=$username" | python3 -c "
import json, sys
users = json.load(sys.stdin)['results']
if not users:
    print('NOT_FOUND', file=sys.stderr)
    sys.exit(1)
print(users[0]['pk'])
")

    # Find group PK and current users
    local group_data
    group_data=$(api_get "core/groups/?search=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$group_name'))")" | python3 -c "
import json, sys
groups = json.load(sys.stdin)['results']
matches = [g for g in groups if g['name'] == '$group_name']
if not matches:
    print('NOT_FOUND', file=sys.stderr)
    sys.exit(1)
g = matches[0]
users = g.get('users', [])
print(json.dumps({'pk': g['pk'], 'users': users}))
")

    local group_pk
    group_pk=$(echo "$group_data" | python3 -c "import json,sys; print(json.load(sys.stdin)['pk'])")

    # Add user to group
    local updated_users
    updated_users=$(echo "$group_data" | python3 -c "
import json, sys
d = json.load(sys.stdin)
users = d['users']
uid = $user_pk
if uid not in users:
    users.append(uid)
print(json.dumps(users))
")

    api_patch "core/groups/$group_pk/" "{\"users\": $updated_users}" > /dev/null

    echo "Added $username (pk=$user_pk) to group '$group_name'"
}

cmd_list() {
    api_get "stages/invitation/invitations/?page_size=50" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data['results']:
    print('No pending invitations.')
    sys.exit(0)

print(f\"{'Token (itoken)':<40} {'Name':<50} {'Single-Use':<12} {'Expires':<25} {'Group'}\")
print('-' * 160)
for inv in data['results']:
    token = inv['pk']
    name = inv.get('name', '')
    single = 'yes' if inv.get('single_use') else 'no'
    expires = inv.get('expires') or 'never'
    if expires != 'never':
        expires = expires[:19]
    group = inv.get('fixed_data', {}).get('group', '—')
    print(f'{token:<40} {name:<50} {single:<12} {expires:<25} {group}')
print(f\"\\nTotal: {data['pagination']['count']}\")
"
}

case "${1:-help}" in
    create) shift; cmd_create "$@" ;;
    assign) shift; cmd_assign "$@" ;;
    list)   cmd_list ;;
    *)
        echo "Authentik Invitation Manager"
        echo ""
        echo "Usage:"
        echo "  $0 create <group-name> [--days N]   Create single-use invite link"
        echo "  $0 assign <username> <group-name>   Add user to group"
        echo "  $0 list                             Show pending invitations"
        ;;
esac
