# Post-Mortem: t3 Nightly Auto-Update (0.0.25) Migrated `state.sqlite` Forward → mint/pairing Broke for All Devvm Users

## Summary

The devvm t3 auto-updater (`t3-autoupdate.timer`) pulled the `t3@nightly`
build `0.0.25-nightly.20260608.497`. That build ran two forward schema
migrations on every per-user `~/.t3/userdata/state.sqlite` (renaming
`role`→`scopes` in `auth_pairing_links` + `auth_sessions`, adding
`proof_key_thumbprint`) **and** changed the bootstrap API. The result was a
binary-vs-schema mismatch that broke `t3-mint` (pairing-credential issuance)
for **all** users — every fresh login landed on the t3 pairing prompt instead
of an authenticated session.

## Impact

- **Who:** every devvm t3 user — `wizard` (Viktor), `emo`, `ancamilea`.
- **What:** `t3 auth pairing create` failed (`AuthControlPlaneError:
  Failed to create pairing link` → `PersistenceSqlError` on
  `auth_pairing_links`), so `t3-dispatch` auto-pair returned 500/502 and the
  browser showed the pairing prompt. Existing *already-authenticated* sessions
  kept working (validated against `auth_sessions`, not the pairing path).
- **When:** ~13:56 (bad nightly installed) → ~15:16 (all users verified 302).
- **Trigger of the report:** Anca could not log in ("gets the pair prompt,
  session broken").

## Timeline (devvm clock)

- **13:56** — `t3-provision-users` step 5b ran `systemctl enable --now
  t3-autoupdate.timer`. The timer is `OnCalendar=04:00 … Persistent=true`;
  `--now` + a missed 04:00 schedule fired the daily job **immediately**.
- **13:56** — updater installed `t3@nightly` = `0.0.25-nightly.20260608.497`
  (was `0.0.24`). The `GET / → 200` health-check **passed** (it never
  exercises mint/bootstrap), so no auto-rollback. It restarted *idle* serves
  (emo) onto 0.0.25 and deferred *active* ones (wizard, ancamilea).
- **~14:38** — `t3-mint` (now global 0.0.25) ran migrations 31
  (`AuthAuthorizationScopes`) + 32 (`AuthPairingProofKeyThumbprint`) against
  each `state.sqlite` it touched → schemas moved to "level 32".
- **~14:40** — first recovery action rolled the **binary** back to `0.0.24`.
  This did **not** help: the DBs were still at level 32, so the level-30
  binary's INSERT hit `no column named role` / `NOT NULL constraint failed:
  scopes`. (Downgrading a binary after a forward migration is not a rollback.)
- **~15:01–15:16** — diagnosed the binary-vs-schema mismatch, confirmed
  `0.0.25` *stable* is **also** dispatch-incompatible (auto-pair → 502, the
  bootstrap API moved), pinned to `0.0.24`, reset the two new users' disposable
  DBs, surgically reverted wizard's two auth tables to level 30. All three
  users verified 302 + `Set-Cookie: t3_session`.

## Root Cause

Three compounding factors:

1. **Auto-tracking a pre-1.0 tool's nightly.** `t3-autoupdate.sh` ran
   `npm i -g t3@nightly`. t3 ships breaking schema-migration and bootstrap-API
   changes between builds; our `t3-dispatch` (Go) speaks a fixed bootstrap
   contract (`POST /api/auth/bootstrap {"credential":…}` → `Set-Cookie`).
2. **`enable --now` on a `Persistent=true` timer.** The provisioner's
   re-assertion of the timer didn't just *arm* the schedule — it fired the
   missed daily job on the spot, mid-afternoon, with users active.
3. **A health-check that proves nothing about auth.** The smoke test only
   probes `GET / → 200`. The 0.0.25 server answers 200 while its pairing/mint
   path is incompatible, so the "auto-rollback on bad build" never triggered.

Forward migrations + a binary downgrade = a DB the old binary can't write.
`state.sqlite` also holds the precious projection tables (session history), so
a blanket "delete and re-pair" was only safe for the brand-new users.

## Detection

User report (Anca on the pairing prompt). No alert fired — the auto-updater's
own health-check is the only automated gate and it passed. **Gap:** nothing
monitors the end-to-end pairing flow.

## Fixes & Mitigations

### 1. Pin t3, stop tracking nightly (DONE)

`infra/scripts/t3-autoupdate.sh` is now a **pinned-version enforcer**:
`T3_PIN="${T3_PIN:-0.0.24}"`, `npm i -g "t3@$T3_PIN"`. It re-asserts the pin
(a no-op when already correct) instead of chasing nightly. Unit `Description`s
updated. To move the pin: bump `T3_PIN` **and first** verify `t3-dispatch`'s
bootstrap flow against the new build (`curl` the dispatch → expect 302 +
`Set-Cookie: t3_session`).

### 2. Drop `--now` from the provisioner (DONE)

`infra/scripts/t3-provision-users.sh` step 5b now runs `systemctl enable
t3-autoupdate.timer` (no `--now`) — it arms the 04:00 schedule without firing a
missed job immediately.

### 3. Pinned install at machine setup (DONE)

`infra/scripts/workstation/setup-devvm.sh` installs `t3@$T3_PIN` directly, so a
fresh box has the pinned t3 immediately rather than depending on the enforcer's
first run.

### 4. Recovery actions taken on the host (DONE)

- Global `t3` rolled to `0.0.24`; enforcer redeployed + timer re-enabled
  (verified the enforcer is a no-op at the pin).
- New users (`emo` 0 threads, `ancamilea` 1 trivial thread): `state.sqlite`
  parked aside; serve restarted → fresh level-30 DB.
- `wizard` (96 threads, and the serve hosting the recovery session — cannot be
  restarted): the two auth tables were atomically rebuilt to the level-30
  schema (copied from a fresh DB) and migration records 31/32 removed.
  `auth_sessions` had 0 rows and the 0.0.24 serve never reads `scopes`, so the
  live session and all projection history were untouched. Backup:
  `/home/wizard/.t3/userdata/auth-backup-*.sql`.

### 5. End-to-end pairing health-check (DEFERRED)

The smoke test should exercise mint→bootstrap→cookie, not just `GET /`. Not
done here (the pin makes it moot for the known-good build); needed before the
enforcer is ever pointed at a new version. A blackbox probe on the dispatch
auto-pair (expect 302 + `t3_session`) would have alerted within minutes.

## Lessons

- **Don't auto-track a pre-1.0 tool's nightly.** Pin to a known-good,
  contract-verified build; upgrades are a deliberate, tested act.
- **`enable --now` on a `Persistent=true` timer fires the missed job now.**
  Use plain `enable` to arm a schedule without a surprise immediate run.
- **A liveness probe (`GET /`) is not a readiness/correctness probe.** If a
  feature (auth/pairing) can break while `/` stays 200, the health-check must
  exercise that feature or it gives false confidence.
- **A binary downgrade is not a schema rollback.** Once a forward migration
  runs, the data is migrated; the old binary now mismatches its own DB.
- **Separate disposable state from precious state before resetting.** t3's
  `state.sqlite` mixes ephemeral auth (`auth_pairing_links`, `auth_sessions`)
  with precious history (`projection_*`); surgical table-level repair
  preserved 8k+ messages that a blanket reset would have destroyed.

## References

- `infra/scripts/t3-autoupdate.sh` (pinned enforcer), `.service`, `.timer`
- `infra/scripts/t3-provision-users.sh` step 5b
- `infra/scripts/workstation/setup-devvm.sh` step 2b
- `infra/.claude/reference/service-catalog.md` (t3 serving layer)
- Backup of wizard's pre-repair auth tables: `/home/wizard/.t3/userdata/auth-backup-*.sql`
