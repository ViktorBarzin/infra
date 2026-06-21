#!/bin/bash
# PreCompact hook: Save key memories before compaction
set -e

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // "unknown"')

MEMORY_HOME="${MEMORY_HOME:-$HOME/.claude/claude-memory}"
MARKER_DIR="${MEMORY_HOME}/state/compaction-markers"
MEMORY_DB="${MEMORY_HOME}/memory/memory.db"
MARKER_FILE="${MARKER_DIR}/${SESSION_ID}.json"

mkdir -p "$MARKER_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Try API first, fall back to SQLite
REMEMBERED_FACTS="[]"
if [ -n "${MEMORY_API_KEY:-${CLAUDE_MEMORY_API_KEY:-}}" ]; then
    API_KEY="${MEMORY_API_KEY:-${CLAUDE_MEMORY_API_KEY:-}}"
    API_URL="${MEMORY_API_URL:-${CLAUDE_MEMORY_API_URL:-}}"
    if [ -n "$API_URL" ]; then
        REMEMBERED_FACTS=$(curl -sf -H "Authorization: Bearer ${API_KEY}" \
            "${API_URL}/api/memories?limit=20" 2>/dev/null | \
            jq '[.memories[] | {content, category, importance}]' 2>/dev/null || echo "[]")
    fi
elif [ -f "$MEMORY_DB" ]; then
    REMEMBERED_FACTS=$(sqlite3 -json "$MEMORY_DB" \
        "SELECT content, category, importance FROM memories ORDER BY importance DESC, created_at DESC LIMIT 20" 2>/dev/null || echo "[]")
fi

if ! echo "$REMEMBERED_FACTS" | jq empty 2>/dev/null; then
    REMEMBERED_FACTS="[]"
fi

jq -n \
  --arg sid "$SESSION_ID" \
  --arg ts "$TIMESTAMP" \
  --argjson facts "$REMEMBERED_FACTS" \
  '{sessionId: $sid, compactedAt: $ts, rememberedFacts: $facts}' \
  > "$MARKER_FILE"

exit 0
