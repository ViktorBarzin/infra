# Setup Shared Remote Executor

Skill for setting up Claude Code's shared remote executor in new projects.

## When to Use
- When adding Claude Code support to a new project
- When the user says "set up remote executor for this project"
- When working on a new project that needs remote command execution

## Prerequisites
- Shared executor already deployed at `~/.claude/` on wizard@10.0.10.10
- Project accessible via NFS from both macOS and the remote VM

## Setup Steps

### 1. Create .claude Directory
```bash
mkdir -p .claude/sessions
```

### 2. Create session-exec.sh Wrapper
Create `.claude/session-exec.sh` with the following content (adjust PROJECT_ROOT):

```bash
#!/bin/bash
# Project-Local Session Helper - Wrapper for shared executor

set -euo pipefail

SHARED_SESSION_EXEC="/home/wizard/.claude/session-exec.sh"
PROJECT_ROOT="/home/wizard/path/to/project"  # UPDATE THIS

if [ -f "$SHARED_SESSION_EXEC" ]; then
    if [ "${1:-}" = "create" ] || [ -z "${1:-}" ]; then
        "$SHARED_SESSION_EXEC" create "$PROJECT_ROOT"
    else
        "$SHARED_SESSION_EXEC" "$@"
    fi
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SESSIONS_DIR="$SCRIPT_DIR/sessions"
    SESSION_ID="${1:-$(date +%s)-$$-$RANDOM}"
    ACTION="${2:-create}"
    SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

    case "$ACTION" in
        create|init|"")
            mkdir -p "$SESSION_DIR"
            echo "ready" > "$SESSION_DIR/cmd_status.txt"
            echo "$PROJECT_ROOT" > "$SESSION_DIR/workdir.txt"
            > "$SESSION_DIR/cmd_input.txt"
            > "$SESSION_DIR/cmd_output.txt"
            echo "$SESSION_ID"
            ;;
        cleanup|remove|delete)
            [ -d "$SESSION_DIR" ] && rm -rf "$SESSION_DIR"
            ;;
        status)
            [ -d "$SESSION_DIR" ] && cat "$SESSION_DIR/cmd_status.txt"
            ;;
        list)
            [ -d "$SESSIONS_DIR" ] && ls -1 "$SESSIONS_DIR" 2>/dev/null
            ;;
    esac
fi
```

Make executable: `chmod +x .claude/session-exec.sh`

### 3. Link Sessions Directory (on remote VM)
Run on the remote VM to add project sessions to the shared executor:

```bash
# Option A: Symlink project sessions (if using project-local sessions)
ln -sfn /path/to/project/.claude/sessions ~/.claude/sessions

# Option B: Use shared sessions (all projects share one directory)
# Just ensure ~/.claude/sessions exists
```

### 4. Create CLAUDE.md
Add execution instructions to `.claude/CLAUDE.md`:

```markdown
## Remote Command Execution
Uses shared executor at `~/.claude/` on wizard@10.0.10.10.

### Usage
\```bash
SESSION_ID=$(.claude/session-exec.sh)
echo "command" > .claude/sessions/$SESSION_ID/cmd_input.txt
sleep 1 && cat .claude/sessions/$SESSION_ID/cmd_status.txt
cat .claude/sessions/$SESSION_ID/cmd_output.txt
\```

Start executor: `~/.claude/remote-executor.sh` (on remote VM)
```

## Shared Executor Location
- Scripts: `~/.claude/remote-executor.sh`, `~/.claude/session-exec.sh`
- Sessions: `~/.claude/sessions/`
- Remote VM: wizard@10.0.10.10
