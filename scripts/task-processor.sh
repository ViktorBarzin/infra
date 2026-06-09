#!/usr/bin/env bash
#
# Task processor for the Forgejo → OpenClaw pipeline.
# Polls Forgejo for new issues in the tasks repo, sends them to OpenClaw
# for processing, and posts results back as comments.
#
# Runs inside the OpenClaw pod via kubectl exec from a CronJob.
#
# Environment:
#   FORGEJO_TOKEN   — Forgejo API token with repo access
#   FORGEJO_URL     — Forgejo base URL (default: https://forgejo.viktorbarzin.me)
#   FORGEJO_REPO    — Repo in format "owner/repo" (default: vbarzin/tasks)
#   OPENCLAW_URL    — OpenClaw gateway URL (default: http://127.0.0.1:18789)
#   OPENCLAW_TOKEN  — OpenClaw gateway token
#   SLACK_WEBHOOK_URL — Optional Slack webhook for notifications

set -euo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://forgejo.viktorbarzin.me}"
FORGEJO_REPO="${FORGEJO_REPO:-viktor/tasks}"
OPENCLAW_URL="${OPENCLAW_URL:-https://integrate.api.nvidia.com}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

: "${FORGEJO_TOKEN:?FORGEJO_TOKEN is required}"
: "${OPENCLAW_TOKEN:?OPENCLAW_TOKEN is required}"
FORGEJO_BOT_USER="${FORGEJO_BOT_USER:-viktor}"

fg_api() {
  curl -sf -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" "$@"
}

get_label_id() {
  local label_name="$1"
  fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/labels?limit=50" | \
    python3 -c "
import sys, json
labels = json.load(sys.stdin)
name = sys.argv[1]
for l in labels:
    if l['name'] == name:
        print(l['id'])
        break
else:
    print(0)
" "$label_name"
}

add_label() {
  local issue_id="$1" label_name="$2"
  local label_id
  label_id=$(get_label_id "$label_name")
  if [ "$label_id" != "0" ]; then
    fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues/$issue_id/labels" \
      -d "{\"labels\":[$label_id]}" > /dev/null 2>&1 || true
  fi
}

remove_label() {
  local issue_id="$1" label_name="$2"
  local label_id
  label_id=$(get_label_id "$label_name")
  if [ "$label_id" != "0" ]; then
    fg_api -X DELETE "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues/$issue_id/labels/$label_id" > /dev/null 2>&1 || true
  fi
}

post_comment() {
  local issue_id="$1"
  # Read comment body from stdin to avoid quoting issues
  python3 -c "
import sys, json
body = sys.stdin.read()
print(json.dumps({'body': body}))
" | fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues/$issue_id/comments" -d @- > /dev/null 2>&1
}

close_issue() {
  local issue_id="$1"
  fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues/$issue_id" \
    -X PATCH -d '{"state": "closed"}' > /dev/null 2>&1
}

get_comment_history() {
  local issue_id="$1"
  fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues/$issue_id/comments?limit=20" 2>/dev/null | \
    python3 -c "
import sys, json
bot_user = sys.argv[1]
comments = json.load(sys.stdin)
history = []
for c in comments:
    user = c.get('user', {}).get('login', 'unknown')
    body = c.get('body', '')
    # Skip bot's own comments to keep context clean
    if user == bot_user:
        # Include a short summary of previous responses
        if '## OpenClaw Task Result' in body:
            # Extract just the result content (skip header/footer)
            lines = body.split('\n')
            content = [l for l in lines if not l.startswith('## ') and not l.startswith('---') and not l.startswith('*Processed')]
            summary = '\n'.join(content).strip()[:500]
            if summary:
                history.append(f'[Previous AI response]: {summary}')
    else:
        history.append(f'[{user}]: {body}')
print('\n\n'.join(history))
" "$FORGEJO_BOT_USER" 2>/dev/null
}

notify_slack() {
  if [ -n "$SLACK_WEBHOOK_URL" ]; then
    python3 -c "
import json, sys
print(json.dumps({'text': sys.argv[1]}))
" "$1" | curl -sf -X POST "$SLACK_WEBHOOK_URL" \
      -H "Content-Type: application/json" -d @- > /dev/null 2>&1 || true
  fi
}

process_issue() {
  local issue_id="$1" title="$2" body="$3" author="$4"

  echo "Processing issue #$issue_id: $title (by $author)"

  # Mark as processing
  add_label "$issue_id" "processing"
  remove_label "$issue_id" "pending"
  remove_label "$issue_id" "completed"

  # Fetch comment history for context
  local comment_history
  comment_history=$(get_comment_history "$issue_id")

  # Call OpenClaw gateway API (OpenAI-compatible chat completions)
  # Use python to safely build the JSON payload
  local response
  response=$(python3 -c "
import json, sys
title = sys.argv[1]
body = sys.argv[2]
author = sys.argv[3]
comment_history = sys.argv[4]

prompt = f'''You are processing a task submitted by {author} via the Forgejo task queue.

Task title: {title}

Task description:
{body}'''

if comment_history.strip():
    prompt += f'''

Conversation history (follow-up comments):
{comment_history}

The latest comment is the most recent request. Address it in context of the original task and prior conversation.'''

prompt += '''

Please execute this task. When done, provide a clear summary of what was done and any results.
If the task requires infrastructure changes, describe what changes would be needed but do NOT apply them automatically — list the commands/changes for review.'''

payload = {
    'model': 'mistralai/mistral-large-3-675b-instruct-2512',
    'messages': [
        {'role': 'system', 'content': 'You are an infrastructure AI assistant. Process the task and provide actionable results. Be concise.'},
        {'role': 'user', 'content': prompt}
    ],
    'max_tokens': 8192,
    'temperature': 0.3
}
print(json.dumps(payload))
" "$title" "$body" "$author" "$comment_history" | \
    curl -sf --max-time 300 \
      -H "Authorization: Bearer $OPENCLAW_TOKEN" \
      -H "Content-Type: application/json" \
      "$OPENCLAW_URL/v1/chat/completions" \
      -d @- 2>&1) || {
    echo "  ERROR: OpenClaw API call failed"
    echo "Failed to process this task. OpenClaw API returned an error. Please check the CronJob logs or process manually." | \
      post_comment "$issue_id"
    add_label "$issue_id" "failed"
    remove_label "$issue_id" "processing"
    notify_slack ":x: Task #$issue_id failed: $title"
    return 1
  }

  # Extract the response content and post as comment
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data['choices'][0]['message']
    # Some models put content in reasoning_content instead of content
    result = msg.get('content') or msg.get('reasoning_content') or msg.get('reasoning') or 'No response generated.'
except Exception as e:
    result = f'Error parsing OpenClaw response: {e}'

body = f'## OpenClaw Task Result\n\n{result}\n\n---\n*Processed automatically by the OpenClaw task pipeline.*'
print(body)
" <<< "$response" | post_comment "$issue_id"

  # Update labels and close
  add_label "$issue_id" "completed"
  remove_label "$issue_id" "processing"
  close_issue "$issue_id"

  echo "  Issue #$issue_id processed and closed"
  notify_slack ":white_check_mark: Task #$issue_id completed: $title"
}

# --- Main ---

echo "=== Task Processor $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# List open issues
ISSUES=$(fg_api "$FORGEJO_URL/api/v1/repos/$FORGEJO_REPO/issues?state=open&type=issues&limit=10&sort=created&direction=asc" 2>/dev/null) || {
  echo "ERROR: Could not fetch issues from Forgejo"
  exit 1
}

# Parse pending issues into a temp file (avoids delimiter issues)
PENDING_FILE=$(mktemp)
trap 'rm -f "$PENDING_FILE"' EXIT

python3 -c "
import sys, json
issues = json.load(sys.stdin)
for issue in issues:
    labels = [l['name'] for l in issue.get('labels', [])]
    # Process if: no processing label AND (no completed label OR issue was reopened)
    if 'processing' not in labels:
        # Write each issue as a JSON line
        print(json.dumps({
            'id': issue['number'],
            'title': issue['title'],
            'body': (issue.get('body') or '')[:4000],
            'author': issue['user']['login']
        }))
" <<< "$ISSUES" > "$PENDING_FILE"

ISSUE_COUNT=$(wc -l < "$PENDING_FILE" | tr -d ' ')

if [ "$ISSUE_COUNT" = "0" ]; then
  echo "No pending issues to process"
  exit 0
fi

echo "Found $ISSUE_COUNT pending issue(s)"

# Process each pending issue (one JSON object per line)
while IFS= read -r line; do
  issue_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$line")
  title=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['title'])" "$line")
  body=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['body'])" "$line")
  author=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['author'])" "$line")
  process_issue "$issue_id" "$title" "$body" "$author" || true
done < "$PENDING_FILE"

echo "=== Task processing complete ==="
