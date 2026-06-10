#!/usr/bin/env bash
# Persist workstation tmux sessions across devvm reboots.
#
#   save    — snapshot every roster user's live tmux sessions to
#             /var/lib/t3-tmux-state/<user>.tsv (name, cwd, claude session
#             uuid). The uuid is sniffed from the claude process's OPEN
#             transcript fd (~/.claude/projects/<slug>/<uuid>.jsonl), so it is
#             correct regardless of how the session was launched (fresh via
#             start-claude.sh or an explicit --resume). Runs every 5 min via
#             t3-tmux-save.timer. A user with no tmux server keeps their last
#             manifest (so a post-reboot save can't wipe it before restore).
#   restore — recreate manifest sessions that don't currently exist, resuming
#             each saved conversation (claude --resume <uuid>). Per-session
#             idempotent: existing names are left alone, so it is safe both at
#             boot (t3-tmux-restore.service) and after a partial loss.
#
# v1 limitation: one window/pane per session is captured (the workstation
# usage pattern — one named claude conversation per tmux session).
set -euo pipefail

STATE_DIR=/var/lib/t3-tmux-state
MAP=/etc/ttyd-user-map
MODE="${1:-}"

log() { echo "[t3-tmux-sessions] $*"; }

users() { [[ -r "$MAP" ]] && cut -d= -f2 "$MAP" | sort -u; }

tmux_as() { local u="$1"; shift; runuser -u "$u" -- tmux "$@"; }

# First descendant of $1 whose comm is `claude` (BFS, bounded by process tree).
claude_pid_under() {
  local q=("$1") pid kids
  while ((${#q[@]})); do
    pid="${q[0]}"; q=("${q[@]:1}")
    [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == claude ]] && { echo "$pid"; return 0; }
    read -ra kids <<<"$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')" || true
    ((${#kids[@]})) && q+=("${kids[@]}")
  done
  return 1
}

# Conversation uuid of a claude process ($1 pid, $2 user, $3 cwd). Two sources
# (claude does NOT hold its transcript fd open, so fd-sniffing doesn't work):
#  1. argv `--resume <uuid>` — covers every session this script's restore (or a
#     manual recovery) created, making the save/restore loop self-sustaining;
#  2. newest <uuid>.jsonl in the user's cwd-slug project dir created at/after
#     the process start — covers fresh launcher-started sessions.
# Always returns 0; empty output means "no conversation" (restored as a shell).
uuid_of_claude() {
  local uuid slug dir start f
  uuid="$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null \
          | grep -A1 -x -- '--resume' | tail -1 \
          | grep -oE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)"
  [[ -n "$uuid" ]] && { echo "$uuid"; return 0; }
  slug="${3//\//-}"; slug="${slug//./-}"
  dir="$(getent passwd "$2" | cut -d: -f6)/.claude/projects/$slug"
  [[ -d "$dir" ]] || return 0
  start=$(( $(date +%s) - $(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ' || echo 0) - 5 ))
  f="$(find "$dir" -maxdepth 1 -name '*.jsonl' -newermt "@$start" -printf '%T@ %f\n' 2>/dev/null \
       | sort -rn | head -1 | awk '{print $2}' || true)"
  [[ -n "$f" ]] && echo "${f%.jsonl}"
  return 0
}

save() {
  install -d -m 0755 "$STATE_DIR"
  local u uid sess pane_pid pane_cwd cpid uuid tmp
  for u in $(users); do
    uid="$(id -u "$u" 2>/dev/null)" || continue
    [[ -S "/tmp/tmux-$uid/default" ]] || continue   # no server -> keep last manifest
    tmp="$(mktemp)"
    while IFS=$'\t' read -r sess pane_pid pane_cwd; do
      [[ -n "$sess" ]] || continue
      uuid=""
      if cpid="$(claude_pid_under "$pane_pid")"; then uuid="$(uuid_of_claude "$cpid" "$u" "$pane_cwd")"; fi
      printf '%s\t%s\t%s\n' "$sess" "$pane_cwd" "$uuid" >> "$tmp"
    done < <(tmux_as "$u" list-panes -a -F $'#{session_name}\t#{pane_pid}\t#{pane_current_path}' 2>/dev/null \
             | sort -u -t$'\t' -k1,1)
    install -m 0600 "$tmp" "$STATE_DIR/$u.tsv"; rm -f "$tmp"
    log "saved $(wc -l < "$STATE_DIR/$u.tsv") session(s) for $u"
  done
}

restore() {
  local u f sess cwd uuid cmd
  for u in $(users); do
    f="$STATE_DIR/$u.tsv"
    [[ -s "$f" ]] || continue
    while IFS=$'\t' read -r sess cwd uuid; do
      [[ -n "$sess" ]] || continue
      tmux_as "$u" has-session -t "=$sess" 2>/dev/null && continue   # already live
      [[ -d "$cwd" ]] || cwd="$(getent passwd "$u" | cut -d: -f6)"
      if [[ -n "$uuid" ]]; then
        cmd="claude --dangerously-skip-permissions --resume $uuid --name \"$sess\"; echo; echo '  claude exited — shell preserved'; exec bash -l"
      else
        cmd="exec bash -l"
      fi
      tmux_as "$u" new-session -d -s "$sess" -c "$cwd" "$cmd" \
        && log "restored $u:$sess${uuid:+ (resume ${uuid:0:8})}" \
        || log "WARN: failed to restore $u:$sess"
    done < "$f"
  done
}

case "$MODE" in
  save) save ;;
  restore) restore ;;
  *) echo "usage: t3-tmux-sessions save|restore" >&2; exit 1 ;;
esac
