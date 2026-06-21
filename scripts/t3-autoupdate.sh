#!/usr/bin/env bash
# t3 GATED NIGHTLY TRACKER (daily, via t3-autoupdate.timer).
#
# t3 is pre-1.0 and ships breaking schema-migration + pairing-API changes between
# builds. On 2026-06-09 a blind `npm i -g t3@nightly` migrated every ~/.t3
# state.sqlite FORWARD and moved the bootstrap API, breaking pairing for ALL users
# with no alert (post-mortem 2026-06-09-t3-nightly-autoupdate-auth-outage.md). We
# pinned in response.
#
# 2026-06-16 (Viktor's call, risk explicitly accepted): re-enable nightly tracking,
# but GATED so a bad nightly self-heals instead of breaking everyone. This script
# now follows the `nightly` npm dist-tag (T3_TRACK) under these guards:
#   - freeze switch (/etc/t3-autoupdate.freeze) + optional hard pin (T3_PIN) for
#     instant manual revert; a canary failure also self-freezes;
#   - downgrade-guard (the nightly tag is mutable — never move backward);
#   - pre-bump per-user state.sqlite backup BEFORE install (rollback => restore,
#     not sqlite surgery), via the same online VACUUM INTO as t3-backup-state;
#   - a health-check that seeds a throwaway instance with a COPY of a real
#     POPULATED state.sqlite, so it exercises the forward MIGRATION (the actual
#     2026-06-09 failure class) + the real pairing handshake before trusting a build;
#   - canary rollout: restart idle instances ONE AT A TIME, verifying pairing
#     through the real dispatch after each, and roll back (binary + that user's DB)
#     + self-freeze on the first failure — active-agent instances are deferred,
#     never killed (deferred instances are recorded for t3-migrate-idle to drain);
#   - rollback target is the recorded LAST-GOOD build, not "whatever was installed".
# Detection backstop (real-user pairing failure/fallback) lives in the dispatch
# logs + Loki alerts (T3PairingBroken / T3PairFallbackHigh / T3AutoUpdate*).
# To stop tracking: `sudo touch /etc/t3-autoupdate.freeze` (or set T3_PIN=<ver>).
# Full procedure + manual rollback: docs/runbooks/t3-version-bump.md.
set -uo pipefail

# ---- autoupdate-specific config (shared config + helpers come from the lib) -----
T3_TRACK="${T3_TRACK:-nightly}"            # npm dist-tag to follow (nightly | latest)
T3_PIN="${T3_PIN:-}"                        # optional HARD pin to an exact version (disables tracking)
SMOKE_PORT="${T3_SMOKE_PORT:-3799}"
DRY_RUN="${T3_DRY_RUN:-0}"
TMPROOT="${T3_TMPDIR:-/var/tmp}"           # health-check scratch on DISK — /tmp is a 2G tmpfs and a populated state.sqlite (~hundreds of MB) overflows it

LOG_TAG=t3-autoupdate
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

# is $1 a strictly-newer version than $2 (version-sort)?
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- 0. freeze gate -------------------------------------------------------------
if [ -e "$FREEZE_FILE" ]; then
  LOG "FROZEN: $FREEZE_FILE present — holding at $(ver), not tracking $T3_TRACK"; exit 0
fi

current="$(ver)"
[ -n "$current" ] || { LOG "cannot read current t3 version — aborting (is t3 installed?)"; exit 0; }
[ -s "$LAST_GOOD_FILE" ] || echo "$current" >"$LAST_GOOD_FILE"   # seed last-good on first run
last_good="$(tr -d '[:space:]' <"$LAST_GOOD_FILE" 2>/dev/null)"
[ -n "$last_good" ] || last_good="$current"

# ---- 1. resolve target ----------------------------------------------------------
if [ -n "$T3_PIN" ]; then
  target="$T3_PIN"
  LOG "T3_PIN=$T3_PIN set — enforcing pin (tracking disabled)"
else
  target="$(npm view "t3@$T3_TRACK" version 2>/dev/null | tail -1 | tr -d '[:space:]')"
  [ -n "$target" ] || { LOG "could not resolve t3@$T3_TRACK from npm — staying on $current"; exit 0; }
fi

[ "$target" = "$current" ] && { LOG "already on $T3_TRACK=$current; nothing to do"; exit 0; }

# ---- 2. downgrade + channel guard (mutable nightly tag can point backward) ------
if [ -z "$T3_PIN" ]; then
  newer "$target" "$current" || { LOG "resolved $T3_TRACK=$target is NOT newer than installed $current — refusing downgrade"; exit 0; }
  if [ "$T3_TRACK" = "nightly" ]; then
    case "$target" in *-nightly.*) : ;; *) LOG "resolved nightly target '$target' is not a nightly build — refusing"; exit 0;; esac
  fi
fi
LOG "candidate: $current -> $target (track=$T3_TRACK, last_good=$last_good, dry_run=$DRY_RUN)"

# ---- helpers: backup, health-check, rollback, restart-verify --------------------
# Online consistent per-user snapshot (run AS the owner so WAL stays owned; never
# stops the serve). Sets $ADMIN_SEED to wizard's backup for the migration health
# check. Mirrors t3-backup-state.sh. (backup_user lives in the shared lib.)
ADMIN_SEED=""
backup_all() {
  local u dst
  for u in $(osusers); do
    if dst="$(backup_user "$u")"; then
      LOG "pre-bump backup: $u -> $dst ($(stat -c%s "$dst" 2>/dev/null) bytes)"
      [ "$u" = "wizard" ] && ADMIN_SEED="$dst"
    else
      LOG "WARN: pre-bump backup FAILED for $u (/home/$u/.t3/userdata/state.sqlite)"
    fi
  done
  [ -n "$ADMIN_SEED" ] || ADMIN_SEED="$(ls -1t "$BACKUP_DIR"/*/"state-prebump-$target-"*.sqlite 2>/dev/null | head -1)"
}

# health_check <t3bin> [seed_db]: start a throwaway serve (seeded with a copy of a
# real populated DB if given, so the forward migration runs on real data), then do
# the real mint -> credential-exchange -> t3_session pairing handshake with the
# dispatch's endpoint fallback, and sniff the serve log for a migration failure.
health_check() {
  local t3bin="$1" seed="${2:-}" dir logf pid live=0 pair=0 migerr=0 cred ep hdr code seeded=fresh
  dir="$(mktemp -d -p "$TMPROOT")"; mkdir -p "$dir/userdata"; logf="$dir/serve.log"
  if [ -n "$seed" ] && [ -f "$seed" ]; then cp "$seed" "$dir/userdata/state.sqlite"; seeded=populated; fi
  "$t3bin" serve --host 127.0.0.1 --port "$SMOKE_PORT" --base-dir "$dir" >"$logf" 2>&1 &
  pid=$!
  for _ in $(seq 1 15); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SMOKE_PORT/" 2>/dev/null)" = "200" ] && { live=1; break; }
    sleep 2
  done
  if [ "$live" = "1" ]; then
    cred="$("$t3bin" auth pairing create --base-dir "$dir" --ttl 5m --json 2>/dev/null | tr -d '\n ' | sed -n 's/.*"credential":"\([^"]*\)".*/\1/p')"
    if [ -n "$cred" ]; then
      for ep in /api/auth/browser-session /api/auth/bootstrap; do
        hdr="$(curl -s -i --max-time 5 -X POST -H 'Content-Type: application/json' -d "{\"credential\":\"$cred\"}" "http://127.0.0.1:$SMOKE_PORT$ep" 2>/dev/null)"
        code="$(printf '%s' "$hdr" | sed -n '1s#.* \([0-9][0-9][0-9]\).*#\1#p')"
        [ "$code" = "404" ] && continue
        printf '%s' "$hdr" | grep -qi '^set-cookie:[[:space:]]*t3_session=' && pair=1
        break
      done
    fi
  fi
  grep -qiE 'migration failed|failed to migrate|no column named|NOT NULL constraint failed|PersistenceSqlError' "$logf" 2>/dev/null && migerr=1
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$live" = "1" ] && [ "$pair" = "1" ] && [ "$migerr" = "0" ]; then
    LOG "health OK ($seeded: live + pairing handshake + clean migration)"
    rm -rf "$dir"; return 0
  fi
  LOG "HEALTH-CHECK FAILED ($seeded: live=$live pair=$pair migerr=$migerr); serve log: $(tail -3 "$logf" 2>/dev/null | tr '\n' '|')"
  rm -rf "$dir"; return 1
}

# is this t3-serve@<unit> running an active agent (claude/codex/opencode)? never restart those.
unit_busy() {
  local unit="$1" pid; pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "0" ] && pgrep -aP "$pid" 2>/dev/null | grep -qiE 'claude|codex|opencode'
}

# ---- 3. DRY RUN: preview only (install candidate to temp prefix, gate it) -------
if [ "$DRY_RUN" = "1" ]; then
  LOG "DRY_RUN: would back up [$(osusers | tr '\n' ' ')]; testing candidate $target in a temp prefix (no global change, no restarts)"
  tmp="$(mktemp -d -p "$TMPROOT")"
  if npm i --prefix "$tmp" "t3@$target" >/dev/null 2>&1; then
    seed="$(ls -1t "$BACKUP_DIR/wizard/state-"*.sqlite 2>/dev/null | head -1)"   # reuse any existing backup as seed
    if health_check "$tmp/node_modules/.bin/t3" "$seed"; then LOG "DRY_RUN: candidate $target PASSED the gate"; else LOG "DRY_RUN: candidate $target FAILED the gate"; fi
  else
    LOG "DRY_RUN: npm could not fetch t3@$target"
  fi
  rm -rf "$tmp"; exit 0
fi

# ---- 4. pre-bump backup, then install -------------------------------------------
backup_all
if ! npm i -g "t3@$target" >/dev/null 2>&1; then
  LOG "npm install of t3@$target FAILED — staying on $current"; exit 0
fi
installed="$(ver)"
[ "$installed" = "$target" ] || { LOG "post-install version is $installed, expected $target — rolling back"; rollback_binary; exit 1; }

# ---- 5. gate the new binary on a POPULATED-DB migration + pairing ---------------
if ! health_check "$(command -v t3)" "$ADMIN_SEED"; then
  rollback_binary; exit 1   # nothing restarted yet -> binary rollback is clean
fi
LOG "health gate passed for $target; canary-restarting idle instances one at a time"

# ---- 6. canary rollout: idle instances one-by-one, verify pairing after each ----
restarted=0; deferred=0
for unit in $(systemctl list-units --type=service --state=running --no-legend 't3-serve@*' 2>/dev/null | awk '{print $1}'); do
  u="$(printf '%s' "$unit" | sed -n 's/^t3-serve@\(.*\)\.service$/\1/p')"; [ -n "$u" ] || continue
  if unit_busy "$unit"; then
    LOG "deferring $unit (active agent) — migrates on its next idle restart"
    mkdir -p "$DEFER_DIR" 2>/dev/null && printf '%s\n' "$target" >"$DEFER_DIR/$u"   # record for t3-migrate-idle
    deferred=$((deferred+1)); continue
  fi
  if safe_restart_unit "$unit" "$u"; then
    restarted=$((restarted+1))
    rm -f "$DEFER_DIR/$u" 2>/dev/null            # now current — clear any stale marker
  else
    exit 1                                        # frozen by safe_restart_unit — preserve today's behavior
  fi
done

# ---- 7. success: advance last-good ----------------------------------------------
echo "$target" >"$LAST_GOOD_FILE"
LOG "update complete: $target (restarted=$restarted deferred=$deferred); last_good now $target"
