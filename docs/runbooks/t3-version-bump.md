# Runbook: t3 version — gated nightly tracker (freeze / revert / roll back)

t3 on the devvm **auto-tracks the `nightly` npm dist-tag** (Viktor, 2026-06-16,
risk explicitly accepted), via the daily `t3-autoupdate` timer. Every bump is
GATED so a bad nightly self-heals instead of repeating 2026-06-09. This reverses
the post-incident pin decision — read `2026-06-09-t3-nightly-autoupdate-auth-outage.md`
for why every guard below exists. t3 is still pre-1.0 and ships breaking changes
between builds; the gate is what makes auto-tracking safe.

## How the tracker gates each bump  (`scripts/t3-autoupdate.sh`)

1. **Freeze gate** — `/etc/t3-autoupdate.freeze` present (or `T3_PIN=<ver>` set) →
   hold at current, do nothing.
2. **Resolve + downgrade-guard** — `npm view t3@nightly version`; proceed only if
   the target is strictly newer than installed AND a `-nightly.` build (the tag is
   mutable and can point backward).
3. **Pre-bump backup** — online `VACUUM INTO` of every user's `state.sqlite` to
   `/var/backups/t3-state/<u>/state-prebump-<ver>-<ts>.sqlite` (runs AS the owner;
   never stops a serve). Rollback is then a RESTORE, not sqlite surgery.
4. **Install + health-check** — `npm i -g t3@<ver>`, then start a throwaway serve
   SEEDED WITH A COPY of wizard's real populated `state.sqlite` (scratch on
   `/var/tmp`, not the 2 GB tmpfs `/tmp`) so it exercises the forward MIGRATION
   (the 2026-06-09 failure class) + the real mint→exchange→`t3_session` pairing
   handshake. Fail → roll back binary to last-good, exit (no serve migrated yet →
   clean).
5. **Canary rollout** — restart IDLE instances one at a time, verifying pairing
   through the real dispatch after each. First failure → roll back binary +
   restore that user's DB from the pre-bump backup + **self-freeze** (touch the
   freeze file) so it cannot re-flap onto bad builds. Active-agent instances are
   DEFERRED (never killed) and migrate on their next idle restart.
6. **Last-good** — advanced to the new version only on full success
   (`/var/lib/t3-autoupdate/last-good`); it is the rollback target.

Detection backstop (real-user pairing failures / endpoint fallback): the dispatch
logs every outcome (`paired user=.. endpoint=.. fallback=..`, plus `mint/pairing
... failed`) → Loki alerts `T3PairingBroken` / `T3PairFallbackHigh` /
`T3AutoUpdateRolledBack` / `T3AutoUpdateRollbackFailed` / `T3AutoUpdateFrozen` →
Alertmanager → Slack.

## Idle migrator — draining deferrals  (`scripts/t3-migrate-idle.sh`)

Step 5 DEFERS any instance with an active agent, recording `/var/lib/t3-autoupdate/deferred/<user>` (= the target version). Without a drainer, a user busy at every 04:00 window never migrates and their client shows *"Client and server versions differ"* for days. `t3-migrate-idle.timer` (overnight, every 20 min 01:00–05:40) drains those markers:

- Per marker: skip + clear if the unit is gone or was already restarted *after* the deferral; otherwise restart the still-stale `t3-serve@<u>` onto the current binary **only when that user is idle** — `state.sqlite` shows zero `active_turn_id` (no in-flight turn) AND ≥ `T3_MIGRATE_QUIET_SECONDS` (default 900 = 15 min) since the last thread activity — then verify pairing and clear the marker. **Fail-closed:** any query/parse doubt → skip, retry next tick.
- It restarts via the SAME `safe_restart_unit` the daily canary uses (sourced `t3-safe-restart.sh`: backup → restart → verify → recover). The shared `/etc/t3-autoupdate.freeze` halts it too.
- **Force / preview:**
  ```bash
  sudo systemctl start t3-migrate-idle.service           # run a drain pass now (still idle-gated)
  sudo env T3_DRY_RUN=1 /usr/local/bin/t3-migrate-idle   # log decisions, act on nothing
  ```
- **Rare-tail failure:** if a deferred user's forward migration fails at idle restart (already gated against a copy of their real DB at install), `safe_restart_unit` restores their DB + freezes + alerts. The binary rollback is a no-op (the build was already accepted, so other users are unaffected), but that user's serve may crashloop on the restored DB until the freeze is cleared and the build investigated (manual rollback below).

## Operations

**Freeze / revert (stop tracking right now — the fast "make it stop"):**
```bash
sudo touch /etc/t3-autoupdate.freeze     # holds at the current build; next run is a no-op + fires T3AutoUpdateFrozen
sudo rm -f /etc/t3-autoupdate.freeze     # resume tracking
```

**Pin to an exact version (instead of tracking nightly):** set `T3_PIN=<ver>` in
the unit environment (or the `scripts/t3-autoupdate.sh` default) — the tracker
enforces it and stops following nightly. Keep in sync with `setup-devvm.sh`.

**Preview the current nightly without touching anything (no global change, no restarts):**
```bash
sudo T3_DRY_RUN=1 /usr/local/bin/t3-autoupdate   # installs candidate to a temp prefix, runs the full gate, reports PASS/FAIL
```

**Force a run now (instead of waiting for 04:00):**
```bash
sudo systemctl start t3-autoupdate.service   # runs in its own cgroup, isolated from the t3-serve@ instances it manages
```

## What a bump touches (still true)

1. **Pairing API** — t3 renamed `POST /api/auth/bootstrap` → `/api/auth/browser-session`
   in 0.0.25. `t3-dispatch` is version-agnostic (`pairEndpoints` in
   `scripts/t3-dispatch/main.go` tries browser-session, falls back to bootstrap).
   If a future build renames it AGAIN, the health-check + canary fail the bump and
   self-freeze — then add the new path to `pairEndpoints`, rebuild + redeploy the
   dispatch, and clear the freeze.
2. **Schema** — 0.0.25+ migrate every `~/.t3/userdata/state.sqlite` FORWARD — a
   **one-way door**. A binary downgrade alone does NOT roll it back; you must
   restore the DB. The tracker does this automatically on a canary failure; do it
   by hand (below) if a problem surfaces *after* a successful bump.

## Manual rollback (problem surfaces after a bump the gate let through)

```bash
GOOD=$(cat /var/lib/t3-autoupdate/last-good)   # or the known-good version you want
sudo touch /etc/t3-autoupdate.freeze           # stop the tracker FIRST
sudo npm i -g "t3@$GOOD"
# Restore + restart each user's serve. The wizard/admin instance: run this from
# OUTSIDE its own t3 session (stopping the serve you're running inside kills you);
# or just let it pick up $GOOD on its next natural restart.
for u in $(awk -F= '!/^[[:space:]]*#/&&NF==2{gsub(/ /,"",$2);print $2}' /etc/ttyd-user-map | sort -u); do
  bak=$(sudo ls -1t /var/backups/t3-state/$u/state-prebump-* 2>/dev/null | head -1)
  [ -n "$bak" ] || continue
  sudo systemctl stop t3-serve@$u
  sudo install -o "$u" -g "$u" -m600 "$bak" /home/$u/.t3/userdata/state.sqlite
  sudo rm -f /home/$u/.t3/userdata/state.sqlite-wal /home/$u/.t3/userdata/state.sqlite-shm
  sudo systemctl start t3-serve@$u
done
```

## Verify (any user pairs cleanly through the dispatch)

```bash
for u in vbarzin emil.barzin ancaelena98; do
  curl -sI -H "X-authentik-username: $u" http://10.0.10.10:3780/ | grep -iE 'HTTP/|set-cookie: t3_session'
done   # each must be 302 + t3_session
t3 --version
```

(The 2026-06-09 incident had no pre-bump backup, so rollback meant per-user sqlite
surgery. The tracker now takes a guaranteed pre-bump snapshot — rollback is a restore.)
