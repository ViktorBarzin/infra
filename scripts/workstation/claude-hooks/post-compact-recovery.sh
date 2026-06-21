#!/bin/bash
# UserPromptSubmit hook: Inject recovery context after compaction
# This hook runs on each user prompt, but only injects context once after compaction.

# Read hook input from stdin
INPUT=$(cat)

# Extract session ID
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // "unknown"')

# Define marker path
MEMORY_HOME="${MEMORY_HOME:-$HOME/.claude/claude-memory}"
MARKER_DIR="${MEMORY_HOME}/state/compaction-markers"
MARKER_FILE="${MARKER_DIR}/${SESSION_ID}.json"

# Fast path: no marker means no recent compaction, exit immediately
if [ ! -f "$MARKER_FILE" ]; then
    exit 0
fi

# Read marker contents
MARKER=$(cat "$MARKER_FILE")

# Validate JSON before processing
if ! echo "$MARKER" | jq -e . >/dev/null 2>&1; then
    rm -f "$MARKER_FILE"
    exit 0
fi

# Extract data from marker
COMPACTED_AT=$(echo "$MARKER" | jq -r '.compactedAt // "unknown"')
PERSONALITY=$(echo "$MARKER" | jq -r '.personalityReminder // ""')

# Build remembered facts summary (limit to ~500 chars)
FACTS_SUMMARY=$(echo "$MARKER" | jq -r '
    .rememberedFacts[:10] |
    map("- [\(.category // "fact")] \(.content)") |
    join("\n")
' 2>/dev/null || echo "")

# Build recovery context (kept under 1000 tokens)
RECOVERY_CONTEXT="[Claude Memory Recovery - Context compacted at ${COMPACTED_AT}]

${PERSONALITY}

Key memories from before compaction:
${FACTS_SUMMARY}

Use the memory_recall MCP tool if you need more context about past conversations."

# Output JSON with additional context for injection
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $(echo "$RECOVERY_CONTEXT" | jq -Rs .)
  }
}
EOF

# Delete marker file (one-time injection)
rm -f "$MARKER_FILE"

exit 0
