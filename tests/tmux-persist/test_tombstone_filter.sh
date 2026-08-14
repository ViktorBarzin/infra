#!/usr/bin/env bash
# A session you deliberately killed stays IN the older snapshots (point-in-time
# restore keeps it pickable) but is not recreated on its own.
#
# Snapshots are immutable, so tmux-persist-forget can no longer drop a row from
# the live manifest the way it used to. A tombstone carries that intent instead:
# blanket restore skips the name, and the picker offers the row unchecked.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== deliberate kills are tombstoned, not resurrected =="

row_for() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1==n'; }

seed_snapshot 20260814T125000 \
  "keeper	/tmp	11111111-1111-1111-1111-111111111111" \
  "Wrongmove	/tmp	22222222-2222-2222-2222-222222222222"
seed_pointer 20260814T125000

# Viktor closes Wrongmove at 12:52, two minutes after that snapshot.
at_time 1786711920
tp forget "$TEST_USER" Wrongmove >/dev/null

assert_file_exists "$TMUX_PERSIST_STATE_DIR/$TEST_USER.forgotten.tsv" "forget writes a tombstone"
assert_contains "$(cat "$TMUX_PERSIST_STATE_DIR/$TEST_USER.forgotten.tsv")" "Wrongmove" \
  "tombstone names the session"

# The snapshot is untouched — history must not be rewritten.
assert_contains "$(cat "$(snap_dir)/20260814T125000.tsv")" "Wrongmove" \
  "the snapshot still lists the killed session"

# --- the picker view offers it, but unchecked ---
view="$(tp snapshot "$TEST_USER" 20260814T125000)"
assert_contains "$view" "Wrongmove" "picker view still offers the killed session"

keeper_line="$(row_for "$view" keeper)"
wrong_line="$(row_for "$view" Wrongmove)"
assert_eq "$(printf '%s' "$keeper_line" | cut -f7)" "on"  "an ordinary missing session is pre-checked"
assert_eq "$(printf '%s' "$wrong_line"  | cut -f7)" "off" "a deliberately-killed session is NOT pre-checked"
assert_contains "$(printf '%s' "$wrong_line" | cut -f8)" "killed@1786711920" \
  "the row carries when it was killed, so the UI can say so"

# --- blanket restore skips it ---
out="$(tp restore "$TEST_USER" 2>&1)"
assert_contains "$out" "keeper" "blanket restore recreates the ordinary session"
assert_not_contains "$out" "restored $TEST_USER:Wrongmove" \
  "blanket restore does not resurrect the killed session"

TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=Wrongmove" 2>/dev/null; then
  _fail "Wrongmove was recreated by blanket restore"
else
  _pass "Wrongmove stayed dead"
fi

# --- a tombstone OLDER than the snapshot must not suppress it ---
# (killed at 12:52, then deliberately started again and captured at 12:55)
seed_snapshot 20260814T125500 "Wrongmove	/tmp	22222222-2222-2222-2222-222222222222"
later_row="$(row_for "$(tp snapshot "$TEST_USER" 20260814T125500)" Wrongmove)"
assert_eq "$(printf '%s' "$later_row" | cut -f7)" "on" \
  "a kill BEFORE the snapshot does not un-check a session captured after it"

finish
