# t3-watchdog — wedged t3-serve auto-recovery

**What:** `t3-watchdog.timer` (minutely, devvm) probes every running
`t3-serve@<user>` on `127.0.0.1:$T3_PORT/` (10s timeout). Three consecutive
failures on a unit that is `active` and up >120s → pre-restart DB snapshot →
shared `safe_restart_unit` (restart, verify pairing through the real dispatch;
on failure: restore that user's DB + freeze the updater). Flap cap: 3 watchdog
restarts per 30 min per unit, then it stands down and logs `WATCHDOG-EXHAUSTED`.
Design + full rationale: `../plans/2026-07-08-t3-watchdog-design.md`.

**Alerts** (Loki, `#alerts`): `T3WatchdogRestarted` (warning — self-healed,
skim why), `T3WatchdogExhausted` (critical — that user's t3 is down and the
watchdog gave up). A restart that lands broken additionally fires the widened
`T3AutoUpdate{RolledBack,RollbackFailed,Frozen}` family (their identifier
filter covers all t3-safe-restart callers).

**Inspect:**

- `journalctl -t t3-watchdog --since -2h` — every probe failure and action.
- `systemctl list-timers t3-watchdog.timer` / `systemctl status t3-watchdog.service`
- Counters/ledger: `/run/t3-watchdog/<user>.fails` + `<user>.restarts` (tmpfs,
  reset on boot — deliberate).

**On T3WatchdogExhausted:** find the cause before restarting by hand —
`journalctl -k | grep -i oom` (cgroup OOM kills in the t3-serve slice),
`ls -lh /home/<user>/.t3/userdata/state.sqlite` (DB bloat), current build
(`t3 --version` vs `/var/lib/t3-autoupdate/last-good`). Then
`sudo systemctl restart t3-serve@<user>` and watch the next probes go green.

**Pause the watchdog:** `sudo systemctl disable --now t3-watchdog.timer`
(re-enable with `enable --now`). It deliberately IGNORES
`/etc/t3-autoupdate.freeze` — freeze stops version changes, not recovery
restarts (the watchdog re-execs the already-installed binary).

**Tune** via a drop-in (`sudo systemctl edit t3-watchdog.service`) setting
`Environment=T3_WD_FAILS_REQUIRED=… T3_WD_GRACE_SECONDS=… T3_WD_MAX_RESTARTS=…
T3_WD_WINDOW_SECONDS=… T3_WD_PROBE_TIMEOUT=…`.

**Known limits:** probes only the HTTP listener (a serve that answers 200 but
is otherwise sick won't trip it); restarts even when sessions look "active" —
by design, a dead port means every session on that instance is already broken.
