#!/usr/bin/env bash
# Persist WEB-TERMINAL (ttyd/tmux) sessions across devvm reboots and crashes.
#
# Scope: the tmux-based web terminal only. The t3 chat surface persists its
# own threads (~/.t3 state.sqlite, backed up daily by t3-backup-state) — this
# script is about the tmux sessions, which are otherwise memory-only. Users
# come from /etc/ttyd-user-map (the terminal surface's roster-derived map).
#
# SNAPSHOTS (2026-08-14) — the store is a short SERIES, not a single file.
# Every save compares the live set against the newest snapshot and writes
# snapshots/<user>/<YYYYMMDDTHHMMSS>.tsv only when it CHANGED, keeping the
# newest SNAPSHOT_KEEP. <user>.tsv is a symlink to the newest snapshot, so the
# boot path and the manifest can never disagree.
#
# This exists because the previous single manifest was rewritten in place on
# every 5-minute tick: a PARTIAL loss (tmux server alive, the processes inside
# individual sessions killed) whose save landed mid-kill dropped the already-
# dead sessions, and one Restore click could only bring back whatever happened
# to still be listed. Older snapshots keep the pre-loss set reachable.
#
#   save        — snapshot the live set when it differs from the newest one.
#                 The uuid comes from the session's @claude_transcript stamp, or
#                 failing that from the claude process's argv — the
#                 `--session-id` a fresh start-claude.sh launch pins, or the
#                 `--resume` a restore carries (see uuid_of_claude for the full
#                 order and the fallbacks a bare `claude` needs). One
#                 conversation is recorded against at most ONE session per
#                 capture; see capture_live for why that matters.
#                 Runs every 5 min via
#                 tmux-persist-save.timer. A capture with no live sessions
#                 (no server, OR a stale socket left behind by an OOM-killed
#                 server) writes nothing, so it can't wipe history before
#                 restore needs it.
#   restore     — recreate sessions from the NEWEST snapshot that aren't
#                 currently live, resuming each saved conversation. Per-session
#                 idempotent; skips names tombstoned after that snapshot.
#   snapshots   — list a user's snapshots (ts, session count) for the picker.
#   snapshot    — resolve ONE snapshot against what's live now: per row, what
#                 restoring it would do and whether it should start ticked.
#   restore-selection <user> <ts> <name>... — restore chosen rows of one
#                 snapshot. Backs the lobby picker.
#   restore-one <user> <name|uuid> — recreate ONE session found in any
#                 snapshot, newest first.
#   history     — list a user's session history, derived by merging snapshots.
#   forget      — tombstone a deliberate kill so a restore doesn't undo it.
#
# v1 limitation: one window/pane per session is captured (the workstation
# usage pattern — one named claude conversation per tmux session).
set -euo pipefail

# Paths and knobs are overridable so the test harness can drive the real script
# against a throwaway state dir. Production never sets these.
STATE_DIR="${TMUX_PERSIST_STATE_DIR:-/var/lib/tmux-persist}"
MAP="${TMUX_PERSIST_MAP:-/etc/ttyd-user-map}"
SNAPSHOT_KEEP="${TMUX_PERSIST_SNAPSHOT_KEEP:-200}"
CLAUDE_BIN="${TMUX_PERSIST_CLAUDE_BIN:-claude}"
TEST_SOCKET="${TMUX_PERSIST_TEST_SOCKET:-}"
# Stands in for every user's home, so a test can own the projects tree that
# transcript resolution reads instead of the real ~/.claude of whoever runs it.
HOME_ROOT="${TMUX_PERSIST_HOME_ROOT:-}"
MODE="${1:-}"

log() { echo "[tmux-persist] $*"; }

# <authentik_user>=<os_user>[:<cwd>], plus comment lines. Comments used to fall
# through as bogus "users" (harmless while every consumer re-checked `id -u`,
# but they now reach path-building code), so they are filtered here instead.
users() {
  [[ -r "$MAP" ]] || return 0
  sed -e 's/#.*//' "$MAP" | cut -d= -f2- | sed -e 's/:.*//' -e 's/[[:space:]]//g' \
    | grep -xE '[a-z_][a-z0-9_-]{0,31}' | sort -u
}

# Production runuser's into the target user (the manifests are root-owned 0600).
# Under test we are not root, so tmux runs directly on a private -L socket.
tmux_as() {
  local u="$1"; shift
  if [[ -n "$TEST_SOCKET" ]]; then tmux -L "$TEST_SOCKET" "$@"
  else runuser -u "$u" -- tmux "$@"; fi
}

now_epoch() { echo "${TMUX_PERSIST_NOW:-$(date +%s)}"; }
epoch_to_ts() { date -u -d "@$1" +%Y%m%dT%H%M%S; }
# YYYYMMDDTHHMMSS -> epoch
ts_to_epoch() { date -u -d "${1:0:8} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; }

user_socket() {
  local uid="$1"
  if [[ -n "$TEST_SOCKET" ]]; then echo "/tmp/tmux-$uid/$TEST_SOCKET"
  else echo "/tmp/tmux-$uid/default"; fi
}

snapshots_dir() { echo "$STATE_DIR/snapshots/$1"; }
pointer_path()  { echo "$STATE_DIR/$1.tsv"; }
tombstones_path() { echo "$STATE_DIR/$1.forgotten.tsv"; }

# Snapshot filenames are timestamps, so a lexical sort is a chronological one.
snapshot_files() { ls -1 "$(snapshots_dir "$1")"/*.tsv 2>/dev/null | sort || true; }
newest_snapshot() { snapshot_files "$1" | tail -1; }
snapshot_path() { echo "$(snapshots_dir "$1")/$2.tsv"; }

home_of() { [[ -n "$HOME_ROOT" ]] && { printf '%s\n' "$HOME_ROOT"; return 0; }; getent passwd "$1" | cut -d: -f6; }

# First descendant of $1 whose comm is `claude` (BFS, bounded by process tree).
#
# Touches ONLY the pane's own subtree, with no subprocesses at all.
#
# It used to call `ps -o comm= -p PID` and `pgrep -P PID` at each node. Both
# read the ENTIRE process table even when asked about a single pid — measured
# on the devvm 2026-08-16: 45 ms and 63 ms per call, one `ps` issuing 2,759
# openat against 679 processes. That was ~2.2 s of the restore picker's ~2.9 s
# open time, and it grew with how busy the box was rather than with the work.
#
# Children come from `/proc/<pid>/task/<tid>/children` (CONFIG_PROC_CHILDREN),
# unioned over the process's threads because each task lists only the children
# IT forked. Deliberately NOT a prebuilt ppid map: callers invoke this inside a
# command substitution, so a subshell-local cache would be rebuilt for every
# row — a full /proc scan per pane, ~4,700 entries a time, which is how the
# first cut of this rewrite still spent ~1 s here.
#
# Note the `2>/dev/null` sits BEFORE each input redirect: redirections apply
# left to right, and a process exiting mid-walk makes the OPEN fail, which the
# shell would otherwise report on the stderr in force at that point.
claude_pid_under() {
  local q=("$1") pid comm t kids kid
  while ((${#q[@]})); do
    pid="${q[0]}"; q=("${q[@]:1}")
    read -r comm 2>/dev/null < "/proc/$pid/comm" || continue
    [[ "$comm" == claude ]] && { echo "$pid"; return 0; }
    for t in /proc/"$pid"/task/*/children; do
      # `children` is space-separated with NO trailing newline, so `read` hits
      # EOF and returns non-zero even though it filled the variable — the
      # status has to be ignored rather than treated as "no children", or the
      # walk never descends at all. (/proc/<pid>/comm above does end in \n.)
      kids=
      read -r kids 2>/dev/null < "$t" || true
      for kid in $kids; do q+=("$kid"); done
    done
  done
  return 1
}

# Conversation uuid of a claude process ($1 pid, $2 user, $3 cwd, $4 tmux session
# name [optional], $5 the session's @claude_transcript stamp [optional]).
#
# Prints "<certainty>\t<uuid>", lowest certainty = most sure. The caller needs the
# certainty because a conversation belongs to exactly ONE session: when two rows
# want the same uuid, the row that KNOWS keeps it and the row that guessed gives
# it up (see capture_live). Use uuid_only when the uuid alone is wanted.
#
# Sources, in order (claude does NOT hold its transcript fd open, so fd-sniffing
# doesn't work):
#  0. the @claude_transcript STAMP, left on the tmux session by Claude Code's own
#     SessionStart hook. Per-session and exact, and it beats argv because it names
#     the conversation claude is writing to NOW: after a /clear, argv still names
#     the id the process was launched with, a transcript claude has abandoned.
#     Sessions started before the stamp existed carry none, so the guesses below
#     stay — the stamp is the fast path out of them, not a replacement.
#  1. an EXPLICIT id in argv — `--session-id <uuid>` (fresh launcher sessions since
#     2026-07-26) or `--resume <uuid>` (this script's own restores + manual recovery).
#     Authoritative and per-process, so it can't confuse concurrent sessions.
#  2. FALLBACK for a claude started without an explicit id: among transcripts touched
#     since this process started, prefer the one whose OWN recorded name (its first
#     custom-title / agent-name, written from --name at creation) matches the tmux
#     session — this disambiguates concurrent sessions that share one cwd-slug dir.
#  3. LAST RESORT: newest <uuid>.jsonl by mtime in the cwd-slug dir. This alone
#     mis-attributes concurrent same-cwd sessions (it returns whichever conversation
#     is most active for EVERY pane) — the bug that source 1 exists to avoid; kept
#     only so a nameless one-off session still restores something. Being the least
#     certain answer, it is also the first one capture_live drops on a collision.
# Always returns 0; empty output means "no conversation" (restored as a shell).
uuid_of_claude() {
  local uuid slug dir start f sess="${4:-}" stamp="${5:-}" p t root
  root="$(home_of "$2")/.claude/projects"
  # 0. the stamp. Written by the session's own user, so it is untrusted input:
  #    only an existing <uuid>.jsonl inside that user's own projects root is
  #    accepted, and a path with a `..` component is refused rather than
  #    normalised — there is nothing legitimate above the root to reach for.
  if [[ -n "$stamp" && "$stamp" != *"/../"* && "$stamp" != */.. \
        && "$stamp" == "$root"/*/*.jsonl && -f "$stamp" ]]; then
    f="${stamp##*/}"; f="${f%.jsonl}"
    if [[ "$f" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
      printf '0\t%s\n' "$f"; return 0
    fi
  fi
  uuid="$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null \
          | grep -A1 -xE -- '--session-id|--resume' | tail -1 \
          | grep -oE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)"
  [[ -n "$uuid" ]] && { printf '1\t%s\n' "$uuid"; return 0; }
  slug="${3//\//-}"; slug="${slug//./-}"
  dir="$root/$slug"
  [[ -d "$dir" ]] || return 0
  start=$(( $(date +%s) - $(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ' || echo 0) - 5 ))
  # 2. name-aware: newest transcript (touched since start) whose own name == $sess.
  if [[ -n "$sess" ]]; then
    while read -r _ p; do
      t="$(grep -m1 -oE '"(customTitle|agentName)":"[^"]*"' "$p" 2>/dev/null \
           | head -1 | sed -E 's/.*:"(.*)"$/\1/')"
      [[ "$t" == "$sess" ]] && { f="${p##*/}"; printf '2\t%s\n' "${f%.jsonl}"; return 0; }
    done < <(find "$dir" -maxdepth 1 -name '*.jsonl' -newermt "@$start" -printf '%T@ %p\n' 2>/dev/null | sort -rn)
  fi
  # 3. last resort: newest by mtime.
  f="$(find "$dir" -maxdepth 1 -name '*.jsonl' -newermt "@$start" -printf '%T@ %f\n' 2>/dev/null \
       | sort -rn | head -1 | awk '{print $2}' || true)"
  [[ -n "$f" ]] && printf '3\t%s\n' "${f%.jsonl}"
  return 0
}

# uuid_of_claude without the certainty column, for callers that only need to know
# WHICH conversation. Pure parameter expansion: resolve_row calls this per row of
# the restore picker, and that path is kept fork-free (test_no_fork_hot_paths).
uuid_only() { local a; a="$(uuid_of_claude "$@")"; printf '%s\n' "${a#*$'\t'}"; }

# --- save ---------------------------------------------------------------------

# A conversation belongs to exactly ONE session, so this resolves every pane
# first and only then decides who keeps what.
#
# Without that second pass, two sessions sharing a cwd both fall through to
# "newest .jsonl by mtime in the slug dir" and are saved carrying the SAME uuid.
# Restoring those rows then resumes one conversation several times over, and
# since each live name already holds a different one, the picker suffixes them —
# so the restore both loses the conversations asked for and adds duplicate
# sessions to the list (emo, 2026-08-21: five sessions in /home/emo collapsed
# onto whichever transcript had been touched last, a different one each tick).
#
# Rows are emitted in session-name order, the order they arrive in: a snapshot is
# only written when it DIFFERS from the newest one, so a reordering would read as
# a change on every tick.
capture_live() {   # $1 user -> TSV rows on stdout
  local u="$1" sess pane_pid pane_cwd stamp cpid answer uuid
  local -a rows=() order=()
  local -A cwd_of=() owner=() saved=()
  # Pass 1: ask every pane which conversation it is running, and how sure it is.
  while IFS=$'\t' read -r sess pane_pid pane_cwd stamp; do
    [[ -n "$sess" ]] || continue
    answer=""
    if cpid="$(claude_pid_under "$pane_pid")"; then
      answer="$(uuid_of_claude "$cpid" "$u" "$pane_cwd" "$sess" "$stamp")"
    fi
    order+=("$sess"); cwd_of["$sess"]="$pane_cwd"
    # "<certainty>\t<uuid>\t<session>"; certainty 9 is "no answer at all", which
    # sorts last. The uuid is `-` rather than empty on purpose: TAB is IFS
    # WHITESPACE, so `read` collapses a run of them and an empty middle field
    # would shift every column after it (the same trap the history rows hit).
    rows+=("${answer:-9$'\t'-}"$'\t'"$sess")
  done < <(tmux_as "$u" list-panes -a \
             -F $'#{session_name}\t#{pane_pid}\t#{pane_current_path}\t#{@claude_transcript}' 2>/dev/null \
           | sort -u -t$'\t' -k1,1)

  # Pass 2: most-certain rows choose first, so a session that KNOWS its
  # conversation keeps it and a session that merely guessed the same one is saved
  # with none — which restores as a plain shell, not as somebody else's history.
  while IFS=$'\t' read -r _ uuid sess; do
    [[ -n "$sess" && "$uuid" != "-" ]] || continue
    [[ -n "${owner[$uuid]:-}" ]] && continue
    owner["$uuid"]="$sess"; saved["$sess"]="$uuid"
  done < <( ((${#rows[@]})) && printf '%s\n' "${rows[@]}" | sort -s -t$'\t' -k1,1n )

  for sess in "${order[@]}"; do
    printf '%s\t%s\t%s\n' "$sess" "${cwd_of[$sess]}" "${saved[$sess]:--}"
  done
}

prune_snapshots() {
  local u="$1" total excess
  total="$(snapshot_files "$u" | wc -l)"
  (( total > SNAPSHOT_KEEP )) || return 0
  excess=$(( total - SNAPSHOT_KEEP ))
  # Oldest first; the newest is never in this slice, so the pointer stays valid.
  snapshot_files "$u" | head -n "$excess" | while read -r f; do rm -f "$f"; done
  log "pruned $excess old snapshot(s) for $u (keeping $SNAPSHOT_KEEP)"
}

# Cutover from the pre-snapshot layout: the old <user>.tsv was a regular file
# holding the last live set. Seed it as the first snapshot so restore keeps
# working in the window before the first post-deploy save, instead of finding
# an empty series.
migrate_manifest() {
  local u="$1" p dir ts
  p="$(pointer_path "$u")"
  [[ -f "$p" && ! -L "$p" && -s "$p" ]] || return 0
  [[ -z "$(snapshot_files "$u")" ]] || return 0
  dir="$(snapshots_dir "$u")"; install -d -m 0700 "$dir"
  ts="$(epoch_to_ts "$(stat -c %Y "$p")")"
  # The old format left the uuid field empty for "no conversation"; snapshots
  # write "-" so consecutive tabs can't collapse on read.
  awk -F'\t' -v OFS='\t' 'NF{print $1, $2, ($3!=""?$3:"-")}' "$p" > "$dir/$ts.tsv"
  chmod 0600 "$dir/$ts.tsv"
  ln -sfn "snapshots/$u/$ts.tsv" "$p"
  log "migrated $u's manifest into snapshot $ts"
}

save() {
  install -d -m 0755 "$STATE_DIR"
  local u uid tmp n ts dir newest
  for u in $(users); do
    migrate_manifest "$u"
    uid="$(id -u "$u" 2>/dev/null)" || continue
    [[ -S "$(user_socket "$uid")" ]] || continue   # no socket at all -> keep history
    tmp="$(mktemp)"
    capture_live "$u" > "$tmp"
    # A socket file can outlive its server (an OOM-killed tmux server leaves one
    # behind); list-panes then yields nothing. Writing that empty result would
    # add a bogus "everything died" snapshot and move the pointer onto it.
    n=$(wc -l < "$tmp")
    if (( n == 0 )); then
      log "no live sessions for $u (stale socket or dead server) — keeping last snapshot"
      rm -f "$tmp"; continue
    fi
    dir="$(snapshots_dir "$u")"; install -d -m 0700 "$dir"
    newest="$(newest_snapshot "$u")"
    if [[ -n "$newest" ]] && cmp -s "$tmp" "$newest"; then
      rm -f "$tmp"; continue      # unchanged — 90% of ticks; keeps the list readable
    fi
    ts="$(epoch_to_ts "$(now_epoch)")"
    install -m 0600 "$tmp" "$dir/$ts.tsv"
    rm -f "$tmp"
    ln -sfn "snapshots/$u/$ts.tsv" "$(pointer_path "$u")"
    prune_snapshots "$u"
    log "saved $n session(s) for $u (snapshot $ts)"
  done
}

# --- tombstones ---------------------------------------------------------------
# Snapshots are immutable, so a deliberate kill can no longer be expressed by
# dropping a row from the manifest (what tmux-persist-forget used to do). A
# tombstone records it instead: restore skips the name, and the picker offers
# the row unchecked so an accidental kill is still one click from coming back.

forget() {
  local u="$1" sess="$2" f
  users | grep -qxF "$u" || { echo "[tmux-persist] forget: '$u' is not a known terminal user" >&2; return 2; }
  [[ "$sess" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { echo "[tmux-persist] forget: invalid session name" >&2; return 2; }
  f="$(tombstones_path "$u")"
  printf '%s\t%s\n' "$sess" "$(now_epoch)" >> "$f"
  chmod 0600 "$f"
  log "forgot $u:$sess"
}

# Most recent kill time for a session name, or empty.
killed_at() {
  local u="$1" sess="$2" f
  f="$(tombstones_path "$u")"
  [[ -s "$f" ]] || return 0
  awk -F'\t' -v s="$sess" '$1""==s"" {t=$2+0} END {if (t) print t}' "$f"
}

# --- resolving a snapshot against what is live now ----------------------------

# `<base>-<HHMM>` for a conflicting name, kept inside tmux-api's sessionNameRe
# (^[a-zA-Z0-9_-]{1,32}$) by trimming the base rather than the suffix.
suffixed_name() {
  local base="$1" ts="$2" suffix="-${2:9:4}" max
  max=$(( 32 - ${#suffix} ))
  (( ${#base} > max )) && base="${base:0:max}"
  printf '%s%s' "$base" "$suffix"
}

# Per live session: name, pane_pid, pane_current_command, @claude_transcript.
# Cached per invocation. The stamp rides along in the same format string so
# resolve_row can identify a live conversation exactly — comparing a GUESSED live
# uuid against the snapshot is what made a session whose conversation had not
# changed read as `live_other_conv`, and get restored beside itself under a
# suffixed name.
declare -A LIVE_CMD LIVE_PID LIVE_STAMP
load_live() {
  local u="$1" sess pid cmd stamp
  LIVE_CMD=(); LIVE_PID=(); LIVE_STAMP=()
  while IFS=$'\t' read -r sess pid cmd stamp; do
    [[ -n "$sess" ]] || continue
    LIVE_CMD["$sess"]="$cmd"; LIVE_PID["$sess"]="$pid"; LIVE_STAMP["$sess"]="$stamp"
  done < <(tmux_as "$u" list-panes -a \
             -F $'#{session_name}\t#{pane_pid}\t#{pane_current_command}\t#{@claude_transcript}' 2>/dev/null \
           | sort -u -t$'\t' -k1,1)
}

is_shell() { case "$1" in bash|zsh|sh|fish|dash|ksh) return 0 ;; *) return 1 ;; esac; }

# Resolve one row -> state, action, target, default, note (tab-separated).
# Rules mirror the design's decision tree:
#   not live                     -> new        (off if tombstoned after this snapshot)
#   live, same conversation      -> skip
#   live, different conversation -> suffixed
#   live, no claude, shell pane  -> in_place
resolve_row() {
  local u="$1" ts="$2" sess="$3" cwd="$4" uuid="$5"
  local state action target def note live_uuid cpid k snap_epoch
  note="-"; def="on"; target="$sess"
  [[ "$uuid" == "-" ]] && uuid=""

  if [[ -z "${LIVE_PID[$sess]+x}" ]]; then
    state="missing"; action="new"
    k="$(killed_at "$u" "$sess")"
    if [[ -n "$k" ]]; then
      snap_epoch="$(ts_to_epoch "$ts")"
      # Only a kill AFTER this snapshot expresses "I closed this"; an older kill
      # was already undone by the session being captured again.
      if (( k > snap_epoch )); then def="off"; note="killed@$k"; fi
    fi
  else
    live_uuid=""
    if cpid="$(claude_pid_under "${LIVE_PID[$sess]}")"; then
      live_uuid="$(uuid_only "$cpid" "$u" "$cwd" "$sess" "${LIVE_STAMP[$sess]:-}")"
    fi
    if [[ -n "$live_uuid" && "$live_uuid" == "$uuid" ]]; then
      state="live_same"; action="skip"; def="off"
    elif [[ -n "$live_uuid" ]]; then
      state="live_other_conv"; action="suffixed"; target="$(suffixed_name "$sess" "$ts")"
    elif [[ -z "$uuid" ]]; then
      # Nothing to resume and the name is taken — there is no work to do.
      state="live_same"; action="skip"; def="off"
    elif is_shell "${LIVE_CMD[$sess]}"; then
      state="live_no_claude"; action="in_place"
    else
      state="live_other_conv"; action="suffixed"; target="$(suffixed_name "$sess" "$ts")"
    fi
  fi
  # Every field stays non-empty ("-" when absent): tab is IFS-whitespace, so
  # bash `read` COLLAPSES consecutive tabs and an empty field would shift every
  # column after it.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sess" "${cwd:--}" "${uuid:--}" "$state" "$action" "$target" "$def" "$note"
}

snapshot_view() {
  local u="$1" ts="$2" f sess cwd uuid
  users | grep -qxF "$u" || { echo "[tmux-persist] snapshot: '$u' is not a known terminal user" >&2; return 2; }
  migrate_manifest "$u"
  f="$(snapshot_path "$u" "$ts")"
  [[ -s "$f" ]] || { echo "[tmux-persist] no snapshot '$ts' for $u" >&2; return 1; }
  load_live "$u"
  while IFS=$'\t' read -r sess cwd uuid; do
    [[ -n "$sess" ]] || continue
    resolve_row "$u" "$ts" "$sess" "$cwd" "$uuid"
  done < "$f"
}

# ts <TAB> session-count <TAB> is-newest, newest first.
#
# Fork-free per row: this runs over every snapshot a user has ever had (94 for
# wizard, 200 for emo on 2026-08-16, and the series only grows), and the old
# `basename` + `grep -c` + `$(...)` trio cost three processes each — ~0.6 s of
# the restore picker's open time. Parameter expansion and a builtin read do the
# same work for nothing.
snapshots_list() {
  local u="$1" f ts n newest mark line
  users | grep -qxF "$u" || { echo "[tmux-persist] snapshots: '$u' is not a known terminal user" >&2; return 2; }
  migrate_manifest "$u"
  newest="$(newest_snapshot "$u")"
  while read -r f; do
    [[ -n "$f" ]] || continue
    ts="${f##*/}"; ts="${ts%.tsv}"
    # Count non-empty lines, matching what `grep -c .` reported. The trailing
    # `|| [[ -n "$line" ]]` keeps a final line with no newline counted.
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && n=$((n + 1))
    done < "$f"
    if [[ "$f" == "$newest" ]]; then mark=newest; else mark=-; fi
    printf '%s\t%s\t%s\n' "$ts" "$n" "$mark"
  done < <(snapshot_files "$u" | sort -r)
}

# --- restore ------------------------------------------------------------------

# Wait until this pane is inside its own systemd scope before forking anything.
#
# tmux asks systemd to move a new pane into `tmux-spawn-<uuid>.scope` and then
# execs without waiting for that move to land. A pane command that forks
# straight away (ours does — `claude …; exec bash -l` is compound, so the shell
# forks claude) can therefore leave claude behind in the tmux SERVER's cgroup,
# where the per-pane MemoryMax from setup-devvm.sh §10a-bis does not reach it.
# Measured 2026-08-16: 1 in 6 fresh panes, and 2 of 8 live claudes, had escaped
# that way; with this wait, 0 of 8.
#
# POSIX sh (tmux runs the pane command through /bin/sh), reads the cgroup with a
# redirect rather than `grep` so the check itself does not fork, and gives up
# after ~2s so a host without scope support just carries on uncapped.
CGROUP_SETTLE='i=0; while [ $i -lt 40 ]; do read -r _cg < /proc/self/cgroup 2>/dev/null; case ${_cg:-} in *tmux-spawn-*) break ;; esac; i=$((i+1)); sleep 0.05; done; '

restore_cmd() {   # $1 sess, $2 uuid ("" -> plain shell)
  if [[ -n "$2" ]]; then
    printf '%s%s --dangerously-skip-permissions --resume %s --name "%s"; echo; echo "  claude exited — shell preserved"; exec bash -l' \
      "$CGROUP_SETTLE" "$CLAUDE_BIN" "$2" "$1"
  else
    printf 'exec bash -l'
  fi
}

spawn_session() {   # $1 user, $2 target name, $3 cwd, $4 uuid
  local u="$1" target="$2" cwd="$3" uuid="$4"
  [[ -d "$cwd" ]] || cwd="$(home_of "$u")"
  tmux_as "$u" new-session -d -s "$target" -c "$cwd" "$(restore_cmd "$target" "$uuid")"
}

# Type the resume into a live session whose claude died but whose shell survived.
#
# The target is `=<sess>:`, not `=<sess>`. send-keys takes a PANE target, and
# tmux rejects a bare `=name` there ("can't find pane") even though it accepts
# it for a session or window — the trailing `:` makes it a session-qualified
# pane target, which resolves to that session's active pane while keeping `=`
# exact (a plain `<sess>` would prefix-match a longer name).
resume_in_place() {   # $1 user, $2 sess, $3 uuid
  tmux_as "$1" send-keys -t "=$2:" \
    "$CLAUDE_BIN --dangerously-skip-permissions --resume $3 --name \"$2\"" C-m
}

apply_row() {   # a resolved row on stdin args: user + the 8 fields
  local u="$1" sess="$2" cwd="$3" uuid="$4" action="$6" target="$7"
  [[ "$uuid" == "-" ]] && uuid=""
  case "$action" in
    new|suffixed)
      spawn_session "$u" "$target" "$cwd" "$uuid" \
        && log "restored $u:$target${uuid:+ (resume ${uuid:0:8})}" \
        || { log "WARN: failed to restore $u:$target"; return 1; } ;;
    in_place)
      resume_in_place "$u" "$sess" "$uuid" \
        && log "resumed $u:$sess in place (${uuid:0:8})" \
        || { log "WARN: failed to resume $u:$sess in place"; return 1; } ;;
    skip) log "$u:$sess already live" ;;
  esac
}

# Blanket restore from the NEWEST snapshot — the boot service and the plain
# button. Rows the picker would leave unticked are skipped here too.
restore() {
  local only="${1:-}" u f ts row
  if [[ -n "$only" ]] && ! users | grep -qxF "$only"; then
    echo "[tmux-persist] restore: '$only' is not a known terminal user" >&2
    return 2
  fi
  for u in $(users); do
    [[ -z "$only" || "$u" == "$only" ]] || continue
    migrate_manifest "$u"
    f="$(newest_snapshot "$u")"
    [[ -n "$f" && -s "$f" ]] || continue
    ts="${f##*/}"; ts="${ts%.tsv}"
    while IFS=$'\t' read -r -a row; do
      [[ -n "${row[0]:-}" ]] || continue
      [[ "${row[6]}" == "on" ]] || continue      # live, or a deliberate kill
      apply_row "$u" "${row[@]}" || true
    done < <(snapshot_view "$u" "$ts")
  done
}

# Restore CHOSEN rows of ONE snapshot — what the lobby picker posts.
restore_selection() {
  local u="$1" ts="$2"; shift 2
  local wanted=("$@") view name found row
  users | grep -qxF "$u" || { echo "[tmux-persist] restore-selection: '$u' is not a known terminal user" >&2; return 2; }
  (( ${#wanted[@]} )) || { echo "[tmux-persist] restore-selection: no sessions given" >&2; return 2; }
  view="$(snapshot_view "$u" "$ts")" || return 1
  # Refuse the whole request if any name is not in that snapshot, rather than
  # half-restoring and leaving the caller to work out which half.
  for name in "${wanted[@]}"; do
    if ! printf '%s\n' "$view" | awk -F'\t' -v n="$name" '$1""==n""{f=1} END{exit !f}'; then
      echo "[tmux-persist] restore-selection: '$name' is not in snapshot $ts" >&2
      return 1
    fi
  done
  for name in "${wanted[@]}"; do
    found="$(printf '%s\n' "$view" | awk -F'\t' -v n="$name" '$1""==n""{print; exit}')"
    IFS=$'\t' read -r -a row <<<"$found"
    apply_row "$u" "${row[@]}" || true
  done
}

# --- history ------------------------------------------------------------------
# Derived by merging the snapshot series: every snapshot a session appears in
# contributes its timestamp, so first/last-seen fall out of the file names.
# Keyed by uuid (fallback name), newest first.

history_rows() {   # $1 user -> name, cwd, uuid, first_seen, last_seen
  local u="$1" f ts epoch
  while read -r f; do
    [[ -n "$f" ]] || continue
    ts="${f##*/}"; ts="${ts%.tsv}"; epoch="$(ts_to_epoch "$ts")"
    awk -F'\t' -v OFS='\t' -v e="$epoch" 'NF{print $1, $2, ($3!=""?$3:"-"), e}' "$f"
  done < <(snapshot_files "$u") \
  | awk -F'\t' -v OFS='\t' '
      { k=($3!="-"?$3:$1)
        nm[k]=$1; cd[k]=$2; uu[k]=$3
        if (!(k in fs) || $4+0 < fs[k]) fs[k]=$4+0
        if (!(k in ls) || $4+0 > ls[k]) ls[k]=$4+0 }
      END { for (k in nm) print nm[k], cd[k], uu[k], fs[k], ls[k] }' \
  | sort -t$'\t' -k5,5nr
}

history_list() {
  local only="${1:-}" u now nm cd uu fs ls state ago
  now="$(now_epoch)"
  for u in $(users); do
    [[ -z "$only" || "$u" == "$only" ]] || continue
    migrate_manifest "$u"
    if [[ -z "$(snapshot_files "$u")" ]]; then echo "[$u] no session history yet"; continue; fi
    echo "== $u — session history (newest first) =="
    printf '  %-22s %-32s %-10s %-8s %s\n' NAME CWD RESUME LAST STATE
    while IFS=$'\t' read -r nm cd uu fs ls; do
      [[ -n "$nm" ]] || continue
      state=dead
      if tmux_as "$u" has-session -t "=$nm" 2>/dev/null; then state=ALIVE; fi
      ago=$(( (now - ls) / 60 ))
      printf '  %-22s %-32s %-10s %5dm   %s\n' "$nm" "${cd:0:32}" "${uu:0:8}" "$ago" "$state"
    done < <(history_rows "$u")
  done
}

# Recreate ONE session found in any snapshot, newest first. The selector matches
# a session name or a uuid (full or prefix).
#
# `$1""==s""` is load-bearing: awk compares two numeric-looking strings as
# NUMBERS, so a bare `$1==s` matched session "007" when asked for "7", and "1e2"
# when asked for "100". Passing the name via -v stops injection but not this.
restore_one() {
  local u="$1" sel="$2" f line sess cwd uuid ts
  users | grep -qxF "$u" || { echo "[tmux-persist] restore-one: '$u' is not a known terminal user" >&2; return 2; }
  migrate_manifest "$u"
  while read -r f; do
    [[ -n "$f" ]] || continue
    line="$(awk -F'\t' -v s="$sel" '
      $1""==s"" || $3""==s"" || ($3!="-" && $3!="" && index($3, s)==1) {print; exit}' "$f")"
    [[ -n "$line" ]] && { ts="${f##*/}"; ts="${ts%.tsv}"; break; }
  done < <(snapshot_files "$u" | sort -r)
  [[ -n "$line" ]] || { echo "[tmux-persist] no session matching '$sel' for $u" >&2; return 1; }
  IFS=$'\t' read -r sess cwd uuid <<<"$line"
  [[ "$uuid" == "-" ]] && uuid=""
  if tmux_as "$u" has-session -t "=$sess" 2>/dev/null; then log "$u:$sess already live"; return 0; fi
  spawn_session "$u" "$sess" "$cwd" "$uuid" \
    && log "restored $u:$sess${uuid:+ (resume ${uuid:0:8})} (from $ts)" \
    || { log "WARN: failed to restore $u:$sess"; return 1; }
}

usage() {
  cat >&2 <<'EOF'
usage: tmux-persist save
       tmux-persist restore [user]
       tmux-persist snapshots <user>
       tmux-persist snapshot <user> <ts>
       tmux-persist restore-selection <user> <ts> <name>...
       tmux-persist restore-one <user> <name|uuid>
       tmux-persist history [user]
       tmux-persist forget <user> <session>
EOF
  exit 1
}

case "$MODE" in
  save)     save ;;
  restore)  restore "${2:-}" ;;
  snapshots) snapshots_list "${2:?usage: snapshots <user>}" ;;
  snapshot) snapshot_view "${2:?usage: snapshot <user> <ts>}" "${3:?usage: snapshot <user> <ts>}" ;;
  restore-selection)
            u="${2:?usage: restore-selection <user> <ts> <name>...}"
            ts="${3:?usage: restore-selection <user> <ts> <name>...}"
            shift 3; restore_selection "$u" "$ts" "$@" ;;
  restore-one) restore_one "${2:?usage: restore-one <user> <name|uuid>}" "${3:?usage: restore-one <user> <name|uuid>}" ;;
  history)  history_list "${2:-}" ;;
  forget)   forget "${2:?usage: forget <user> <session>}" "${3:?usage: forget <user> <session>}" ;;
  *)        usage ;;
esac
