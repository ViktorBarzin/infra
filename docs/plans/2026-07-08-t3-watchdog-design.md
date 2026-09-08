# t3-watchdog — auto-recovery for wedged t3-serve instances (design)

**Date:** 2026-07-08 · **Author:** wizard (approved by Viktor) · **Status:** approved

## Problem

`t3-serve@<user>` can survive a cgroup OOM event *wounded*: the runaway child dies
(by design — `OOMPolicy=continue`, unit file + post-mortem
`2026-06-22-devvm-mem-io-overload-containment.md`), but the surviving main process
sometimes drops its HTTP listener and goes silent while systemd still reports the
unit `active (running)`. `Restart=on-failure` never fires, so nothing recovers it.

Two production instances of the class:

- **2026-07-08**: two ~10G children OOM-killed inside `t3-serve@wizard` at 07:24/07:26;
  the main process degraded, dropped the `:3773` listener at ~18:58, and the instance
  was a listener-less zombie for ~2h until a manual `systemctl restart`. Graceful stop
  timed out; systemd needed SIGKILL.
- **2026-07-02** (post-mortem addendum): a hog plateaued in the then-existing
  `MemoryHigh` band and livelocked the whole cgroup — port *open* but the accept queue
  backed up and nothing answered. (The band was removed, but "port open, never
  answers" remains a reachable state.)

## Goal

Detect a wedged `t3-serve@<user>` (dead OR unresponsive listener while the unit is
`active`) and safe-restart it automatically within ~4 minutes, loudly.

## Non-goals (explicitly out of scope, Viktor 2026-07-08)

- Root-cause work: the ~10G agent-child balloon, wizard's 2.26G `state.sqlite`,
  and the 16G `MemoryMax` sizing are a separate future task.
- Changing `OOMPolicy=continue` / `Restart=` semantics on the unit (settled by the
  2026-06-10 outage + 2026-06-22 post-mortem; `kill` would nuke every session of a
  user whenever any one child OOMs, and misses the livelock class entirely).
- Upstream (app-level) `sd_notify`/`WatchdogSec` support — t3 is pre-1.0 nightly
  churn we don't control.

## Design

New sibling of `t3-migrate-idle`: **`scripts/t3-watchdog.sh`** (main-guarded, sources
`/usr/local/lib/t3-safe-restart.sh`) + **`t3-watchdog.service`** (oneshot) +
**`t3-watchdog.timer`** (`OnCalendar=minutely`, `Persistent` omitted like the
autoupdate timer). Installed + enabled by `scripts/workstation/setup-devvm.sh` like
its siblings. Runs as root on the devvm; no Terraform (hand-managed host), except
the alert rules below.

### Detection (each tick, per running `t3-serve@<user>` unit)

1. Enumerate running units exactly like `t3-autoupdate` step 6
   (`systemctl list-units --type=service --state=running 't3-serve@*'`).
2. Read `T3_PORT` from `/etc/t3-serve/<user>.env` (root-readable). No port → log,
   skip (provisioning problem, not a wedge).
3. Probe `http://127.0.0.1:$T3_PORT/` with `curl --max-time 10`; healthy = HTTP 200.
   Connection-refused catches the 07-08 class; the 10s timeout catches the 07-02
   livelock class.
4. Failure counting in `/run/t3-watchdog/<user>.fails` (tmpfs — resets on boot,
   which is correct: fresh boot = fresh grace). Healthy probe resets the counter.

### Gate (pure function, unit-tested)

Restart only when ALL hold:

- unit is `active` (an inactive/failed unit is systemd's job, not ours);
- unit uptime > **120s** (grace: don't count probes against a booting/migrating
  instance — the 06:01 restart today needed ~9s to bind, autoupdate restarts happen
  minutely-adjacent);
- **3 consecutive** failed probes (~3 min of confirmed wedge; single blips ignored);
- fewer than **3 watchdog restarts in the trailing 30 min** for this unit
  (ledger in `/run/t3-watchdog/<user>.restarts`). At the cap: log
  `WATCHDOG-EXHAUSTED`, stop acting on this unit until the window slides —
  restart evidently isn't curing it and a human must look.

**Deliberately NOT gated on** the idle/active-turn check (`gate_is_safe`) that
version migrations use: a dead or unresponsive port means every session on that
instance is already broken — there is nothing live to preserve by waiting. The 2h
zombie on 2026-07-08 is the counterfactual. Also **not gated on
`/etc/t3-autoupdate.freeze`**: freeze is *version* policy; the watchdog is
*availability* and re-execs the already-installed binary — it never changes
versions. (Contrast: `t3-migrate-idle` honours freeze because its whole purpose is
moving users onto a new build.)

### Action

1. `backup_user <user>` (online `VACUUM INTO`, works even with the serve dead —
   sqlite reads the file directly). **Backup failure logs a warning but does NOT
   block the restart**: availability wins, and `safe_restart_unit`'s recovery path
   degrades gracefully (`prebump_of` finds an older snapshot or skips restore).
   This intentionally differs from `t3-migrate-idle`'s fail-closed skip — there the
   instance is healthy and waiting costs nothing; here it is already down.
2. `safe_restart_unit <unit> <user>` from the shared lib, with
   `target = installed version` and `last_good` read from the state file — the
   same "idle path" semantics the 2026-06-21 idle-migrate design documented as
   load-bearing: pairing is verified through the real dispatch after the restart;
   on a restart that comes up broken the lib restores that user's DB, "rolls back"
   the binary (a no-op reinstall, since last-good == installed), **freezes the
   updater and alerts**. That freeze-on-failure is correct here too: a restart that
   lands broken means the installed build or the user's DB is bad — exactly what
   freeze+human is for.
3. On success: append to the restart ledger, log
   `WATCHDOG: restarted t3-serve@<user> (reason=<refused|timeout>, fails=3)`.

### Visibility

`logger -t t3-watchdog` → devvm journal → Loki `{job="devvm-journal",
identifier="t3-watchdog"}`. Two new rules in the existing T3 alert family
(`stacks/monitoring/modules/monitoring/loki.tf`):

- **T3WatchdogRestarted** (warning): `|~ "WATCHDOG: restarted"` count > 0 over 15m —
  the watchdog fired and recovered an instance; skim-worthy, self-healed.
- **T3WatchdogExhausted** (critical): `|~ "WATCHDOG-EXHAUSTED"` count > 0 over 15m —
  it gave up after 3 restarts/30m; instance is down and staying down without a human.

Additionally, the three existing `T3AutoUpdate{RolledBack,RollbackFailed,Frozen}`
rules currently filter `identifier="t3-autoupdate"` exactly, so a
freeze/rollback logged by any *other* caller of `t3-safe-restart.sh` is invisible
to them — a pre-existing gap that already silently applies to `t3-migrate-idle`.
Same commit widens those filters to
`identifier=~"t3-autoupdate|t3-migrate-idle|t3-watchdog"`, so `safe_restart_unit`
failures alert no matter which timer triggered them. (`T3PairingBroken` needs no
change — it watches `t3-dispatch.service`, which is caller-independent.)

## Testing

- **Unit tests** (`tests/t3-watchdog-gate.test.sh`, same pure-bash harness as
  `t3-migrate-idle-gate.test.sh`): the gate function across fail-counts, grace
  window, ledger cap/window-slide, unparseable inputs (fail closed — do nothing),
  port extraction from env-file text.
- **Live-fire drill** (approved): after deploy, `kill -STOP` the main PID of
  `t3-serve@wizard` to fake the livelock class; expect detection at 3 ticks and a
  verified safe restart within ~4 min, `T3WatchdogRestarted` visible. Wizard's
  instance only; brief self-inflicted outage accepted.
- **Healthy-cycle soak**: one full day with zero watchdog actions on healthy
  instances (no false positives) before calling it done — checked via the journal.

## Deployment

Repo → `setup-devvm.sh` (install script to `/usr/local/bin/t3-watchdog`, units to
`/etc/systemd/system`, `systemctl enable --now t3-watchdog.timer`) — run the
installer on the devvm after landing (presence-claim the host first). Monitoring
stack change (Loki rules) lands in the same commit; CI applies it on push to
master. Docs updated in the same commit: this design, a short
`docs/runbooks/t3-watchdog.md`, an addendum pointer in the 2026-06-22 post-mortem
("OOMPolicy=continue leaves a survived-but-wounded gap; the watchdog closes it"),
and a paragraph in `docs/architecture/multi-tenancy.md` alongside the other devvm
timer machinery (provision/claude-auth-sync/playwright/tmux-persist sections).

## Rejected alternatives

- **`OOMPolicy=kill` + `Restart=on-failure`**: no new code, but kills all of a
  user's sessions on any child OOM (regression of the settled 2026-06-10 decision)
  and is blind to the livelock class (2026-07-02 had `oom_kill=0`).
- **Bare cron curl-and-restart**: no pairing verification (a restart that lands
  broken stays broken silently), no flap protection, invisible in alerting.
- **systemd `WatchdogSec`**: needs `sd_notify` keepalives from inside t3 — upstream
  change we don't own.
