#!/usr/bin/env bash
# openclaw-task — manage long-running tmux tasks on devvm
#
# Canonical source: infra/stacks/openclaw/files/openclaw-task.sh
# Installed to /usr/local/bin/openclaw-task on devvm so non-interactive
# SSH (e.g. `ssh devvm openclaw-task list`) finds it on the default PATH.
#
# Sessions are prefixed `openclaw-task-` to avoid colliding with the
# user's own tmux work. Persistent transcripts live in
# ~/openclaw-tasks/<id>.log via `tmux pipe-pane`. Sessions and logs
# survive OpenClaw pod restarts (they live on devvm, not in the pod).

set -euo pipefail

# Use full paths because non-interactive SSH does not source ~/.profile
# or ~/.bashrc (see memory id=740).
TMUX_BIN=/usr/bin/tmux
CLAUDE_BIN=/usr/local/bin/claude   # installed as symlink to /home/wizard/.local/bin/claude

PREFIX=openclaw-task-
TASK_DIR=${OPENCLAW_TASK_DIR:-$HOME/openclaw-tasks}
mkdir -p "$TASK_DIR"

die() { echo "openclaw-task: $*" >&2; exit 1; }

session_name() { printf 'openclaw-task-%s' "$1"; }

require_session() {
  local name="$1"
  "$TMUX_BIN" has-session -t "$name" 2>/dev/null || die "no session '$name' (use 'openclaw-task list')"
}

usage() {
  cat <<EOF
openclaw-task — manage long-running tmux tasks on devvm

USAGE
  openclaw-task new <id> <command...>      spawn detached tmux session
  openclaw-task claude <id> [prompt...]    spawn interactive claude in a session;
                                             if prompt given, send-keys it + Enter
  openclaw-task send <id> <keys...>        tmux send-keys passthrough (you must
                                             pass 'Enter' literal for newline)
  openclaw-task capture <id> [lines]       last <lines> of pane (default 1000)
  openclaw-task log <id>                   cat the persistent pipe-pane log
  openclaw-task tail <id>                  tail -f the persistent log
  openclaw-task list                       all openclaw task ids (one per line)
  openclaw-task status <id>                'running' or 'ended'
  openclaw-task kill <id>                  kill session (log file kept)
  openclaw-task purge <id>                 kill + delete log file

EXAMPLES
  openclaw-task new build-foo "cd ~/code/foo && make all 2>&1"
  openclaw-task claude diag-frigate
  openclaw-task send diag-frigate "investigate gpu crashloop" Enter
  openclaw-task capture diag-frigate 200
  openclaw-task list
EOF
}

cmd_new() {
  [ $# -lt 2 ] && die "usage: openclaw-task new <id> <command...>"
  local id="$1"; shift
  local name; name=$(session_name "$id")
  if "$TMUX_BIN" has-session -t "$name" 2>/dev/null; then
    die "session '$name' already exists"
  fi
  local log="$TASK_DIR/$id.log"
  : > "$log"
  # Start an idle interactive bash so pipe-pane can attach BEFORE the
  # user's command runs. If we passed the command directly to
  # new-session, its first lines beat pipe-pane to the pane and never
  # land in the log.
  "$TMUX_BIN" new-session -d -s "$name" bash --norc -i
  "$TMUX_BIN" pipe-pane -o -t "$name" "cat >> '$log'"
  sleep 0.2
  "$TMUX_BIN" send-keys -t "$name" "$*" Enter
  # Auto-exit propagating the command's status so the tmux session
  # ends when the command does.
  "$TMUX_BIN" send-keys -t "$name" 'exit $?' Enter
  printf 'session: %s\nlog: %s\n' "$name" "$log"
}

cmd_claude() {
  [ $# -lt 1 ] && die "usage: openclaw-task claude <id> [prompt...]"
  local id="$1"; shift
  local name; name=$(session_name "$id")
  if "$TMUX_BIN" has-session -t "$name" 2>/dev/null; then
    die "session '$name' already exists (use 'send' to add prompts)"
  fi
  local log="$TASK_DIR/$id.log"
  : > "$log"
  # sleep+exec lets pipe-pane attach before claude prints its banner.
  "$TMUX_BIN" new-session -d -s "$name" bash -c "sleep 0.3; exec '$CLAUDE_BIN'"
  "$TMUX_BIN" pipe-pane -o -t "$name" "cat >> '$log'"
  if [ $# -gt 0 ]; then
    # Wait for claude to come up before sending the prompt
    sleep 2
    "$TMUX_BIN" send-keys -t "$name" "$*" Enter
  fi
  printf 'session: %s\nlog: %s\n' "$name" "$log"
}

cmd_send() {
  [ $# -lt 2 ] && die "usage: openclaw-task send <id> <keys...>"
  local id="$1"; shift
  local name; name=$(session_name "$id")
  require_session "$name"
  "$TMUX_BIN" send-keys -t "$name" "$@"
}

cmd_capture() {
  [ $# -lt 1 ] && die "usage: openclaw-task capture <id> [lines]"
  local id="$1"
  local lines="${2:-1000}"
  local name; name=$(session_name "$id")
  require_session "$name"
  "$TMUX_BIN" capture-pane -t "$name" -p -S "-$lines"
}

cmd_log() {
  [ $# -lt 1 ] && die "usage: openclaw-task log <id>"
  local id="$1"
  local log="$TASK_DIR/$id.log"
  [ -f "$log" ] || die "no log file for '$id' (looked at $log)"
  cat "$log"
}

cmd_tail() {
  [ $# -lt 1 ] && die "usage: openclaw-task tail <id>"
  local id="$1"
  local log="$TASK_DIR/$id.log"
  [ -f "$log" ] || die "no log file for '$id' (looked at $log)"
  tail -n 100 -f "$log"
}

cmd_list() {
  "$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null \
    | grep "^$PREFIX" \
    | sed "s|^$PREFIX||" \
    || true
}

cmd_status() {
  [ $# -lt 1 ] && die "usage: openclaw-task status <id>"
  local id="$1"
  local name; name=$(session_name "$id")
  if "$TMUX_BIN" has-session -t "$name" 2>/dev/null; then
    echo running
  else
    echo ended
  fi
}

cmd_kill() {
  [ $# -lt 1 ] && die "usage: openclaw-task kill <id>"
  local id="$1"
  local name; name=$(session_name "$id")
  require_session "$name"
  "$TMUX_BIN" kill-session -t "$name"
}

cmd_purge() {
  [ $# -lt 1 ] && die "usage: openclaw-task purge <id>"
  local id="$1"
  local name; name=$(session_name "$id")
  "$TMUX_BIN" kill-session -t "$name" 2>/dev/null || true
  rm -f "$TASK_DIR/$id.log"
  echo "purged: $id"
}

case "${1:-help}" in
  new)     shift; cmd_new "$@" ;;
  claude)  shift; cmd_claude "$@" ;;
  send)    shift; cmd_send "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  log)     shift; cmd_log "$@" ;;
  tail)    shift; cmd_tail "$@" ;;
  list)    shift; cmd_list "$@" ;;
  status)  shift; cmd_status "$@" ;;
  kill)    shift; cmd_kill "$@" ;;
  purge)   shift; cmd_purge "$@" ;;
  help|-h|--help) usage ;;
  *)       usage; exit 2 ;;
esac
