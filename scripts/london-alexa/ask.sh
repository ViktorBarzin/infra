#!/usr/bin/env bash
# Runs the Alexa Skills Kit CLI in a container as Anca's Amazon developer
# account (the owner of the London Echo). Credentials: Login with Amazon refresh
# token in Vault secret/viktor ask_cli_refresh_token. Usage: ask.sh smapi <command> ...
# The current directory is mounted at /work, so file:/work/... arguments work.
set -euo pipefail

ASK_CLI_VERSION=2.30.7
export ASK_REFRESH_TOKEN="${ASK_REFRESH_TOKEN:-$(vault kv get -field=ask_cli_refresh_token secret/viktor)}"

export ASK_VENDOR_ID="${ASK_VENDOR_ID:-$(cat "$(dirname "$0")/skill/vendor-id" 2>/dev/null || true)}"

# The CLI reads credentials only from a named profile in its config file, so
# write a throwaway "default" profile from the environment inside the container.
# The expired access token makes it refresh on first use.
docker run --rm -e HOME=/tmp -e ASK_REFRESH_TOKEN -e ASK_VENDOR_ID \
  -v ask-npm-cache:/tmp/.npm -v "$PWD:/work" -w /work node:22-alpine \
  sh -c 'mkdir -p /tmp/.ask && node -e "
    const p = {token: {access_token: \"\", refresh_token: process.env.ASK_REFRESH_TOKEN, token_type: \"bearer\",
               expires_in: 3600, expires_at: \"2000-01-01T00:00:00.000Z\"}, vendor_id: process.env.ASK_VENDOR_ID || \"\"};
    require(\"fs\").writeFileSync(\"/tmp/.ask/cli_config\", JSON.stringify({profiles: {default: p}}));" \
    && exec npx -y --loglevel=error "ask-cli@$0" "$@"' \
  "$ASK_CLI_VERSION" "$@"
