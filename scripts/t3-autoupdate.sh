#!/usr/bin/env bash
# Track the latest t3 nightly — with a health-check + auto-rollback (lesson from
# the Keel auto-update incidents: never blindly trust a new build) and idle-only
# restarts (never kill an in-flight coding session). Runs as root via the unit.
set -uo pipefail
LOG() { logger -t t3-autoupdate "$*"; echo "t3-autoupdate: $*"; }

ver() { t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//'; }

before=$(ver); LOG "current: ${before:-unknown}"
npm i -g t3@nightly >/dev/null 2>&1 || { LOG "npm install failed; staying on ${before:-current}"; exit 0; }
after=$(ver)

if [[ -z "$after" || "$after" == "$before" ]]; then
  LOG "already latest (${before:-?}); nothing to do"; exit 0
fi
LOG "installed $after (was $before); health-checking…"

# Health-check the NEW binary on a throwaway port/base-dir before trusting it.
SMOKE_PORT=3799; SMOKE_DIR=$(mktemp -d)
t3 serve --host 127.0.0.1 --port "$SMOKE_PORT" --base-dir "$SMOKE_DIR" >/dev/null 2>&1 &
smoke=$!; ok=0
for _ in $(seq 1 15); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SMOKE_PORT/" 2>/dev/null)" == "200" ]] && { ok=1; break; }
  sleep 2
done
kill "$smoke" 2>/dev/null; wait "$smoke" 2>/dev/null; rm -rf "$SMOKE_DIR"

if [[ "$ok" != "1" ]]; then
  LOG "HEALTH-CHECK FAILED for $after — rolling back to $before"
  if [[ -n "$before" ]] && npm i -g "t3@$before" >/dev/null 2>&1; then
    LOG "rolled back to $before"
  else
    LOG "ROLLBACK FAILED — manual fix needed (t3 may be broken)"
  fi
  exit 1
fi
LOG "health OK; restarting idle instances"

# Restart only IDLE per-user instances; defer any with an active agent child.
for unit in $(systemctl list-units --type=service --state=running --no-legend 't3-serve@*' | awk '{print $1}'); do
  pid=$(systemctl show -p MainPID --value "$unit")
  if [[ -n "$pid" && "$pid" != 0 ]] && pgrep -aP "$pid" 2>/dev/null | grep -qiE 'claude|codex|opencode'; then
    LOG "deferring $unit (active agent) — updates next cycle when idle"
  else
    systemctl restart "$unit" && LOG "restarted $unit -> $after"
  fi
done
LOG "update complete: $after"
