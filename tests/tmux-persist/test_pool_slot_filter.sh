#!/usr/bin/env bash
# A pre-warmed terminal-lobby pool slot is not a session anybody owns, so it
# must not be snapshotted — and above all must not be recreated at boot.
#
# The slot exists so that creating a session costs a tmux rename (~9ms) instead
# of a Claude cold start (~2.7s). It is named beyond the 32 characters the
# lobby's session-name pattern allows, precisely so that no client can address
# it. Restoring one would resurrect a slot as if it were somebody's work, under
# a name they can neither open nor kill.
#
# The rule is written as "skip what the lobby cannot address" rather than
# "skip the pool prefix", so it also covers the names tmux accepts but this
# stack never hands out — a `tmux new -s 'has space'` from a shell, say.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== unaddressable sessions are neither captured nor restored =="

SLOT='__terminal_lobby_prewarmed_pool_slot__tmp'

mk_session keeper
mk_session "$SLOT"
mk_session 'has space'

at_time 1786711920
tp save >/dev/null 2>&1

snap="$(newest_snap)"
assert_file_exists "$snap" "a save with live sessions writes a snapshot"

body="$(cat "$snap")"
assert_contains     "$body" "keeper" "an ordinary session is captured"
assert_not_contains "$body" "prewarmed_pool_slot" "the pool slot is not captured"
assert_not_contains "$body" "has space" "a name the lobby cannot address is not captured"

# The load-bearing consequence: nothing restores it. Kill everything, restore,
# and the slot must stay gone while the ordinary session comes back.
tt kill-session -t "=$SLOT" 2>/dev/null || true
tt kill-session -t "=keeper" 2>/dev/null || true

out="$(tp restore "$TEST_USER" 2>&1)"
assert_contains     "$out" "keeper" "restore recreates the ordinary session"
assert_not_contains "$out" "prewarmed_pool_slot" "restore does not recreate the pool slot"

TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=$SLOT" 2>/dev/null; then
  _fail "the pool slot was resurrected by restore"
else
  _pass "the pool slot stayed gone"
fi

# A save that sees ONLY unaddressable sessions must behave like a save that saw
# nothing at all: writing an empty snapshot here would erase the real history
# the previous snapshot holds.
before="$(snap_count)"
tt kill-session -t "=keeper" 2>/dev/null || true
at_time 1786712400
tp save >/dev/null 2>&1
assert_eq "$(snap_count)" "$before" \
  "a save seeing only unaddressable sessions writes no snapshot"

finish
