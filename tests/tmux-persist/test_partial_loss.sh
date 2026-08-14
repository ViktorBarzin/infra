#!/usr/bin/env bash
# The regression test for 2026-08-14 (and 2026-07-18 before it).
#
# The tmux server survives while the processes inside individual sessions are
# killed. The old manifest was rewritten in place on the next 5-minute tick, so
# a save landing MID-KILL dropped the already-dead sessions and one Restore
# click could only bring back whatever happened to still be listed.
#
# Snapshots make the pre-loss set reachable afterwards.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== a partial loss leaves the pre-loss set recoverable =="

full=(alpha bravo charlie delta echo foxtrot golf hotel india)
for s in "${full[@]}"; do mk_session "$s"; done

at_time 1786711800          # 12:50 — everything up
tp save >/dev/null
assert_eq "$(wc -l < "$(newest_snap)" | tr -d ' ')" "9" "12:50 snapshot holds all 9 sessions"
full_snap="$(newest_snap)"

# 12:59 — memory pressure takes four of them; the tmux server stays up.
for s in foxtrot golf hotel india; do tt kill-session -t "$s" 2>/dev/null; done
at_time 1786712340
tp save >/dev/null
assert_eq "$(wc -l < "$(newest_snap)" | tr -d ' ')" "5" "12:59 snapshot reflects the partial loss"

# 13:00 — the save that used to destroy the evidence lands mid-kill.
for s in charlie delta echo; do tt kill-session -t "$s" 2>/dev/null; done
at_time 1786712449
tp save >/dev/null
assert_eq "$(wc -l < "$(newest_snap)" | tr -d ' ')" "2" "13:00 snapshot reflects the deeper loss"

# The pre-loss snapshot is still on disk and still complete. This is the whole fix.
assert_eq "$(wc -l < "$full_snap" | tr -d ' ')" "9" "the 12:50 snapshot is untouched by later saves"
for s in "${full[@]}"; do
  assert_contains "$(cat "$full_snap")" "$s" "12:50 snapshot still lists $s"
done

# --- the snapshot list is what the picker reads ---
list="$(tp snapshots "$TEST_USER")"
assert_eq "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" "3" "three snapshots listed"
assert_contains "$(printf '%s\n' "$list" | head -1)" "20260814T130049" "newest snapshot listed first"
assert_contains "$list" "	9" "the list carries each snapshot's session count"

# --- restoring the chosen snapshot brings the whole set back ---
ts="$(basename "$full_snap" .tsv)"
tp restore-selection "$TEST_USER" "$ts" charlie delta echo foxtrot golf hotel india >/dev/null 2>&1
for s in charlie delta echo foxtrot golf hotel india; do
  TESTS_RUN=$((TESTS_RUN + 1))
  if tt has-session -t "=$s" 2>/dev/null; then _pass "$s restored"; else _fail "$s was not restored"; fi
done

# Sessions that never died are left alone rather than disturbed.
TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=alpha" 2>/dev/null; then _pass "the surviving session is untouched"; else _fail "alpha went missing"; fi

# --- a selection may not reach outside the snapshot it names ---
out="$(tp restore-selection "$TEST_USER" "$ts" not-in-that-snapshot 2>&1)"; rc=$?
assert_eq "$rc" "1" "a name absent from the snapshot is refused"
assert_contains "$out" "not-in-that-snapshot" "the refusal names the offending selection"

finish
