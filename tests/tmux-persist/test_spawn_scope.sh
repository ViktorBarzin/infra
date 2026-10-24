#!/usr/bin/env bash
# A restore that has to start the user's tmux server starts it inside a
# transient scope under the user's own systemd manager (2026-10-24).
#
# Before this, spawn_session ran `runuser -u <user> -- tmux new-session`, and
# the new server joined the caller's cgroup. At boot that caller is the
# tmux-persist-restore oneshot, and systemd kills a oneshot's cgroup when
# ExecStart returns: on 2026-10-23 emo's 11 restored sessions died 6s after
# they were restored. From the picker the caller is tmux-api, so the server
# died with any tmux-api restart and its panes were outside the per-pane cap.
#
# Seams: TMUX_PERSIST_SCOPE_RUN stands in for systemd-run (here a fake that
# logs its argv and runs the rest), TMUX_PERSIST_SCOPE_PROBE stands in for
# "does the user's systemd manager answer" (exit status).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

fake_run="$TEST_TMP/fake-systemd-run"
cat > "$fake_run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/scope.log"
# Drop the four scope flags and run the wrapped command, as systemd-run would.
[[ "\$1 \$2 \$3 \$4" == "--user --scope --quiet --collect" ]] || exit 99
shift 4
exec "\$@"
EOF
chmod +x "$fake_run"
export TMUX_PERSIST_SCOPE_RUN="$fake_run"

# A probe that counts its calls and answers with $PROBE_RC.
probe="$TEST_TMP/probe"
cat > "$probe" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TEST_TMP/probe.log"
exit "\${PROBE_RC:-0}"
EOF
chmod +x "$probe"
export TMUX_PERSIST_SCOPE_PROBE="$probe"

reset_logs() { rm -f "$TEST_TMP/scope.log" "$TEST_TMP/probe.log"; }
probe_calls() { [[ -f "$TEST_TMP/probe.log" ]] && wc -l < "$TEST_TMP/probe.log" | tr -d ' ' || echo 0; }

seed_snapshot 20261023T060000 \
  "$(printf 'one\t%s\t-' "$TEST_TMP")" \
  "$(printf 'two\t%s\t-' "$TEST_TMP")" \
  "$(printf 'three\t%s\t-' "$TEST_TMP")"
seed_pointer 20261023T060000

echo "== the user manager answers: sessions are spawned in a user scope =="

reset_logs
export PROBE_RC=0
out="$(tp restore "$TEST_USER" 2>&1)"
assert_contains "$out" "restored $TEST_USER:one" "restore reports session one"
assert_contains "$(cat "$TEST_TMP/scope.log" 2>/dev/null)" \
  "--user --scope --quiet --collect tmux -L $TMUX_PERSIST_TEST_SOCKET new-session -d -s one" \
  "new-session ran under systemd-run --user --scope"
assert_eq "$(tt has-session -t =three 2>&1 && echo yes)" "yes" "the scoped spawn created the sessions"
assert_eq "$(probe_calls)" "1" "the manager is probed once per user, not once per session"
assert_not_contains "$out" "WARN" "no warning when the scope is available"

echo "== the user manager never answers: plain spawn, with a warning =="

tt kill-server 2>/dev/null
reset_logs
export PROBE_RC=1
out="$(tp restore "$TEST_USER" 2>&1)"
assert_contains "$out" "WARN" "restore warns that it is spawning outside a user scope"
assert_eq "$(cat "$TEST_TMP/scope.log" 2>/dev/null)" "" "systemd-run was not used"
assert_eq "$(tt has-session -t =two 2>&1 && echo yes)" "yes" "sessions were still restored"
assert_eq "$(probe_calls)" "1" "a failed probe is not repeated for every session"
assert_not_contains "$out" "failed to restore" "no session was reported as failed"

echo "== restore-one goes through the same scope =="

tt kill-server 2>/dev/null
reset_logs
export PROBE_RC=0
out="$(tp restore-one "$TEST_USER" two 2>&1)"
assert_contains "$out" "restored $TEST_USER:two" "restore-one reports the restore"
assert_contains "$(cat "$TEST_TMP/scope.log" 2>/dev/null)" "new-session -d -s two" \
  "restore-one spawned in a user scope"

finish
