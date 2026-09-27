#!/usr/bin/env bash
# claude-command-scope, the CLAUDE_CODE_SHELL_PREFIX wrapper (2026-09-27).
#
# Claude Code hands the wrapper one argument: the command string, for Bash tool
# calls, hooks, the status line and stdio MCP server startups alike. Only a Bash
# tool call starts by sourcing a shell snapshot, and only those go into their
# own systemd scope, so a test run or dev server is charged to its own 6G cap
# instead of the pane claude lives in.
set -uo pipefail
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/playbooks/files/devvm/claude-command-scope"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0 runs=0
check() { runs=$((runs+1)); if [[ "$1" == "$2" ]]; then echo "  ok   $3"; else echo "  FAIL $3"; echo "       want: $2"; echo "       got:  $1"; fails=$((fails+1)); fi; }

# A systemd-run that records how it was called and then runs the command, and a
# "user shell" that says which shell ran the string.
mkdir -p "$T/bin" "$T/run"
cat > "$T/bin/systemd-run" <<'SR'
#!/usr/bin/env bash
echo "$*" > "$SR_LOG"
while [[ "$1" != "--" ]]; do shift; done; shift
exec "$@"
SR
cat > "$T/usershell" <<'US'
#!/usr/bin/env bash
[[ "$1" == "-c" ]] && { echo "usershell"; exec bash -c "$2"; }
US
chmod +x "$T/bin/systemd-run" "$T/usershell"
: > "$T/run/bus"   # stands in for the socket; the wrapper tests with -e
export SR_LOG="$T/sr.log" PATH="$T/bin:$PATH" SHELL="$T/usershell"

snap="source /home/x/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'echo hi'"

echo "== a Bash tool call runs in its own scope, under the user's shell =="
rm -f "$SR_LOG"
out="$(XDG_RUNTIME_DIR="$T/run" "$SUT" "$snap")"
check "$out" $'usershell\nhi' "the command ran under the user's shell"
check "$(cat "$SR_LOG" 2>/dev/null)" "--user --scope --quiet --collect -- $T/usershell -c $snap" "through systemd-run --user --scope"

echo "== exit codes come back =="
XDG_RUNTIME_DIR="$T/run" "$SUT" "source /x/.claude/shell-snapshots/snapshot-zsh-1.sh; exit 7" >/dev/null
check "$?" "7" "a failing command's status reaches Claude"

echo "== a hook is not scoped and runs under bash =="
rm -f "$SR_LOG"
out="$(XDG_RUNTIME_DIR="$T/run" "$SUT" 'echo "$0"')"
check "$out" "bash" "a hook runs under bash -c"
check "$(cat "$SR_LOG" 2>/dev/null || echo none)" "none" "and never touches systemd-run"

echo "== with no user bus, a Bash tool call still runs =="
rm -f "$SR_LOG"
out="$(XDG_RUNTIME_DIR="$T/nothere" "$SUT" "$snap")"
check "$out" $'usershell\nhi' "it runs under the user's shell without a scope"
check "$(cat "$SR_LOG" 2>/dev/null || echo none)" "none" "and does not try systemd-run"

echo
(( fails == 0 )) && echo "all $runs passed" || { echo "$fails/$runs FAILED"; exit 1; }
