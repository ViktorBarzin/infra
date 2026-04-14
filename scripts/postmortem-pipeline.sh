#!/bin/sh
# postmortem-pipeline.sh — Woodpecker pipeline step for post-mortem TODO automation
# Called from .woodpecker/postmortem-todos.yml
set -e

# 1. Find which post-mortem changed
# Woodpecker shallow clones (depth 1) so HEAD~1 may not exist. Fetch more history.
git fetch --deepen=2 origin master 2>/dev/null || true
PM_FILE=$(git diff HEAD~1 --name-only 2>/dev/null | grep 'docs/post-mortems/.*[.]md' | head -1)
if [ -z "$PM_FILE" ]; then
  # Fallback: check all post-mortems for TODO items
  for f in docs/post-mortems/*.md; do
    if grep -q '| TODO |' "$f" 2>/dev/null; then
      PM_FILE="$f"
      echo "Fallback: found TODOs in $f"
      break
    fi
  done
fi
if [ -z "$PM_FILE" ]; then
  echo "No post-mortem with TODOs found"
  exit 0
fi
echo "Post-mortem: $PM_FILE"

# 2. Check if there are TODO items to process
if ! grep -q '| TODO |' "$PM_FILE"; then
  echo "No TODOs in $PM_FILE — skipping"
  exit 0
fi

# 3. Parse TODOs
bash scripts/parse-postmortem-todos.sh "$PM_FILE" > /tmp/todos.json
cat /tmp/todos.json
TODO_COUNT=$(jq '.safe_todos' /tmp/todos.json)
echo "$TODO_COUNT safe TODO(s) found"
if [ "$TODO_COUNT" -eq 0 ]; then
  echo "No auto-implementable TODOs — skipping"
  exit 0
fi

# 4. Authenticate to Vault via K8s SA JWT
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
VAULT_RESP=$(curl -sf -X POST http://vault-active.vault.svc.cluster.local:8200/v1/auth/kubernetes/login \
  -d "{\"role\":\"ci\",\"jwt\":\"$SA_TOKEN\"}")
VAULT_TOKEN=$(echo "$VAULT_RESP" | jq -r .auth.client_token)
if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
  echo "ERROR: Vault authentication failed"
  exit 1
fi
echo "Vault authenticated"

# 5. Fetch DevVM SSH key from Vault
curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
  http://vault-active.vault.svc.cluster.local:8200/v1/secret/data/ci/infra | \
  jq -r '.data.data.devvm_ssh_key' > /tmp/devvm-key
chmod 600 /tmp/devvm-key
if [ ! -s /tmp/devvm-key ]; then
  echo "ERROR: Failed to fetch DevVM SSH key"
  exit 1
fi
echo "SSH key fetched"

# 6. SSH to DevVM and run Claude Code headless
TODOS=$(cat /tmp/todos.json)
ssh -i /tmp/devvm-key -o StrictHostKeyChecking=no wizard@10.0.10.10 \
  "cd ~/code/infra && git pull && claude -p \
    --agent postmortem-todo-resolver \
    --dangerously-skip-permissions \
    --max-budget-usd 5 \
    'Implement the auto-implementable TODOs from $PM_FILE. Parsed TODO list: $TODOS'"

# 7. Cleanup
rm -f /tmp/devvm-key
echo "Pipeline complete"
