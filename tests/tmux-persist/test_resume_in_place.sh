#!/usr/bin/env bash
# Regression test for the in-place resume path (2026-08-16).
#
# When a pane's claude exits but its shell survives, the restore is meant to
# type the resume command back into that same pane instead of building a second
# session. The target used was `send-keys -t "=<name>"`. tmux accepts the `=`
# exact-match prefix on a session or window target, but `send-keys` takes a PANE
# target and rejects it there — "can't find pane: =<name>" — so the branch
# logged a WARN and left a bare shell on every run since it was written.
#
# `=<name>:` is accepted as a pane target and still matches the name exactly,
# which is what this pins: the resume lands, and it lands in the right pane.
#
# Seen live on 2026-08-16: a restore of four panes whose claudes had been
# OOM-killed produced four WARNs and four empty shells.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== a pane whose claude died is resumed in place =="

# "claude died, shell survived" is a pane whose current command is a shell.
# mk_session runs `sleep`, which is_shell() correctly refuses to treat as one.
mk_shell_session() {
  tt new-session -d -s "$1" -c "$TEST_TMP" 'exec bash --norc --noprofile' 2>/dev/null
}

# tmux reports the pane command only once the child has exec'd.
wait_for_cmd() {
  local sess="$1" want="$2" i
  for i in $(seq 1 25); do
    [[ "$(tt list-panes -t "$sess" -F '#{pane_current_command}' 2>/dev/null)" == "$want" ]] && return 0
    sleep 0.2
  done
  return 1
}

wait_for_pane_text() {
  local sess="$1" needle="$2" i
  for i in $(seq 1 25); do
    [[ "$(tt capture-pane -p -J -t "$sess" 2>/dev/null)" == *"$needle"* ]] && return 0
    sleep 0.2
  done
  return 1
}

uuid="11111111-2222-3333-4444-555555555555"

mk_shell_session revive
mk_shell_session revive-long          # a longer name that must never be hit instead
wait_for_cmd revive bash      || { echo "fixture: revive never reached a shell" >&2; exit 1; }
wait_for_cmd revive-long bash || { echo "fixture: revive-long never reached a shell" >&2; exit 1; }

ts=20260816T120000
seed_snapshot "$ts" "$(printf 'revive\t%s\t%s' "$TEST_TMP" "$uuid")"

# --- the pane is classified as a dead claude, not as missing or as a rename ---
view="$(tp snapshot "$TEST_USER" "$ts")"
assert_contains "$view" "live_no_claude" "a shell-only pane reads as a claude that died"
assert_contains "$view" "in_place"       "and is scheduled for an in-place resume"

# --- the resume actually reaches the pane ---
out="$(tp restore-selection "$TEST_USER" "$ts" revive 2>&1)"
assert_not_contains "$out" "can't find pane" "the pane target resolves"
assert_not_contains "$out" "WARN"            "the resume reports no failure"
assert_contains     "$out" "resumed"         "the resume is logged"

wait_for_pane_text revive "$uuid" || true
pane="$(tt capture-pane -p -J -t revive)"
assert_contains "$pane" "$uuid"     "the resume command was typed into the surviving pane"
assert_contains "$pane" "--resume"  "carrying the resume flag"

# --- and only that pane ---
assert_not_contains "$(tt capture-pane -p -J -t revive-long)" "$uuid" \
  "a longer session name is not resumed by prefix match"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$(tt list-sessions -F '#{session_name}' | grep -cx 'revive')" == "1" ]]; then
  _pass "the surviving pane is reused rather than duplicated"
else
  _fail "restore made a second session instead of resuming in place"
fi

# --- a SPAWNED pane waits for its cgroup before forking claude -----------------
#
# tmux moves a new pane into its own scope asynchronously. `claude ...; exec bash`
# is compound, so the shell forks claude immediately and can leave it in the tmux
# server's cgroup, outside the per-pane MemoryMax. The spawn command carries a
# bounded wait so the fork happens after the move.
echo
echo "== a spawned pane settles into its cgroup before forking =="

ts2=20260816T130000
seed_snapshot "$ts2" "$(printf 'fresh-pane\t%s\t%s' "$TEST_TMP" "$uuid")"
tp restore-selection "$TEST_USER" "$ts2" fresh-pane >/dev/null 2>&1

TESTS_RUN=$((TESTS_RUN + 1))
if tt has-session -t "=fresh-pane" 2>/dev/null; then
  _pass "the spawned session still comes up with the wait in front"
else
  _fail "the cgroup wait broke session spawning"
fi

# The wait must be bounded: this fixture's tmux may not create scopes at all, and
# the session above still had to start.
assert_contains "$(sed -n "/^CGROUP_SETTLE=/p" "$SCRIPT_UNDER_TEST")" \
  "i -lt 40" "the wait is bounded rather than open-ended"
assert_contains "$(sed -n "/^CGROUP_SETTLE=/p" "$SCRIPT_UNDER_TEST")" \
  "tmux-spawn-" "the wait watches for the pane scope"
assert_not_contains "$(sed -n "/^CGROUP_SETTLE=/p" "$SCRIPT_UNDER_TEST")" \
  "grep" "the check does not fork a helper of its own"

finish
