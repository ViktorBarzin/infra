#!/usr/bin/env bash
# restore-one's optional third argument: a first message for the resumed claude
# (2026-09-26). tl-session-watch calls `restore-one <user> <name> <message>` when
# the pane memory cap kills a session's claude, so the conversation comes back
# already told what happened.
#
# The message rides into the pane as ONE argv word to claude, after --resume, in
# both shapes a killed session can be in:
#   - gone from tmux (the pane was `zsh -lic "claude ..."`, so the session died
#     with claude): a new session is spawned.
#   - still live with only its shell left (a session an earlier restore made,
#     whose command ends in `exec bash -l`): the resume is typed into that shell.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

# A claude that writes its argv, one word per line, and then exits, so the pane
# falls through to its preserved shell the way a real one would.
fake_claude="$TEST_TMP/fake-claude"
cat > "$fake_claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/argv.\$(date +%s%N)"
EOF
chmod +x "$fake_claude"
export TMUX_PERSIST_CLAUDE_BIN="$fake_claude"

wait_for_argv() {
  local i
  for i in $(seq 1 50); do
    compgen -G "$TEST_TMP/argv.*" >/dev/null && return 0
    sleep 0.1
  done
  return 1
}
last_argv() { cat "$(ls -1 "$TEST_TMP"/argv.* | sort | tail -1)"; }
clear_argv() { rm -f "$TEST_TMP"/argv.*; }

uuid="aaaaaaaa-1111-2222-3333-444444444444"
msg="You were killed by the pane's memory cap. Don't re-run \$HOME \"as is\"; check what finished."

echo "== a session that is gone comes back with the message =="

seed_snapshot 20260926T120000 "$(printf 'gone\t%s\t%s' "$TEST_TMP" "$uuid")"
seed_pointer 20260926T120000

out="$(tp restore-one "$TEST_USER" gone "$msg" 2>&1)"
assert_contains "$out" "restored" "restore-one reports the restore"
wait_for_argv || true
argv="$(last_argv 2>/dev/null)"
assert_contains "$argv" "--resume
$uuid" "claude is resumed on the saved conversation"
assert_eq "$(tail -1 <<<"$argv")" "$msg" "the message is the last argument, byte for byte"
# Every lobby surface reads an unstamped session as a system session: hidden in
# the System group, no push, suspended after 4h, skipped by the death watcher
# and by the next snapshot. Only user sessions are ever snapshotted, so a
# restored one is a user session.
assert_eq "$(tt show-options -t "=gone:" -v @tl_origin 2>&1)" "user" "the restored session is stamped as a user session"

echo "== without a message, the argv is unchanged =="

clear_argv
tt kill-session -t "=gone" 2>/dev/null
out="$(tp restore-one "$TEST_USER" gone 2>&1)"
wait_for_argv || true
argv="$(last_argv 2>/dev/null)"
assert_eq "$(tail -1 <<<"$argv")" "gone" "the last argument is still the --name value"

echo "== a live session with only its shell left is resumed in place =="

clear_argv
tt new-session -d -s shellonly -c "$TEST_TMP" 'exec bash --norc --noprofile' 2>/dev/null
for i in $(seq 1 25); do
  [[ "$(tt list-panes -t shellonly -F '#{pane_current_command}' 2>/dev/null)" == bash ]] && break
  sleep 0.2
done
seed_snapshot 20260926T121000 "$(printf 'shellonly\t%s\t%s' "$TEST_TMP" "$uuid")"
seed_pointer 20260926T121000

out="$(tp restore-one "$TEST_USER" shellonly "$msg" 2>&1)"
assert_contains "$out" "resumed" "restore-one resumes in place"
wait_for_argv || true
argv="$(last_argv 2>/dev/null)"
assert_contains "$argv" "$uuid" "the typed resume names the saved conversation"
assert_eq "$(tail -1 <<<"$argv")" "$msg" "the typed message survives the shell intact"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$(tt list-sessions -F '#{session_name}' | grep -cx shellonly)" == 1 ]]; then
  _pass "the surviving session is reused, not duplicated"
else
  _fail "a second shellonly session appeared"
fi

echo "== a live session running something else is left alone =="

clear_argv
mk_session busy
seed_snapshot 20260926T122000 "$(printf 'busy\t%s\t%s' "$TEST_TMP" "$uuid")"
seed_pointer 20260926T122000
out="$(tp restore-one "$TEST_USER" busy "$msg" 2>&1)"
assert_contains "$out" "already live" "a pane that is not a bare shell is not typed into"
sleep 0.5
TESTS_RUN=$((TESTS_RUN + 1))
if compgen -G "$TEST_TMP/argv.*" >/dev/null; then _fail "claude was started in a busy pane"; else _pass "nothing was started"; fi

finish
