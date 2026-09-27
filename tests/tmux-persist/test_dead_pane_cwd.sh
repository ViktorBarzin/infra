#!/usr/bin/env bash
# A dead pane still saves the folder it runs in (2026-09-27).
#
# terminal-lobby suspends an idle session by stopping its claude with
# remain-on-exit on, so the pane stays, dead. tmux reports an empty
# #{pane_current_path} for a dead pane. TAB is IFS whitespace, so the empty field
# collapsed into its neighbour and the transcript stamp landed in the cwd column:
# a suspended session was saved with its .jsonl path as its folder, and a restore
# after a reboot started it in the user's home instead.
#
# #{pane_start_path} survives the pane's death, so it is the fallback, and a "-"
# placeholder keeps the column from ever being empty.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== a dead pane is saved with its start folder and its own conversation =="

HOME_ROOT="$TEST_TMP/home"
export TMUX_PERSIST_HOME_ROOT="$HOME_ROOT"
WORK="$TEST_TMP/proj"
mkdir -p "$WORK"
slug="${WORK//\//-}"; slug="${slug//./-}"
PROJ="$HOME_ROOT/.claude/projects/$slug"
mkdir -p "$PROJ"
UUID="dddddddd-4444-4444-8444-dddddddddddd"
: > "$PROJ/$UUID.jsonl"

row() { awk -F'\t' -v s="$1" '$1==s' "$(newest_snap)"; }

# The shape suspend leaves: remain-on-exit on that session, the process gone.
tt new-session -d -s parked -c "$WORK" 'exec sleep 3600' 2>/dev/null
tt set-option -t parked @tl_origin user
tt set-option -t parked @claude_transcript "$PROJ/$UUID.jsonl"
tt set-option -t "=parked:" remain-on-exit on
tt respawn-pane -k -t "=parked:" 'true' 2>/dev/null
for i in $(seq 1 25); do
  [[ "$(tt display -p -t "=parked:" '#{pane_dead}')" == 1 ]] && break
  sleep 0.2
done
assert_eq "$(tt display -p -t "=parked:" '#{pane_dead}')" "1" "fixture: the pane is dead"

tp save >/dev/null 2>&1

IFS=$'\t' read -r name cwd uuid <<<"$(row parked)"
assert_eq "$name" "parked" "the dead session is still captured"
assert_eq "$cwd" "$WORK" "its folder is the one it started in, not the transcript path"
assert_eq "$uuid" "$UUID" "and its conversation stays in the uuid column"

echo "== a live pane still saves where it is now =="

MOVED="$TEST_TMP/moved"; mkdir -p "$MOVED"
tt new-session -d -s live -c "$WORK" 'exec bash --norc --noprofile' 2>/dev/null
tt set-option -t live @tl_origin user
sleep 0.5
tt send-keys -t "=live:" "cd $MOVED" C-m
for i in $(seq 1 25); do
  [[ "$(tt display -p -t "=live:" '#{pane_current_path}')" == "$MOVED" ]] && break
  sleep 0.2
done
tp save >/dev/null 2>&1
IFS=$'\t' read -r _ cwd _ <<<"$(row live)"
assert_eq "$cwd" "$MOVED" "a live pane's current folder wins over its start folder"

echo "== a live shell whose claude someone exited saves no conversation =="

# Its stamp still names the old conversation, but a person chose to leave it.
# Only a DEAD pane takes the stamp; a live shell restores as a shell, as before.
tt set-option -t live @claude_transcript "$PROJ/$UUID.jsonl"
tt kill-session -t "=parked"
tp save >/dev/null 2>&1
IFS=$'\t' read -r _ _ uuid <<<"$(row live)"
assert_eq "$uuid" "-" "a live shell with a stale stamp is saved without a conversation"

finish
