#!/usr/bin/env bash
# awk compares two numeric-looking strings as NUMBERS, so a bare `$1==s`
# selector matched session "007" when asked for "7" (and "1e2" when asked for
# "100"). Passing the name via -v stops injection but not this mis-comparison;
# the fix is to force string context with $1""==s"".
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== restore-one selects by string, never by numeric coercion =="

seed_snapshot 20260814T120000 \
  "007	/tmp	aaaaaaaa-1111-1111-1111-111111111111" \
  "1e2	/tmp	bbbbbbbb-2222-2222-2222-222222222222" \
  "ordinary	/tmp	cccccccc-3333-3333-3333-333333333333"
seed_pointer 20260814T120000

# "7" must match nothing — 007 is a different session name.
out="$(tp restore-one "$TEST_USER" 7 2>&1)"; rc=$?
assert_eq "$rc" "1" "restore-one 7 fails (no such session)"
assert_not_contains "$out" "restored" "restore-one 7 restores nothing"
TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=007" 2>/dev/null; then _fail "007 was restored by selector 7"; else _pass "007 untouched by selector 7"; fi

# "100" must not match "1e2" (awk reads both as the number 100).
out="$(tp restore-one "$TEST_USER" 100 2>&1)"; rc=$?
assert_eq "$rc" "1" "restore-one 100 fails (no such session)"
TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=1e2" 2>/dev/null; then _fail "1e2 was restored by selector 100"; else _pass "1e2 untouched by selector 100"; fi

# The exact name still works.
out="$(tp restore-one "$TEST_USER" 007 2>&1)"
assert_contains "$out" "restored" "the exact name 007 restores"
TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=007" 2>/dev/null; then _pass "007 restored by its own name"; else _fail "007 was not restored by its own name"; fi

# A uuid prefix still selects.
out="$(tp restore-one "$TEST_USER" cccccccc 2>&1)"
assert_contains "$out" "ordinary" "a uuid prefix selects its session"

# restore-one searches ALL snapshots, not just the newest — the whole point of
# keeping history is reaching a session that is no longer in the live set.
seed_snapshot 20260814T130000 "ordinary	/tmp	cccccccc-3333-3333-3333-333333333333"
seed_pointer 20260814T130000
out="$(tp restore-one "$TEST_USER" 1e2 2>&1)"
assert_contains "$out" "restored" "a session only present in an older snapshot is still restorable"

finish
