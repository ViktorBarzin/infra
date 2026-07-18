#!/usr/bin/env bash
# Persist WEB-TERMINAL (ttyd/tmux) sessions across devvm reboots.
#
# Scope: the tmux-based web terminal only. The t3 chat surface persists its
# own threads (~/.t3 state.sqlite, backed up daily by t3-backup-state) — this
# script is about the tmux sessions, which are otherwise memory-only. Users
# come from /etc/ttyd-user-map (the terminal surface's roster-derived map).
#
#   save    — snapshot every roster user's live tmux sessions to
#             /var/lib/tmux-persist/<user>.tsv (name, cwd, claude session
#             uuid). The uuid is sniffed from the claude process's OPEN
#             transcript fd (~/.claude/projects/<slug>/<uuid>.jsonl), so it is
#             correct regardless of how the session was launched (fresh via
#             start-claude.sh or an explicit --resume). Runs every 5 min via
#             tmux-persist-save.timer. A snapshot that captures no live sessions
#             (no server, OR a stale socket left behind by an OOM-killed server)
#             keeps the user's last manifest, so it can't be wiped before restore.
#   restore — recreate manifest sessions that don't currently exist, resuming
#             each saved conversation (claude --resume <uuid>). Per-session
#             idempotent: existing names are left alone, so it is safe both at
#             boot (tmux-persist-restore.service) and after a partial loss.
#   history — list a user's session HISTORY (name, cwd, uuid, last-seen,
#             ALIVE/dead). Every save MERGES the live set into
#             /var/lib/tmux-persist/<user>.history.tsv and NEVER drops a dead
#             session, so past sessions stay pickable after they die (the
#             manifest only holds the live set, so it alone loses them).
#   restore-one <user> <name|uuid> — recreate ONE session from the history,
#             resuming its conversation. Backs a "pick which to restore" flow.
#
# v1 limitation: one window/pane per session is captured (the workstation
# usage pattern — one named claude conversation per tmux session).
set -euo pipefail

STATE_DIR=/var/lib/tmux-persist
MAP=/etc/ttyd-user-map
MODE="${1:-}"

log() { echo "[tmux-persist] $*"; }

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
  local u uid sess pane_pid pane_cwd cpid uuid tmp n
  for u in $(users); do
    uid="$(id -u "$u" 2>/dev/null)" || continue
    [[ -S "/tmp/tmux-$uid/default" ]] || continue   # no socket at all -> keep last manifest
    tmp="$(mktemp)"
    while IFS=$'\t' read -r sess pane_pid pane_cwd; do
      [[ -n "$sess" ]] || continue
      uuid=""
      if cpid="$(claude_pid_under "$pane_pid")"; then uuid="$(uuid_of_claude "$cpid" "$u" "$pane_cwd")"; fi
      printf '%s\t%s\t%s\n' "$sess" "$pane_cwd" "$uuid" >> "$tmp"
    done < <(tmux_as "$u" list-panes -a -F $'#{session_name}\t#{pane_pid}\t#{pane_current_path}' 2>/dev/null \
             | sort -u -t$'\t' -k1,1)
    # Only overwrite the manifest when we captured >=1 live session. A socket
    # file can outlive its server (an OOM-killed tmux server leaves
    # /tmp/tmux-<uid>/default behind); list-panes then yields nothing, and
    # installing that empty result would clobber a good manifest right before
    # restore needs it. Empty capture -> keep the last good manifest.
    n=$(wc -l < "$tmp")
    if (( n > 0 )); then
      install -m 0600 "$tmp" "$STATE_DIR/$u.tsv"
      merge_history "$u" "$tmp"
      log "saved $n session(s) for $u"
    else
      log "no live sessions for $u (stale socket or dead server) — keeping last manifest"
    fi
    rm -f "$tmp"
  done
}

restore() {
  local only="${1:-}" u f sess cwd uuid cmd
  # Optional single-user restore: `tmux-persist restore <user>` limits the
  # action to one terminal user (the web-UI restore button calls this via the
  # tmux-restore-user wrapper). No arg => restore every user (the boot service).
  if [[ -n "$only" ]] && ! users | grep -qxF "$only"; then
    echo "[tmux-persist] restore: '$only' is not a known terminal user" >&2
    return 2
  fi
  for u in $(users); do
    [[ -z "$only" || "$u" == "$only" ]] || continue
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

# --- session history ----------------------------------------------------------
# The manifest (<user>.tsv) only holds the CURRENTLY-live set (for boot
# auto-restore), so a save after a partial loss drops dead sessions from it. The
# history (<user>.history.tsv: name, cwd, uuid, first_seen, last_seen) is MERGED
# on every save and never loses a dead session, so past sessions stay pickable
# (`history` to list, `restore-one` to bring one back). Keyed by uuid (fallback
# name); retained 30 days / newest 60.
merge_history() {
  local u="$1" live="$2" hist tmp now
  hist="$STATE_DIR/$u.history.tsv"; now="$(date +%s)"; touch "$hist"
  tmp="$(mktemp)"
  # Use FILENAME (not FNR==NR) to tell the two files apart — FNR==NR mis-detects
  # when the history file is empty (first run), which would blank the timestamps.
  awk -F'\t' -v OFS='\t' -v now="$now" -v H="$hist" '
    FILENAME==H { k=($3!=""?$3:$1); nm[k]=$1; cd[k]=$2; uu[k]=$3; fs[k]=$4; ls[k]=$5; keys[k]=1; next }
    { k=($3!=""?$3:$1); nm[k]=$1; cd[k]=$2; uu[k]=$3; if (!(k in fs) || fs[k]=="") fs[k]=now; ls[k]=now; keys[k]=1 }
    END { for (k in keys) print nm[k], cd[k], (uu[k]!=""?uu[k]:"-"), fs[k], ls[k] }
  ' "$hist" "$live" \
    | sort -t$'\t' -k5,5nr \
    | awk -F'\t' -v cut="$(( now - 30*86400 ))" 'NR<=60 && $5+0>=cut' > "$tmp"
  install -m 0600 "$tmp" "$hist"; rm -f "$tmp"
}

history_list() {
  local only="${1:-}" u hist now nm cd uu fs ls state ago
  now="$(date +%s)"
  for u in $(users); do
    [[ -z "$only" || "$u" == "$only" ]] || continue
    hist="$STATE_DIR/$u.history.tsv"
    if [[ ! -s "$hist" ]]; then echo "[$u] no session history yet"; continue; fi
    echo "== $u — session history (newest first) =="
    printf '  %-22s %-32s %-10s %-8s %s\n' NAME CWD RESUME LAST STATE
    while IFS=$'\t' read -r nm cd uu fs ls; do
      [[ -n "$nm" ]] || continue
      state=dead
      if runuser -u "$u" -- tmux has-session -t "=$nm" 2>/dev/null; then state=ALIVE; fi
      ago=$(( (now - ls) / 60 ))
      printf '  %-22s %-32s %-10s %5dm   %s\n' "$nm" "${cd:0:32}" "${uu:0:8}" "$ago" "$state"
    done < <(sort -t$'\t' -k5,5nr "$hist")
  done
}

restore_one() {
  local u="$1" sel="$2" hist line sess cwd uuid cmd
  users | grep -qxF "$u" || { echo "[tmux-persist] restore-one: '$u' is not a known terminal user" >&2; return 2; }
  hist="$STATE_DIR/$u.history.tsv"
  [[ -s "$hist" ]] || { echo "[tmux-persist] no history for $u" >&2; return 1; }
  line="$(awk -F'\t' -v s="$sel" '$1==s || $3==s || ($3!="" && index($3,s)==1) {print; exit}' "$hist")"
  [[ -n "$line" ]] || { echo "[tmux-persist] no history entry matching '$sel' for $u" >&2; return 1; }
  IFS=$'\t' read -r sess cwd uuid _ _ <<<"$line"
  [[ "$uuid" == "-" ]] && uuid=""   # "-" is the history's "no conversation" placeholder
  if tmux_as "$u" has-session -t "=$sess" 2>/dev/null; then log "$u:$sess already live"; return 0; fi
  [[ -d "$cwd" ]] || cwd="$(getent passwd "$u" | cut -d: -f6)"
  if [[ -n "$uuid" ]]; then
    cmd="claude --dangerously-skip-permissions --resume $uuid --name \"$sess\"; echo; echo '  claude exited — shell preserved'; exec bash -l"
  else
    cmd="exec bash -l"
  fi
  tmux_as "$u" new-session -d -s "$sess" -c "$cwd" "$cmd" \
    && log "restored $u:$sess${uuid:+ (resume ${uuid:0:8})}" \
    || { log "WARN: failed to restore $u:$sess"; return 1; }
}

case "$MODE" in
  save) save ;;
  restore) restore "${2:-}" ;;
  history) history_list "${2:-}" ;;
  restore-one) restore_one "${2:?usage: restore-one <user> <name|uuid>}" "${3:?usage: restore-one <user> <name|uuid>}" ;;
  *) echo "usage: tmux-persist save | restore [user] | history [user] | restore-one <user> <name|uuid>" >&2; exit 1 ;;
esac
