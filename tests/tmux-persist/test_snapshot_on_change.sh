#!/usr/bin/env bash
# A snapshot is written when the live session set CHANGES, and skipped when it
# does not. This is what keeps the picker list short enough to read: measured
# over three days, 277 saves held only 28 distinct session sets.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== snapshot is written only when the session set changes =="

# --- first save with one session writes the first snapshot ---
mk_session alpha
at_time 1786700000
tp save >/dev/null
assert_eq "$(snap_count)" "1" "first save writes a snapshot"
assert_file_exists "$(snap_dir)/$(date -u -d @1786700000 +%Y%m%dT%H%M%S).tsv" \
  "snapshot is named from the save time (UTC)"

# --- an unchanged set writes nothing ---
at_time 1786700300
tp save >/dev/null
assert_eq "$(snap_count)" "1" "unchanged session set writes no second snapshot"

# --- adding a session is a change ---
mk_session beta
at_time 1786700600
tp save >/dev/null
assert_eq "$(snap_count)" "2" "a new session writes a snapshot"
assert_eq "$(wc -l < "$(newest_snap)" | tr -d ' ')" "2" "newest snapshot holds both sessions"

# --- removing a session is a change ---
tt kill-session -t beta 2>/dev/null
at_time 1786700900
tp save >/dev/null
assert_eq "$(snap_count)" "3" "losing a session writes a snapshot"
assert_eq "$(wc -l < "$(newest_snap)" | tr -d ' ')" "1" "newest snapshot is back to one session"

# --- the older snapshot still holds the session that went away ---
assert_contains "$(cat "$(snap_dir)/$(date -u -d @1786700600 +%Y%m%dT%H%M%S).tsv")" "beta" \
  "the pre-loss snapshot still lists the session that died"

# --- the pointer manifest always resolves to the newest snapshot ---
assert_eq "$(cat "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv")" "$(cat "$(newest_snap)")" \
  "manifest resolves to the newest snapshot"

# --- an empty capture keeps the last manifest and writes no snapshot ---
# (a socket can outlive its server; installing that empty result would clobber
# a good manifest right before restore needs it)
tt kill-server 2>/dev/null
at_time 1786701200
tp save >/dev/null
assert_eq "$(snap_count)" "3" "an empty capture writes no snapshot"
assert_contains "$(cat "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv")" "alpha" \
  "an empty capture leaves the manifest pointing at the last good snapshot"

finish
