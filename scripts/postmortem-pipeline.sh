#!/bin/sh
# postmortem-pipeline.sh — Woodpecker pipeline step for post-mortem TODO automation
# Called from .woodpecker/postmortem-todos.yml
set -e

# 1. Find post-mortem(s) with TODO items
# Scan all post-mortems — don't rely on git diff (Woodpecker shallow clone breaks HEAD~1)
PM_FILE=""
for f in docs/post-mortems/*.md; do
  if grep -q '| TODO |' "$f" 2>/dev/null; then
    PM_FILE="$f"
    break
  fi
done
if [ -z "$PM_FILE" ]; then
  echo "No post-mortem with pending TODOs found"
  exit 0
fi
echo "Post-mortem with TODOs: $PM_FILE"

# 3. Parse TODOs
sh scripts/parse-postmortem-todos.sh "$PM_FILE" > /tmp/todos.json
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

# 5. Fetch API token for claude-agent-service
AGENT_TOKEN=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
  http://vault-active.vault.svc.cluster.local:8200/v1/secret/data/claude-agent-service | \
  jq -r '.data.data.api_bearer_token')
if [ -z "$AGENT_TOKEN" ] || [ "$AGENT_TOKEN" = "null" ]; then
  echo "ERROR: Failed to fetch agent API token"
  exit 1
fi
echo "Agent token fetched"

# 6. Submit to claude-agent-service
TODOS=$(cat /tmp/todos.json)
PAYLOAD=$(jq -n \
  --arg prompt "Implement the auto-implementable TODOs from $PM_FILE. Parsed TODO list: $TODOS" \
  --arg agent ".claude/agents/postmortem-todo-resolver" \
  '{prompt: $prompt, agent: $agent, max_budget_usd: 5, timeout_seconds: 900}')

RESP=$(curl -sf -X POST \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  http://claude-agent-service.claude-agent.svc.cluster.local:8080/execute)
JOB_ID=$(echo "$RESP" | jq -r '.job_id')
echo "Job submitted: $JOB_ID"

# 7. Poll for completion (15min max)
for i in $(seq 1 60); do
  sleep 15
  RESULT=$(curl -sf \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    http://claude-agent-service.claude-agent.svc.cluster.local:8080/jobs/$JOB_ID)
  STATUS=$(echo "$RESULT" | jq -r '.status')
  echo "[$i/60] Status: $STATUS"
  if [ "$STATUS" != "running" ]; then
    echo "$RESULT" | jq .
    if [ "$STATUS" = "completed" ]; then exit 0; else exit 1; fi
  fi
done
echo "ERROR: Job timed out after 15 minutes"
exit 1
