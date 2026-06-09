#!/usr/bin/env bash
# Enforce the PINNED t3 version ($T3_PIN) across the box — NOT "latest/nightly".
# t3 is pre-1.0 and ships breaking schema-migration + bootstrap-API changes between
# builds that our t3-dispatch can't follow blind. 2026-06-09: a nightly auto-update
# (0.0.25) migrated every ~/.t3 state.sqlite forward (auth_pairing_links/auth_sessions
# role->scopes) AND changed the bootstrap API, breaking mint/pairing for ALL users.
# So we PIN; this unit just re-asserts the pin (a no-op when already correct) with a
# health-check + auto-rollback and idle-only restarts (never kill an in-flight session).
# To move the pin: bump T3_PIN AND first verify t3-dispatch's bootstrap flow against the
# new build (curl the dispatch -> expect 302 + Set-Cookie t3_session). See post-mortem
# 2026-06-09-t3-nightly-autoupdate-auth-outage.md.
# The health-check below exercises the REAL pairing handshake (mint -> credential
# exchange -> t3_session cookie), mirroring t3-dispatch's endpoint fallback — so a
# build that renames or breaks the pairing API fails the check and auto-rolls-back
# (closes the 2026-06-09 miss, where a GET / probe passed a pairing-broken build).
set -uo pipefail
T3_PIN="${T3_PIN:-0.0.24}"   # known-good, t3-dispatch-compatible (2026-06-09 post-mortem)
LOG() { logger -t t3-autoupdate "$*"; echo "t3-autoupdate: $*"; }

ver() { t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//'; }

before=$(ver); LOG "current: ${before:-unknown}; pin: $T3_PIN"
npm i -g "t3@$T3_PIN" >/dev/null 2>&1 || { LOG "npm install failed; staying on ${before:-current}"; exit 0; }
after=$(ver)

if [[ -z "$after" || "$after" == "$before" ]]; then
  LOG "already at pin $T3_PIN (${before:-?}); nothing to do"; exit 0
fi
LOG "re-pinned to $after (was $before); health-checking…"

# Health-check the NEW binary on a throwaway port/base-dir before trusting it.
# Gate 1 = liveness (GET / -> 200); Gate 2 = the REAL pairing handshake t3-dispatch
# performs (mint -> POST credential -> 200 + t3_session cookie), trying the same
# endpoint fallback. Gate 2 catches a bootstrap-API rename / pairing regression.
SMOKE_PORT=3799; SMOKE_DIR=$(mktemp -d)
t3 serve --host 127.0.0.1 --port "$SMOKE_PORT" --base-dir "$SMOKE_DIR" >/dev/null 2>&1 &
smoke=$!; live=0; pair_ok=0
for _ in $(seq 1 15); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SMOKE_PORT/" 2>/dev/null)" == "200" ]] && { live=1; break; }
  sleep 2
done
if [[ "$live" == "1" ]]; then
  cred=$(t3 auth pairing create --base-dir "$SMOKE_DIR" --ttl 5m --json 2>/dev/null \
          | tr -d '\n ' | sed -n 's/.*"credential":"\([^"]*\)".*/\1/p')
  if [[ -n "$cred" ]]; then
    for ep in /api/auth/browser-session /api/auth/bootstrap; do  # mirror t3-dispatch's fallback
      hdr=$(curl -s -i --max-time 5 -X POST -H 'Content-Type: application/json' \
              -d "{\"credential\":\"$cred\"}" "http://127.0.0.1:$SMOKE_PORT$ep" 2>/dev/null)
      code=$(printf '%s' "$hdr" | sed -n '1s#.* \([0-9][0-9][0-9]\).*#\1#p')
      [[ "$code" == "404" ]] && continue   # endpoint absent in this build — try the next
      printf '%s' "$hdr" | grep -qi '^set-cookie:[[:space:]]*t3_session=' && pair_ok=1
      break
    done
  fi
fi
kill "$smoke" 2>/dev/null; wait "$smoke" 2>/dev/null; rm -rf "$SMOKE_DIR"

if [[ "$live" != "1" || "$pair_ok" != "1" ]]; then
  LOG "HEALTH-CHECK FAILED for $after (live=$live pair=$pair_ok) — rolling back to $before"
  if [[ -n "$before" ]] && npm i -g "t3@$before" >/dev/null 2>&1; then
    LOG "rolled back to $before"
  else
    LOG "ROLLBACK FAILED — manual fix needed (t3 may be broken)"
  fi
  exit 1
fi
LOG "health OK (live + pairing handshake); restarting idle instances"

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
