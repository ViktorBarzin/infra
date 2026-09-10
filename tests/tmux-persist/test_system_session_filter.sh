#!/usr/bin/env bash
# A session the lobby did not create must not be snapshotted, and above all must
# not be recreated at boot.
#
# terminal-lobby stamps @tl_origin=user on every session its own create path
# makes. A QA or e2e harness stamps "test" on its own, and anything nobody
# stamped at all is a session whose maker is unknown. Restoring either kind
# resumes a conversation nobody owns, under a session that reappears in the
# picker every time somebody opens it.
#
# The load-bearing subtlety is the ARMING rule. Every session alive before the
# stamper reaches a box is unstamped, so an unconditional filter would read them
# all as system sessions and stop persisting anybody's work. The filter engages
# only once the capture can see at least one stamped session, which is what
# proves the stamper is live on this box.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

stamp() { tt set-option -t "$1" @tl_origin "$2"; }

echo "== an unstamped box keeps persisting everything =="

mk_session legacy_a
mk_session legacy_b
mk_session qa-early          # a reserved name needs no arming and never counts

at_time 1786711920
tp save >/dev/null 2>&1

snap="$(newest_snap)"
assert_file_exists "$snap" "a save on an unstamped box writes a snapshot"
body="$(cat "$snap")"
assert_contains     "$body" "legacy_a" "an unstamped session is captured while nothing is stamped"
assert_contains     "$body" "legacy_b" "so is the one beside it"
assert_not_contains "$body" "qa-early" "a reserved name is dropped even before the box stamps"

echo "== once the box stamps, system sessions drop out =="

mk_session mine
stamp mine user
mk_session harness
stamp harness test
mk_session qa-fleet          # reserved prefix, and deliberately left unstamped
mk_session nobody_made_me    # unstamped, so unattributed

at_time 1786712400
tp save >/dev/null 2>&1

snap="$(newest_snap)"
body="$(cat "$snap")"
assert_contains     "$body" "mine"           "a session the lobby created is captured"
assert_not_contains "$body" "harness"        "a session a harness stamped is not captured"
assert_not_contains "$body" "qa-fleet"       "a reserved prefix is not captured"
assert_not_contains "$body" "nobody_made_me" "a session nobody stamped is not captured"
assert_not_contains "$body" "legacy_a"       "an unstamped session drops out once the box is stamping"

# The load-bearing consequence: nothing restores them.
for s in mine harness qa-fleet nobody_made_me legacy_a legacy_b qa-early; do
  tt kill-session -t "=$s" 2>/dev/null || true
done

out="$(tp restore "$TEST_USER" 2>&1)"
assert_contains     "$out" "mine"     "restore recreates the session the lobby made"
assert_not_contains "$out" "harness"  "restore does not recreate a harness session"
assert_not_contains "$out" "qa-fleet" "restore does not recreate a reserved-prefix session"

TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=harness" 2>/dev/null; then
  _fail "the harness session was resurrected by restore"
else
  _pass "the harness session stayed gone"
fi

echo "== a stamped session with no transcript keeps its columns straight =="

# Two adjacent optional columns is the trap this guards: TAB is IFS whitespace,
# so an unstamped transcript beside a stamped origin used to shift the origin
# into the transcript's variable. A session with neither must still capture.
mk_session plain
stamp plain user
at_time 1786713000
tp save >/dev/null 2>&1
body="$(cat "$(newest_snap)")"
assert_contains "$body" "plain" "a stamped session with no transcript is captured"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q $'\tuser' "$(newest_snap)"; then
  _fail "the origin column leaked into the snapshot row"
else
  _pass "the origin column stays out of the snapshot row"
fi

# A save that sees ONLY system sessions must behave like a save that saw nothing:
# writing an empty snapshot here would erase the history the previous one holds.
#
# A reserved NAME is what this uses, not a stamped origin. With no user-stamped
# session live the arming check reads the box as unstamped and the origin rule
# stands down, which is the whole point of it; the name rule does not need arming
# and is what still holds here.
tt kill-session -t "=mine" 2>/dev/null || true
tt kill-session -t "=plain" 2>/dev/null || true
mk_session qa-only
before="$(snap_count)"
at_time 1786713600
tp save >/dev/null 2>&1
assert_eq "$(snap_count)" "$before" \
  "a save seeing only system sessions writes no snapshot"

echo "== a tab in a pane's cwd cannot corrupt the origin column =="

# `read` gives its LAST variable everything left over, separators included, so
# whichever column goes last absorbs a stray tab in the ones before it. Origin
# therefore sits third and the transcript keeps the absorbing job. Without that
# ordering the tab below would hand `origin` the string "<transcript>\tuser",
# which reads as a foreign origin and drops a real session out of every snapshot.
tabbed="$TEST_TMP/has"$'\t'"tab"
mkdir -p "$tabbed"
mk_session tabbed_cwd "$tabbed"
stamp tabbed_cwd user
mk_session anchor
stamp anchor user

at_time 1786714200
tp save >/dev/null 2>&1
body="$(cat "$(newest_snap)")"
assert_contains "$body" "tabbed_cwd" \
  "a session whose cwd contains a tab is still captured"

finish
