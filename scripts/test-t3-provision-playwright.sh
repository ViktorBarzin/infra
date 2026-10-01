#!/usr/bin/env bash
# Checks for t3-provision-users.sh's per-user playwright wiring: the switch from
# the shared playwright-mcp@ http server to terminal-lobby's stdio tl-browser
# launcher, and when the shared server may be stopped.
#
# Run: bash scripts/test-t3-provision-playwright.sh
#
# The provisioning script acts on the box when sourced, so this pulls the two
# functions out of it by name and runs them against stand-ins for claude,
# runuser, systemctl and ps. The stand-in `claude mcp get` prints the same lines
# the real CLI printed on the devvm on 2026-10-01.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }

extract() {  # the text of one top-level function, from its name to its closing brace
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
eval "$(extract install_playwright)"
eval "$(extract playwright_stdio_settled)"
declare -F install_playwright >/dev/null || { echo "FAIL: install_playwright not found"; exit 1; }
declare -F playwright_stdio_settled >/dev/null || { echo "FAIL: playwright_stdio_settled not found"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fakebin="$tmp/bin"; mkdir -p "$fakebin" "$tmp/home" "$tmp/env"
export MCP_STATE="$tmp/mcp" PATH="$fakebin:$PATH"

# claude stand-in. $MCP_STATE holds the user-scope playwright entry as
# "http <url>" or "stdio <command>"; absent means no entry.
cat > "$fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == mcp ]] || exit 1
case "$2" in
  get)
    [[ -s "$MCP_STATE" ]] || { echo "No MCP server named \"$3\"." >&2; exit 1; }
    read -r kind target < "$MCP_STATE"
    echo "playwright:"
    echo "  Scope: User config (available in all your projects)"
    if [[ "$kind" == http ]]; then
      printf '  Type: http\n  URL: %s\n' "$target"
    else
      printf '  Type: stdio\n  Command: %s\n  Args:\n  Environment:\n' "$target"
    fi ;;
  remove) rm -f "$MCP_STATE" ;;
  add)
    [[ -s "$MCP_STATE" ]] && exit 1   # the real CLI refuses to clobber
    shift 2; transport=stdio
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --scope) shift 2 ;;
        --transport) transport="$2"; shift 2 ;;
        --) shift; echo "stdio $1" > "$MCP_STATE"; exit 0 ;;
        playwright) shift ;;
        *) echo "$transport $1" > "$MCP_STATE"; exit 0 ;;
      esac
    done ;;
esac
FAKE
chmod +x "$fakebin/claude"

runuser() { shift 3; bash -c "$3"; }        # runuser -u U -- bash -lc CMD
getent() { echo "alice:x:1001:1001::$tmp/home:/bin/bash"; }
id() { echo 1001; }
log() { echo "$*" >> "$tmp/log"; }
run() { "$@"; }
retire_legacy_playwright_units() { :; }
mkdir_as() { :; }
write_as() { cat > /dev/null; }
systemctl() {
  echo "$*" >> "$tmp/systemctl"
  if [[ "$1" == is-enabled ]]; then [[ -e "$tmp/mcp-enabled" ]]; return; fi
  if [[ "$*" == "disable --now playwright-mcp@alice.service" ]]; then rm -f "$tmp/mcp-enabled"; fi
  if [[ "$*" == "enable --now playwright-mcp@alice.service" ]]; then touch "$tmp/mcp-enabled"; fi
  return 0
}
PS_OUT=""
ps() { [[ -n "$PS_OUT" ]] && printf '%s\n' "$PS_OUT"; return 0; }

export DRY_RUN=0
ENVDIR="$tmp/env"
STATEDIR="$tmp/state"; mkdir -p "$STATEDIR"
echo "PLAYWRIGHT_PORT=8933" > "$ENVDIR/playwright-alice.env"
export TL_BROWSER_BIN="$tmp/tl-browser"
since="$STATEDIR/playwright-stdio-alice.since"
reset() { rm -f "$MCP_STATE" "$since" "$tmp/systemctl" "$tmp/mcp-enabled" "$TL_BROWSER_BIN"; PS_OUT=""; }
entry() { cat "$MCP_STATE" 2>/dev/null; }
called() { grep -qxF "$1" "$tmp/systemctl" 2>/dev/null; }

# --- without tl-browser: the http entry, as before ---------------------------
reset
install_playwright alice false
eq "no tl-browser: wires the http entry" "http http://localhost:8933/mcp" "$(entry)"
ok "no tl-browser: shared server enabled" called "enable --now playwright-mcp@alice.service"
ok "no tl-browser: snapshot timer enabled" called "enable --now playwright-snapshot-refresh@alice.timer"
no "no tl-browser: no switch recorded" test -e "$since"

# --- tl-browser installed: replace our http entry, record the switch ---------
reset
echo "http http://localhost:8933/mcp" > "$MCP_STATE"; touch "$tmp/mcp-enabled"
printf '#!/bin/sh\n' > "$TL_BROWSER_BIN"; chmod +x "$TL_BROWSER_BIN"
PS_OUT="  99999 claude"   # a session started long before the switch
install_playwright alice false
eq "switch: entry is the stdio launcher" "stdio $TL_BROWSER_BIN" "$(entry)"
ok "switch: time recorded" test -s "$since"
ok "switch: snapshot timer still enabled" called "enable --now playwright-snapshot-refresh@alice.timer"
no "switch: old session keeps the shared server" called "disable --now playwright-mcp@alice.service"
ok "switch: shared server still enabled" test -e "$tmp/mcp-enabled"

# A second run while the old session lives changes nothing.
first="$(cat "$since")"; : > "$tmp/systemctl"
echo $(( first - 50 )) > "$since"; recorded="$(cat "$since")"
install_playwright alice false
eq "rerun: switch time not rewritten" "$recorded" "$(cat "$since")"
no "rerun: old session still keeps the shared server" called "disable --now playwright-mcp@alice.service"

# Once only sessions started after the switch remain, the shared server stops.
: > "$tmp/systemctl"
PS_OUT="     10 claude
  99999 bash"
install_playwright alice false
ok "settled: shared server disabled" called "disable --now playwright-mcp@alice.service"
no "settled: shared server not re-enabled" called "enable --now playwright-mcp@alice.service"
ok "settled: snapshot timer still enabled" called "enable --now playwright-snapshot-refresh@alice.timer"

# And stays stopped on the next run, without another disable.
: > "$tmp/systemctl"
install_playwright alice false
no "settled rerun: no second disable" called "disable --now playwright-mcp@alice.service"
no "settled rerun: not re-enabled" called "enable --now playwright-mcp@alice.service"

# --- an entry the user chose themselves is left alone ------------------------
reset
printf '#!/bin/sh\n' > "$TL_BROWSER_BIN"; chmod +x "$TL_BROWSER_BIN"
echo "stdio npx @playwright/mcp@latest" > "$MCP_STATE"
install_playwright alice false
eq "own entry: untouched" "stdio npx @playwright/mcp@latest" "$(entry)"
no "own entry: no switch recorded" test -e "$since"
ok "own entry: shared server kept" called "enable --now playwright-mcp@alice.service"

# --- no entry at all, tl-browser installed: stdio straight away --------------
reset
printf '#!/bin/sh\n' > "$TL_BROWSER_BIN"; chmod +x "$TL_BROWSER_BIN"
install_playwright alice false
eq "fresh user: stdio entry" "stdio $TL_BROWSER_BIN" "$(entry)"
ok "fresh user: switch recorded" test -s "$since"
ok "fresh user with no sessions: shared server not started" called "is-enabled --quiet playwright-mcp@alice.service"
no "fresh user with no sessions: no enable" called "enable --now playwright-mcp@alice.service"

# --- parked users keep the existing behaviour --------------------------------
reset
printf '#!/bin/sh\n' > "$TL_BROWSER_BIN"; chmod +x "$TL_BROWSER_BIN"
install_playwright alice true
ok "parked: shared server disabled" called "disable --now playwright-mcp@alice.service"
ok "parked: snapshot timer disabled" called "disable --now playwright-snapshot-refresh@alice.timer"
no "parked: snapshot timer not enabled" called "enable --now playwright-snapshot-refresh@alice.timer"

# --- dry run mutates nothing --------------------------------------------------
reset
echo "http http://localhost:8933/mcp" > "$MCP_STATE"
printf '#!/bin/sh\n' > "$TL_BROWSER_BIN"; chmod +x "$TL_BROWSER_BIN"
export DRY_RUN=1
run() { echo "[dry-run] $*" >> "$tmp/log"; }
install_playwright alice false >/dev/null
eq "dry run: entry unchanged" "http http://localhost:8933/mcp" "$(entry)"
no "dry run: no switch recorded" test -e "$since"

# --- playwright_stdio_settled on its own -------------------------------------
now="$(date +%s)"
echo "$(( now - 100 ))" > "$since"
PS_OUT=""
ok "settled: no claude running" playwright_stdio_settled alice "$since"
PS_OUT="     50 claude"
ok "settled: claude started after the switch" playwright_stdio_settled alice "$since"
PS_OUT="    500 claude"
no "unsettled: claude started before the switch" playwright_stdio_settled alice "$since"
PS_OUT="    500 node"
ok "settled: other old processes do not count" playwright_stdio_settled alice "$since"
echo "garbage" > "$since"
no "unsettled: unreadable switch time" playwright_stdio_settled alice "$since"
rm -f "$since"
no "unsettled: no switch recorded" playwright_stdio_settled alice "$since"

echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
