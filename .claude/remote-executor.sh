#!/bin/bash
# Remote Command Executor
# Run this in a terminal with SSH access to the remote machine
#
# Usage: ./remote-executor.sh [user@host] [remote_workdir]
# Example: ./remote-executor.sh wizard@10.0.10.10 /home/wizard/code/infra

REMOTE_HOST="${1:-wizard@10.0.10.10}"
REMOTE_WORKDIR="${2:-/home/wizard/code/infra}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_FILE="$SCRIPT_DIR/cmd_input.txt"
OUTPUT_FILE="$SCRIPT_DIR/cmd_output.txt"
STATUS_FILE="$SCRIPT_DIR/cmd_status.txt"

# Initialize files
echo "ready" > "$STATUS_FILE"
> "$CMD_FILE"
> "$OUTPUT_FILE"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Remote Command Executor Started                  ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║ Remote: $REMOTE_HOST"
echo "║ Workdir: $REMOTE_WORKDIR"
echo "║ Watching: $CMD_FILE"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Waiting for commands..."

# Watch for new commands
while true; do
    # Check if there's a command to execute
    if [ -s "$CMD_FILE" ]; then
        CMD=$(cat "$CMD_FILE")

        # Clear the command file immediately
        > "$CMD_FILE"

        # Update status
        echo "running" > "$STATUS_FILE"
        echo "[$(date '+%H:%M:%S')] Executing: $CMD"

        # Execute on remote and capture output
        ssh "$REMOTE_HOST" "cd $REMOTE_WORKDIR && $CMD" > "$OUTPUT_FILE" 2>&1
        EXIT_CODE=$?

        # Append exit code to output
        echo "" >> "$OUTPUT_FILE"
        echo "---EXIT_CODE:$EXIT_CODE---" >> "$OUTPUT_FILE"

        # Update status
        echo "done:$EXIT_CODE" > "$STATUS_FILE"
        echo "[$(date '+%H:%M:%S')] Done (exit: $EXIT_CODE)"
    fi

    sleep 0.2
done
