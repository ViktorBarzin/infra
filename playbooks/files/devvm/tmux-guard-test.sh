#!/usr/bin/env bash
# Tests for tmux-guard, the /usr/local/bin/tmux shim that refuses kill-server
# against a user's default tmux server.
#
# Why it exists: on 2026-10-06 an agent's e2e script set TMUX_TMPDIR to a
# private directory and ran `tmux kill-server`, expecting to stop only its own
# test server. The agent ran inside a lobby pane, so $TMUX was set, and tmux
# uses the socket named in $TMUX ahead of TMUX_TMPDIR. The command killed
# wizard's real server, twice, and every lobby session with it.
#
# The real tmux is replaced by a stub that prints its arguments, so nothing
# here talks to a live server.
set -uo pipefail
GUARD="$(dirname "$0")/tmux-guard"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/tmux" <<'EOF'
#!/bin/sh
echo "REAL $*"
EOF
chmod +x "$tmp/tmux"
uid="$(id -u)"
default="/tmp/tmux-$uid/default"

# run <env assignments...> -- <tmux args...>; prints "rc=<n>" then output.
run() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  local out rc
  out="$(env -u TMUX -u TMUX_TMPDIR -u TMUX_KILL_SERVER_OK \
         TMUX_GUARD_REAL="$tmp/tmux" "${envs[@]}" sh "$GUARD" "$@" 2>&1)"; rc=$?
  printf 'rc=%s\n%s' "$rc" "$out"
}

expect_blocked() { # name, run args...
  local name="$1"; shift
  local r; r="$(run "$@")"
  if [[ "$r" == rc=1* && "$r" != *REAL* && "$r" == *refusing* ]]; then ok "$name"
  else bad "$name" "$r"; fi
}
expect_passed() { # name, run args...
  local name="$1"; shift
  local r; r="$(run "$@")"
  if [[ "$r" == rc=0* && "$r" == *REAL* ]]; then ok "$name"
  else bad "$name" "$r"; fi
}

echo "blocked: kill-server aimed at the default server"
expect_blocked "the 2026-10-06 incident: \$TMUX set, private TMUX_TMPDIR" \
  "TMUX=$default,123,4" "TMUX_TMPDIR=$tmp/priv" -- kill-server
expect_blocked "no \$TMUX, no TMUX_TMPDIR" -- kill-server
expect_blocked "explicit -L default" -- -L default kill-server
expect_blocked "explicit -S to the default socket" -- -S "$default" kill-server
expect_blocked "after other global flags" "TMUX=$default,1,0" -- -f /dev/null -u kill-server
expect_blocked "inside a command list" "TMUX=$default,1,0" -- new -d -s x \; kill-server
expect_blocked "abbreviated command" "TMUX=$default,1,0" -- kill-ser

echo "passed: everything else"
expect_passed "kill-server on a named private server" "TMUX=$default,1,0" -- -L e2e kill-server
expect_passed "kill-server on a private -S socket" "TMUX=$default,1,0" -- -S "$tmp/s" kill-server
expect_passed "kill-server via a private TMUX_TMPDIR, no \$TMUX" "TMUX_TMPDIR=$tmp/priv" -- kill-server
expect_passed "kill-server when \$TMUX names a private socket" "TMUX=$tmp/s,1,0" -- kill-server
expect_passed "explicit override" "TMUX=$default,1,0" "TMUX_KILL_SERVER_OK=1" -- kill-server
expect_passed "kill-session is untouched" "TMUX=$default,1,0" -- kill-session -t foo
expect_passed "ordinary commands" "TMUX=$default,1,0" -- list-sessions -F '#{session_name}'
expect_passed "a session literally named kill-server" "TMUX=$default,1,0" -- new -d -s kill-server

r="$(run "TMUX=$default,1,0" -- display-message -p 'a b')"
if [[ "$r" == *"REAL display-message -p a b"* ]]; then ok "arguments reach real tmux intact"
else bad "arguments reach real tmux intact" "$r"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
