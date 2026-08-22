#!/usr/bin/env bash
# The restore picker's two endpoints must not fork per row or per snapshot.
#
# The web picker calls `snapshots` (the series) then `snapshot <ts>` (one
# snapshot resolved against live state). Both used to spawn a process per item:
#
#   snapshots      basename + grep -c + a $(...) subshell, per snapshot FILE
#   snapshot <ts>  ps -o comm= + pgrep -P, per node of each pane's process tree
#
# `ps` and `pgrep` read the WHOLE process table even when asked about one pid.
# Measured on the devvm 2026-08-16 against 678 processes / 2358 threads: 45 ms
# per `ps -o comm= -p PID`, 63 ms per `pgrep -P PID`, one `ps` issuing 2,759
# openat calls — while `read < /proc/<pid>/comm` is a builtin and free. The
# picker took ~2.9 s to open, ~2.2 s of it in that BFS.
#
# Timing would be a flaky assertion; fork COUNT is not. Recording shims sit
# ahead of the real tools on PATH and the endpoints must never reach them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== the picker's hot paths fork nothing per row or per snapshot =="

FORKLOG="$TEST_TMP/forks.log"; : > "$FORKLOG"

# Shims RECORD and then exec the real tool, so behaviour is unchanged and only
# the fork is observed. Real paths are resolved before PATH is shadowed.
SHIMS="$TEST_TMP/shims"; mkdir -p "$SHIMS"
for c in ps pgrep basename; do
  real="$(command -v "$c" || true)"
  [[ -n "$real" ]] || continue
  printf '#!/usr/bin/env bash\necho %s >> %q\nexec %q "$@"\n' "$c" "$FORKLOG" "$real" > "$SHIMS/$c"
  chmod +x "$SHIMS/$c"
done
export PATH="$SHIMS:$PATH"

forks_of() { grep -c "^$1\$" "$FORKLOG" 2>/dev/null || true; }

# --- fixtures: a series of snapshots, and live sessions to resolve against -----
for s in alpha bravo charlie; do mk_session "$s"; done
for t in 20260816T120000 20260816T121000 20260816T122000 20260816T123000; do
  seed_snapshot "$t" \
    "$(printf 'alpha\t%s\t-' "$TEST_TMP")" \
    "$(printf 'bravo\t%s\t-' "$TEST_TMP")" \
    "$(printf 'charlie\t%s\t-' "$TEST_TMP")"
done

# --- GET /snapshots — the series listing ---------------------------------------
: > "$FORKLOG"
out="$(tp snapshots "$TEST_USER")"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "4" "all four snapshots are listed"
assert_contains "$out" "20260816T123000" "the newest snapshot is listed"
assert_contains "$out" "$(printf '\t3\t')"  "each row carries its session count"
assert_contains "$out" "newest"            "the newest row is marked"
assert_eq "$(forks_of basename)" "0" "listing the series forks no basename"

# --- GET /snapshots/{ts} — one snapshot resolved against live state ------------
: > "$FORKLOG"
view="$(tp snapshot "$TEST_USER" 20260816T123000)"
assert_eq "$(printf '%s\n' "$view" | grep -c .)" "3" "all three rows resolve"
assert_contains "$view" "alpha" "the live session appears in the view"
assert_eq "$(forks_of ps)" "0"    "resolving a snapshot forks no ps"
assert_eq "$(forks_of pgrep)" "0" "resolving a snapshot forks no pgrep"

# --- the fork-free tree walk must still FIND a nested claude -------------------
# The rewrite replaced a ps/pgrep BFS, so prove the walk still recurses rather
# than only that it went quiet. A copy of python3 named `claude` gives a real
# process whose kernel comm is `claude` and whose argv carries a session id;
# it is started as a grandchild of the pane so a single level would miss it.
uuid="cafe1234-0000-4000-8000-abcdefabcdef"
cp "$(command -v python3)" "$TEST_TMP/claude"
# A SHELL pane, not mk_session's `exec sleep` — send-keys needs a shell to type
# into, and the claude has to be a grandchild so one level would miss it.
tt new-session -d -s deep -c "$TEST_TMP" 'exec bash --norc --noprofile' 2>/dev/null
for _ in $(seq 1 30); do
  [[ "$(tt list-panes -t deep -F '#{pane_current_command}' 2>/dev/null)" == bash ]] && break
  sleep 0.2
done
tt send-keys -t "=deep:" "bash -c '\"$TEST_TMP/claude\" -c \"import time;time.sleep(300)\" --session-id $uuid' &" C-m
for _ in $(seq 1 30); do
  pgrep -u "$(id -u)" -x claude >/dev/null 2>&1 && break
  sleep 0.2
done
sleep 0.5

seed_snapshot 20260816T124000 "$(printf 'deep\t%s\t%s' "$TEST_TMP" "$uuid")"
: > "$FORKLOG"
deepview="$(tp snapshot "$TEST_USER" 20260816T124000)"

# Same uuid live as in the snapshot => nothing to do. Reaching that verdict at
# all means the walk found the grandchild AND read its --session-id.
assert_contains "$deepview" "live_same" "the walk finds a nested claude and reads its session id"
assert_contains "$deepview" "skip"      "and resolves it as already-live"
assert_eq "$(forks_of ps)" "0"    "the deep walk still forks no ps"
assert_eq "$(forks_of pgrep)" "0" "the deep walk still forks no pgrep"

finish
