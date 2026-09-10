#!/usr/bin/env bash
# `picker <user>` answers the restore picker's whole opening question in ONE
# process: which snapshots exist, how many sessions are running now, and the
# newest snapshot resolved against them.
#
# The web picker used to ask twice — GET /snapshots then GET /snapshots/{ts} —
# and each call paid its own sudo, its own bash, its own user-map parse and its
# own tmux round trip, sequentially, before anything appeared on screen. The
# sections here carry the SAME row formats the two older verbs emit, so the
# server parses one stream with the parsers it already had.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== picker answers the whole open in one call =="

mk_session alpha
mk_session bravo

seed_snapshot 20260901T100000 \
  "$(printf 'alpha\t%s\t-' "$TEST_TMP")" \
  "$(printf 'bravo\t%s\t-' "$TEST_TMP")" \
  "$(printf 'charlie\t%s\t-' "$TEST_TMP")"
seed_snapshot 20260901T101000 \
  "$(printf 'alpha\t%s\t-' "$TEST_TMP")" \
  "$(printf 'bravo\t%s\t-' "$TEST_TMP")"

out="$(tp picker "$TEST_USER")"

# --- the three sections --------------------------------------------------------
assert_contains "$out" "$(printf '#live\t2')" "the live session count comes back with the list"
assert_contains "$out" "#snapshots" "the series section is marked"
assert_contains "$out" "$(printf '#rows\t20260901T101000')" "the row section names the snapshot it resolved"

# --- section 1 is exactly what `snapshots` prints -------------------------------
series="$(printf '%s\n' "$out" | sed -n '/^#snapshots$/,/^#rows/p' | grep -v '^#')"
assert_eq "$series" "$(tp snapshots "$TEST_USER")" "the series section matches the snapshots verb"

# --- section 2 is exactly what `snapshot <newest>` prints -----------------------
rows="$(printf '%s\n' "$out" | sed -n '/^#rows/,$p' | grep -v '^#')"
assert_eq "$rows" "$(tp snapshot "$TEST_USER" 20260901T101000)" "the row section matches the snapshot verb"

# --- and it resolved against live state, not just echoed the file ---------------
assert_contains "$rows" "live_same" "a running session resolves as already-live"

# --- a user with no snapshots at all --------------------------------------------
rm -f "$(snap_dir)"/*.tsv
empty="$(tp picker "$TEST_USER")"
assert_contains "$empty" "#snapshots" "an empty series still marks the section"
assert_not_contains "$empty" "#rows" "with no snapshots there is nothing to resolve"

# --- an unknown user is refused, as the other verbs refuse it -------------------
out="$(tp picker "not-a-user" 2>&1)"; rc=$?
assert_eq "$rc" "2" "an unknown user is refused"
assert_contains "$out" "not a known terminal user" "the refusal says why"

finish
