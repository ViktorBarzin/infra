# t3 idle-migrate — graceful overnight restart of deferred t3-serve instances — design

- **Date:** 2026-06-21
- **Status:** designed 2026-06-21 (brainstorm) — not yet implemented
- **Owner:** Viktor (wizard)
- **Builds on:** the gated nightly tracker `t3-autoupdate` (re-enabled 2026-06-16, `scripts/t3-autoupdate.{sh,service,timer}`; design history in `docs/runbooks/t3-version-bump.md` + post-mortem `2026-06-09-t3-nightly-autoupdate-auth-outage.md`) and the per-user `t3-serve@<user>` systemd instances (`scripts/t3-serve@.service`).

## Goal

When `t3-autoupdate` **defers** a user's `t3-serve` restart because that user has an active agent at the daily 04:00–05:00 window, the user's running server keeps executing its start-time t3 version indefinitely — their client (which tracks the freshly-installed global binary) then shows *"Client and server versions differ."* For a user who is busy at every daily window (wizard: long-lived/AFK sessions overnight), the deferral never resolves and the skew persists for days.

Add a **small, idle-gated overnight job that drains those deferrals**: restart a deferred `t3-serve@<user>` onto the current binary **only when nothing is actively working** in that instance, so the migration happens during a genuine quiet gap rather than killing in-flight agent turns.

## Background — why the skew persists (root cause, verified 2026-06-21)

- All `t3-serve@<user>` instances share ONE global `/usr/bin/t3` (→ `/usr/lib/node_modules/t3`). `t3-autoupdate` installs a new nightly to that single binary, health-gates it against a **copy** of wizard's populated `state.sqlite`, then **canary-restarts idle instances one at a time**, verifying pairing after each (`scripts/t3-autoupdate.sh` step 6).
- Its idle check is coarse — `unit_busy()`:
  ```sh
  pid=$(systemctl show -p MainPID --value "$unit")
  pgrep -aP "$pid" | grep -qiE 'claude|codex|opencode'
  ```
  i.e. "does the server have any `claude`/`codex`/`opencode` **child**?" But `t3 serve` keeps one such child alive per **open** session, even one idle awaiting input. Live snapshot 2026-06-21: wizard had **5 `running` provider sessions** (= 5 `claude` children) but only **3 mid-turn**, plus **89 `ready` (open-idle)** threads. So `unit_busy` is true whenever any tab is open → wizard is deferred at every window.
- The job runs **once daily** (`OnCalendar=*-*-* 04:00:00`, `RandomizedDelaySec=1h`, `Persistent` deliberately omitted) and **only acts on a version bump** (exits early if `installed == target`). So once the binary is already current, nothing re-triggers a restart of a still-stale running server until the *next* new nightly — and only if the user happens to be idle then.
- Confirmed in the logs: `t3-autoupdate: deferring t3-serve@wizard.service (active agent) — migrates on its next idle restart` on **both** Jun 20 and Jun 21 windows; wizard's server has been up since Jun 20 06:17 on `…20260620.605` while the binary + client are on `…20260621.613`.

## Decisions (from brainstorm 2026-06-21)

1. **"Safe to restart" = no turn in flight AND a quiet buffer.** Not "zero open sessions" (that would essentially never fire for wizard). Open-but-idle tabs are acceptable to drop — t3 persists thread history in `state.sqlite` and the client reconnects/resumes (the daily job already restarts idle instances routinely; restart→resume is the exercised path). To verify during implementation: the user-facing resume after a server restart.
2. **Cadence: overnight window only.** Frequent checks within a fixed overnight window; never disconnects tabs during the working day. Migrates within ~1 night of a build landing.
3. **Scope: all `t3-serve@<user>`, self-limiting.** The job restarts only an instance that actually *owes* a migration (a deferral marker exists). Users already migrated at the daily window have no marker → no-op. No hardcoded per-user logic.
4. **Approach C: extract a shared safe-restart helper, reuse from both jobs.** One audited copy of the dangerous backup→restart→verify→recover logic; the new job adds only *scheduling + gating*.

## Constraints (load-bearing)

1. **The binary is global; migrations are forward-only and per-user-DB.** You cannot keep one user on the old version while others run the new one. A real-user forward-migration failure therefore means the build is unsafe for a real user → the only consistent recovery is the daily job's existing one (restore that user's DB + roll the **global** binary back to last-good + freeze + alert). This is a rare tail (the build was already migration-gated against a copy of wizard's real DB at install time), but the idle path must not invent a weaker recovery.
2. **Per-user secret boundary.** A user's `~/.t3/userdata/state.sqlite` is mode 600 and may not be read as another user. The job runs as root (system service) but reads each user's DB **as that user** via `runuser -u <user> -- sqlite3 …` (the pattern `backup_all` already uses), read-only (`mode=ro`) so it never locks the live WAL.
3. **Fail closed.** Any uncertainty about whether an instance is safe to restart (DB locked/busy/unreadable, query error, unparseable timestamp) → treat as *not safe*, skip this tick, retry in 20 min. Never restart on doubt.
4. **Do not change the daily job's gated-install behavior.** The step-6 extraction must be behavior-preserving; health-gate, canary, downgrade-guard, freeze, and rollback stay exactly as today.
5. **Infra-as-code via the devvm installer.** Sources live in `scripts/`; deployment is `scripts/workstation/setup-devvm.sh` (the devvm is hand-managed VM 102 — no Terraform apply). Shared-devvm deploy takes a presence claim.

## Design

### Components

Four new files in `scripts/` + a one-line addition to the existing job:

1. **`scripts/t3-safe-restart.sh`** — shared library, sourced (not executed). Holds the per-unit "dangerous" routine extracted from `t3-autoupdate.sh` step 6 as `safe_restart_unit <unit> <target>`:
   pre-restart `VACUUM INTO` backup (as the owner) → `systemctl restart` → poll `verify_pairing` (15×2s ≈ 30s) → on failure: restore that user's DB from the pre-restart backup, `rollback_binary` to last-good, `touch $FREEZE_FILE`, log+alert. The shared helpers it needs (`LOG`, `ver`, `osusers`, `ak_for`, `verify_pairing`, `prebump_of`, `rollback_binary`, `DISPATCH`/`BACKUP_DIR`/… config) move into the lib too. Installed to `/usr/local/lib/t3-safe-restart.sh`.
   **Contract:** returns `0` on verified success, **non-zero** after performing recovery+freeze on failure. This is the one non-verbatim change to step-6 logic — today it `exit 1`s inline; the extracted function `return`s instead so the *caller* decides (the daily job `exit 1`s on non-zero exactly as today; the idle job `break`s). Behavior is otherwise identical.

2. **`scripts/t3-migrate-idle.sh`** — the new job (scheduling + gating only). Installed to `/usr/local/bin/t3-migrate-idle`. Sources the lib; per tick, drains the deferral directory (control flow below).

3. **`scripts/t3-migrate-idle.service`** — `Type=oneshot`, `ExecStart=/usr/local/bin/t3-migrate-idle`. (No `EnvironmentFile` needed; env-overridable knobs have defaults.)

4. **`scripts/t3-migrate-idle.timer`** — overnight window, frequent checks:
   ```ini
   [Timer]
   OnCalendar=*-*-* 01..05:00/20      # fires 01:00,01:20,…,05:40; none at/after 06:00. System TZ (UTC) — tune the window.
   Persistent=false                    # never replay a missed migrate-restart at an unpredictable time
   RandomizedDelaySec=120
   ```

5. **One-line edit to `t3-autoupdate.sh`** — in the existing defer branch, *also record* the deferral:
   ```sh
   LOG "deferring $unit (active agent) — migrates on its next idle restart"
   mkdir -p "$DEFER_DIR" 2>/dev/null; printf '%s\n' "$target" > "$DEFER_DIR/$u"   # NEW
   deferred=$((deferred+1)); continue
   ```
   where `DEFER_DIR=/var/lib/t3-autoupdate/deferred`. This is the *only* behavioral change to the scarred script beyond the verbatim step-6 extraction.

### Why a deferral marker (not version-introspection)

The marker makes "which instances owe a restart" **exact** and decouples it from the binary-is-current problem — the daily job already *knows* it deferred wizard, so it records that fact. The idle job drains the directory; the version string in the marker is informational (a restart always picks up whatever binary is current). The marker is removed only after the restart's pairing is verified.

### Control flow of `t3-migrate-idle` (per tick)

```
for marker in $DEFER_DIR/*:                       # nothing deferred → no-op
    user = basename(marker); unit = t3-serve@<user>.service
    [ unit is an active running service ] or { rm marker; continue }     # gone
    if unit ActiveEnterTimestamp > mtime(marker):  rm marker; continue   # already restarted (manual/other) → just clear
    if not safe_to_restart(user):                  continue              # mid-turn or not quiet → try next tick
    target = contents(marker)
    if safe_restart_unit(unit, target):            rm marker             # success: verified on new binary
    else:                                          # helper already restored DB + rolled back binary + froze + alerted
        break                                      # frozen: stop draining; a human investigates
```

### `safe_to_restart(user)` — the gate

Single read-only query, run as the user:

```sh
runuser -u "$user" -- sqlite3 "file:/home/$user/.t3/userdata/state.sqlite?mode=ro" "
  SELECT
    (SELECT count(*) FROM projection_thread_sessions WHERE active_turn_id IS NOT NULL),
    CAST((julianday('now')
          - julianday(replace(replace(max(updated_at),'T',' '),'Z',''))) * 86400 AS INT)
  FROM projection_thread_sessions;"
```

- Column 1 = **active turns**; must be `0`. (`active_turn_id` is set exactly while a turn runs — verified 2026-06-21.)
- Column 2 = **idle seconds** = now − most-recent thread activity. Must be `≥ QUIET_SECONDS` (default **900** = 15 min, env-overridable). `updated_at` is ISO-8601 `…Z`; `datetime('now')`/`julianday('now')` are UTC, so normalizing `T`/`Z` away before `julianday()` keeps the arithmetic correct without depending on a newer SQLite's `Z` parsing.
- **NULL idle** (no threads at all) ⇒ safe. **Any error / non-numeric / nonzero exit** ⇒ not safe (constraint 3).

### Failure recovery

Delegated entirely to `safe_restart_unit` (the extracted, already-proven path): restore the user's DB from the pre-restart backup, roll the global binary back to last-good, `touch /etc/t3-autoupdate.freeze`, log+alert. The idle job then stops draining (the freeze halts both jobs until a human clears it) — see constraint 1 for why per-user divergence isn't an option.

### Observability

- Structured `logger -t t3-migrate-idle` lines; extend the existing `T3AutoUpdate*` Loki ruler/alerts to also match this tag. Success → one line: `migrated t3-serve@wizard → <target> (idle restart; idle 47m)`. Failure → reuses the daily job's freeze+alert.
- **Recommended (optional):** a Pushgateway gauge for **deferral-marker age** + an alert if a marker survives **> 3 days** — passive visibility into "busy every night for 3 days," *not* the auto-escalation/daytime-widening that was explicitly de-scoped.

### Delivery

- Wire into `scripts/workstation/setup-devvm.sh` alongside the existing units:
  - `install -m 0644 "$SCRIPTS/t3-safe-restart.sh" /usr/local/lib/t3-safe-restart.sh`
  - `install -m 0755 "$SCRIPTS/t3-migrate-idle.sh" /usr/local/bin/t3-migrate-idle`
  - add `t3-migrate-idle.service t3-migrate-idle.timer` to the unit-install loop (→ `/etc/systemd/system/`)
  - add `t3-migrate-idle.timer` to the `systemctl enable --now` list
- `homelab claim host:devvm --purpose "deploy t3-migrate-idle units"` before the install + enable on the shared devvm.
- No Terraform (hand-managed VM 102).

## Testing

- **TDD on the gating core (`bats`)** against fixture `state.sqlite` files: active turn → unsafe; idle-but-recent (< QUIET) → unsafe; idle + quiet → safe; empty DB → safe; locked/garbage DB / sqlite error → unsafe (fail-closed); marker drain: unit started after marker → clear+skip, before → eligible.
- **`T3_DRY_RUN=1`** mode logs `would migrate <unit> → <target>` without acting. Roll out in dry-run first; confirm it flags wizard's server at a real overnight idle moment; then enable live.
- **Step-6 extraction is behavior-preserving** — validate the daily job's decisions are unchanged via a dry-run diff before/after the refactor.

## Out of scope (YAGNI)

- Daytime restarts / "around the clock" cadence (de-scoped: overnight only).
- Auto-escalation that widens to a daytime attempt after N stale nights (de-scoped; the optional marker-age alert covers visibility).
- Per-user opt-out file (not needed — the job is self-limiting via markers).
- Any change to how `t3-autoupdate` *installs/gates* a build.

## Open questions

None outstanding from the brainstorm. Two items to **verify during implementation** (not blockers): (a) user-facing session resume after a `t3-serve` restart; (b) the devvm's `sqlite3` parses the normalized timestamp as expected (the `replace()` normalization is the safeguard).
