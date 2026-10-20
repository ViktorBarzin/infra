#!/usr/bin/env bash
# t3 GATED RELEASE TRACKER (daily, via t3-autoupdate.timer).
#
# t3 is pre-1.0 and ships breaking schema-migration + pairing-API changes between
# builds. On 2026-06-09 a blind `npm i -g t3@nightly` migrated every ~/.t3
# state.sqlite FORWARD and moved the bootstrap API, breaking pairing for ALL users
# with no alert (post-mortem 2026-06-09-t3-nightly-autoupdate-auth-outage.md). We
# pinned in response.
#
# 2026-06-16 (Viktor's call, risk explicitly accepted): re-enable nightly tracking,
# but GATED so a bad build self-heals instead of breaking everyone.
#
# 2026-09-06 (Viktor: "t3 isn't critical anymore"): the track moves from
# `nightly` to `latest`. He wants every agent binary on this box at the latest
# version, and for t3 the LATEST RELEASE is the honest reading of that: the
# nightly tag is a stream of prereleases, and it is the one that keeps costing
# us. It caused the 2026-06-09 outage, and on the morning of 2026-09-06
# 0.0.39-nightly.20260906.1292 failed the pairing health-check and was rolled
# back to 0.0.38-nightly.20260831.1235 — the guards worked, but the box spent
# the churn for nothing. `latest` was 0.0.38 the same day, so this is a move
# forward, not a downgrade: a prerelease sorts BELOW its release.
#
# Every guard below stays exactly as it is. They were built for a channel that
# breaks things, and a release channel is not a reason to trust a build
# unverified.
#
# The script follows the `latest` npm dist-tag (T3_TRACK) under these guards:
#   - freeze switch (/etc/t3-autoupdate.freeze) + optional hard pin (T3_PIN) for
#     instant manual revert; a canary failure also self-freezes;
#   - downgrade-guard (the nightly tag is mutable — never move backward);
#   - versioned install (2026-10-19): each build gets its own npm prefix under
#     /usr/local/lib/t3/<ver>, is gated from there, and only then is /usr/bin/t3
#     swapped to it with one rename. Running serves never see their files change
#     (the old `npm i -g` made them answer 404 mid-install, 2026-09-28), and a
#     rollback is a symlink swap back to last-good;
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
T3_TRACK="${T3_TRACK:-latest}"             # npm dist-tag to follow (latest | nightly)
T3_PIN="${T3_PIN:-}"                        # optional HARD pin to an exact version (disables tracking)
DRY_RUN="${T3_DRY_RUN:-0}"

LOG_TAG=t3-autoupdate
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

# is $1 a strictly-newer version than $2 (version-sort)?
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

mkdir -p "$STATE_DIR" 2>/dev/null || true

# ---- 0a. update lock: held for the whole run (install, canary, rollback) ---------
# t3-watchdog and t3-migrate-idle skip while it is held. Taken before the freeze
# gate so a recovery that froze while we waited is seen. Wait out a watchdog sweep
# or an idle drain; a second t3-autoupdate (timer + a person) gives up.
if ! take_update_lock "${T3_LOCK_WAIT:-1800}"; then
  LOG "skipping: $UPDATE_LOCK held by another t3 update, migration or watchdog sweep for ${T3_LOCK_WAIT:-1800}s"; exit 0
fi

# ---- 0b. freeze gate ------------------------------------------------------------
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

# ---- 2. downgrade + channel guard (a mutable dist-tag can point backward) ------
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
      LOG "WARN: pre-bump backup FAILED for $u ($(state_db "$u"))"
    fi
  done
  [ -n "$ADMIN_SEED" ] || ADMIN_SEED="$(ls -1t "$BACKUP_DIR"/*/"state-prebump-$target-"*.sqlite 2>/dev/null | head -1)"
}

# health_check, unit_busy, install_version, activate_version and rollback_binary
# live in the lib, shared with t3-watchdog and t3-migrate-idle.

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

# ---- 4. pre-bump backup, then install into the candidate's own prefix -----------
# Nothing a running serve uses changes here: the build goes to
# $T3_VERSIONS_DIR/<ver> and T3_LINK still points at the current one.
backup_all
if ! install_version "$target"; then
  LOG "npm install of t3@$target FAILED — staying on $current"; exit 0
fi

# ---- 5. gate the new build on a POPULATED-DB migration + pairing, THEN activate --
# The gate runs the candidate from its prefix before anything switches, so a
# failure leaves every user on $current. "rolled back" keeps T3AutoUpdateRolledBack firing.
if ! health_check "$(version_entry "$target")" "$ADMIN_SEED"; then
  LOG "health gate failed for $target — rolled back (never activated; $current stays live)"; exit 1
fi
if ! activate_version "$target"; then
  LOG "could not point $T3_LINK at $target — staying on $current"; exit 1
fi
installed="$(ver)"
[ "$installed" = "$target" ] || { LOG "post-activate version is $installed, expected $target — rolling back"; rollback_binary; exit 1; }
LOG "health gate passed for $target and $T3_LINK now points at it; canary-restarting idle instances one at a time"

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
prune_versions "$target" "$last_good"
