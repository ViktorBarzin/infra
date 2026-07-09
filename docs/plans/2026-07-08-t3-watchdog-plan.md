# t3-watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-detect and safe-restart `t3-serve@<user>` instances that wedge (unit `active`, port dead or unresponsive) after cgroup OOM, per the approved design `docs/plans/2026-07-08-t3-watchdog-design.md`.

**Architecture:** A minutely systemd timer runs a root oneshot bash script that probes each running instance's local port; after 3 consecutive failures (with a startup grace window and a 3-per-30-min flap cap) it takes a DB snapshot and calls the shared `safe_restart_unit` (restart → dispatch-pairing verify → recover+freeze on failure). Log lines ship via journald → Loki, where two new alert rules (plus a widened identifier filter on three existing ones) surface every action.

**Tech Stack:** bash (main-guarded, sources `/usr/local/lib/t3-safe-restart.sh`), systemd timer/service, pure-bash tests (`tests/*.test.sh` harness), Terraform (Loki ruler rules in the monitoring stack).

**Worktree:** `~/code/infra/.worktrees/t3-watchdog`, branch `wizard/t3-watchdog`. ALL git commands need the git-crypt filter flags. Define this helper once per shell and use it for every git command below (`gcgit` in the code blocks):

```bash
gcgit() { git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false "$@"; }
```

Stage files BY NAME, never `-A`/`.`.

---

### Task 1: Watchdog script — gate logic first (TDD), then the full script

**Files:**
- Test: `tests/t3-watchdog-gate.test.sh` (new)
- Create: `scripts/t3-watchdog.sh`

- [ ] **Step 1: Write the failing test file**

Create `tests/t3-watchdog-gate.test.sh` (mode 0755), mirroring the harness of `tests/t3-migrate-idle-gate.test.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash unit tests for the t3-watchdog gate. No root, no bats, no Docker.
# Sources t3-watchdog.sh (main-guarded) with the lib path pointed at the worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
export T3_SAFE_RESTART_LIB="$HERE/scripts/t3-safe-restart.sh"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-watchdog.sh"            # defines functions; main-guard prevents the sweep from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }

WD_GRACE_SECONDS=120 WD_FAILS_REQUIRED=3 WD_MAX_RESTARTS=3 WD_WINDOW_SECONDS=1800

# --- gate_should_restart <active_state> <uptime_s> <fails> <restarts_in_window> ---
# rc 0 = restart, rc 1 = hold off, rc 2 = at flap cap (caller logs EXHAUSTED)
ok    gate_should_restart active 300 3 0        # golden path
ok    gate_should_restart active 300 5 2        # more fails, under cap
notok gate_should_restart active 300 2 0        # not enough consecutive fails
notok gate_should_restart active 60  3 0        # inside startup grace
notok gate_should_restart active 120 3 0        # grace boundary: must be STRICTLY past it
notok gate_should_restart inactive 300 3 0      # unit not active -> systemd's problem
notok gate_should_restart failed 300 3 0
notok gate_should_restart active "" 3 0         # unparseable uptime -> fail closed
notok gate_should_restart active -5 3 0         # negative uptime (clock skew) -> fail closed
notok gate_should_restart active 300 x 0        # unparseable fails -> fail closed
notok gate_should_restart active 300 3 junk     # unparseable ledger count -> fail closed
gate_should_restart active 300 3 3; eq "$?" 2 "at cap returns rc 2"
gate_should_restart active 300 9 7; eq "$?" 2 "over cap returns rc 2"

# --- parse_port: extract T3_PORT from env-file text on stdin ---
eq "$(printf 'NODE_ENV=production\nT3_PORT=3773\n' | parse_port)" "3773" "plain assignment"
eq "$(printf 'T3_PORT="3774"\n' | parse_port)" "3774" "double-quoted"
eq "$(printf "T3_PORT='3775'\n" | parse_port)" "3775" "single-quoted"
eq "$(printf '# T3_PORT=9999\nT3_PORT=3773\n' | parse_port)" "3773" "comment line ignored"
eq "$(printf 'T3_PORT=3773\nT3_PORT=3999\n' | parse_port)" "3999" "last assignment wins"
eq "$(printf 'T3_PORT=abc\n' | parse_port)" "" "non-numeric -> empty"
eq "$(printf 'no port here\n' | parse_port)" "" "absent -> empty"

# --- restarts_in_window <now_epoch> (ledger epochs on stdin, one per line) ---
NOW=1000000   # window = (NOW-1800, NOW]
eq "$(printf '999000\n999500\n' | restarts_in_window $NOW)" "2" "both inside window"
eq "$(printf '990000\n999500\n' | restarts_in_window $NOW)" "1" "old entry pruned"
eq "$(printf '998200\n' | restarts_in_window $NOW)" "0" "boundary epoch is outside (strict >)"
eq "$(printf 'garbage\n999500\n' | restarts_in_window $NOW)" "1" "garbage line ignored"
eq "$(printf '' | restarts_in_window $NOW)" "0" "empty ledger"

echo; echo "t3-watchdog-gate: pass=$pass fail=$fail"
[ "$fail" = 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ~/code/infra/.worktrees/t3-watchdog && bash tests/t3-watchdog-gate.test.sh`
Expected: FAIL immediately — `scripts/t3-watchdog.sh: No such file or directory` (non-zero exit).

- [ ] **Step 3: Write the script**

Create `scripts/t3-watchdog.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# t3-watchdog.sh — minutely wedge watchdog for t3-serve@<user> (via t3-watchdog.timer).
#
# WHY: OOMPolicy=continue (the settled 2026-06-10 decision — a runaway agent child
# dies, the server survives) leaves a gap: the surviving main process is sometimes
# WOUNDED — it drops its HTTP listener (2026-07-08: ~2h listener-less zombie after
# two cgroup OOM kills) or livelocks with the port open (2026-07-02 class). The unit
# stays "active", so Restart=on-failure never fires. This watchdog probes each
# instance's local port and safe-restarts confirmed-wedged ones, loudly.
#
# GATES (all must hold): unit active; up >WD_GRACE_SECONDS (don't judge a booting
# instance); WD_FAILS_REQUIRED consecutive failed probes (ride out blips); fewer
# than WD_MAX_RESTARTS watchdog restarts in the trailing WD_WINDOW_SECONDS — at the
# cap it logs WATCHDOG-EXHAUSTED (-> critical Loki alert) and stands down.
# DELIBERATELY NOT GATED on the idle/active-turn check (a dead port means every
# session is already broken) nor on /etc/t3-autoupdate.freeze (freeze is VERSION
# policy; this re-execs the already-installed binary). Design + rationale:
# docs/plans/2026-07-08-t3-watchdog-design.md. Runbook: docs/runbooks/t3-watchdog.md.
set -uo pipefail

LOG_TAG=t3-watchdog
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

WD_STATE_DIR="${T3_WD_STATE_DIR:-/run/t3-watchdog}"     # tmpfs: fresh counters after boot (deliberate)
WD_GRACE_SECONDS="${T3_WD_GRACE_SECONDS:-120}"
WD_FAILS_REQUIRED="${T3_WD_FAILS_REQUIRED:-3}"
WD_MAX_RESTARTS="${T3_WD_MAX_RESTARTS:-3}"
WD_WINDOW_SECONDS="${T3_WD_WINDOW_SECONDS:-1800}"
WD_PROBE_TIMEOUT="${T3_WD_PROBE_TIMEOUT:-10}"           # also what catches the livelock class

# T3_PORT from env-file text on stdin (last assignment wins; tolerates quotes).
parse_port() {
  sed -n "s/^[[:space:]]*T3_PORT=[\"']\{0,1\}\([0-9][0-9]*\)[\"']\{0,1\}[[:space:]]*$/\1/p" | tail -1
}

# Count ledger epochs (stdin, one per line) strictly inside (now-WINDOW, now].
restarts_in_window() {
  local now="$1" n=0 e
  while IFS= read -r e; do
    case "$e" in ''|*[!0-9]*) continue;; esac
    [ "$e" -gt $((now - WD_WINDOW_SECONDS)) ] && n=$((n+1))
  done
  echo "$n"
}

# gate_should_restart <active_state> <uptime_s> <fails> <restarts_in_window>
# rc 0 = restart now; rc 1 = hold off; rc 2 = still wedged but at the flap cap.
# Unparseable input -> rc 1 (fail closed: do nothing rather than restart blind).
gate_should_restart() {
  local active="$1" uptime="$2" fails="$3" recent="$4"
  [ "$active" = "active" ] || return 1
  case "$uptime" in ''|*[!0-9]*) return 1;; esac
  [ "$uptime" -gt "$WD_GRACE_SECONDS" ] || return 1
  case "$fails" in ''|*[!0-9]*) return 1;; esac
  [ "$fails" -ge "$WD_FAILS_REQUIRED" ] || return 1
  case "$recent" in ''|*[!0-9]*) return 1;; esac
  [ "$recent" -lt "$WD_MAX_RESTARTS" ] || return 2
  return 0
}

main() {
  mkdir -p "$WD_STATE_DIR"
  local unit u port code rc fails now started uptime recent reason
  # safe_restart_unit contract: $target (version moved to — here: what's installed,
  # used in backup filenames/logs) and $last_good (its rollback target — equal to
  # installed outside a mid-update window, making rollback a no-op reinstall).
  target="$(ver)"
  [ -n "$target" ] || { LOG "cannot read t3 version — skipping sweep"; return 0; }
  last_good="$(tr -d '[:space:]' <"$LAST_GOOD_FILE" 2>/dev/null)"
  [ -n "$last_good" ] || last_good="$target"

  for unit in $(systemctl list-units --type=service --state=running --no-legend 't3-serve@*' 2>/dev/null | awk '{print $1}'); do
    u="$(printf '%s' "$unit" | sed -n 's/^t3-serve@\(.*\)\.service$/\1/p')"; [ -n "$u" ] || continue
    port=""
    [ -r "/etc/t3-serve/$u.env" ] && port="$(parse_port <"/etc/t3-serve/$u.env")"
    [ -n "$port" ] || { LOG "no T3_PORT for $u in /etc/t3-serve/$u.env — skipping (provisioning problem, not a wedge)"; continue; }

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$WD_PROBE_TIMEOUT" "http://127.0.0.1:$port/" 2>/dev/null)"; rc=$?
    if [ "$code" = "200" ]; then rm -f "$WD_STATE_DIR/$u.fails"; continue; fi

    fails="$(cat "$WD_STATE_DIR/$u.fails" 2>/dev/null || echo 0)"
    case "$fails" in ''|*[!0-9]*) fails=0;; esac
    fails=$((fails+1)); printf '%s\n' "$fails" >"$WD_STATE_DIR/$u.fails"
    case "$rc" in 7) reason="connection-refused";; 28) reason="timeout";; *) reason="http=$code(curl=$rc)";; esac

    now="$(date +%s)"
    started="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)" +%s 2>/dev/null || echo '')"
    if [ -n "$started" ]; then uptime=$((now - started)); else uptime=""; fi
    if [ -f "$WD_STATE_DIR/$u.restarts" ]; then
      recent="$(restarts_in_window "$now" <"$WD_STATE_DIR/$u.restarts")"
    else
      recent=0
    fi
    LOG "probe FAILED for $unit (port=$port reason=$reason consecutive=$fails uptime=${uptime:-?}s recent_restarts=$recent)"

    gate_should_restart "$(systemctl is-active "$unit" 2>/dev/null)" "$uptime" "$fails" "$recent"
    case $? in
      0) : ;;
      2) LOG "WATCHDOG-EXHAUSTED: $unit still unhealthy but hit the flap cap ($WD_MAX_RESTARTS restarts/${WD_WINDOW_SECONDS}s) — standing down, human needed"; continue ;;
      *) continue ;;
    esac

    printf '%s\n' "$now" >>"$WD_STATE_DIR/$u.restarts"   # cap counts ATTEMPTS
    if ! backup_user "$u" >/dev/null; then
      # Unlike t3-migrate-idle (healthy instance, waiting is free) we proceed:
      # the instance is DOWN; recovery-restore degrades to an older snapshot.
      LOG "WARN: pre-restart backup FAILED for $u — proceeding anyway (instance is down)"
    fi
    if safe_restart_unit "$unit" "$u"; then
      LOG "WATCHDOG: restarted $unit (reason=$reason) — recovered, pairing verified"
    else
      LOG "WATCHDOG: restart of $unit FAILED verification — safe_restart_unit ran recovery (DB restore + freeze); see its log lines"
    fi
    rm -f "$WD_STATE_DIR/$u.fails"   # fresh process gets a clean slate + grace window
  done
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/t3-watchdog-gate.test.sh`
Expected: `t3-watchdog-gate: pass=25 fail=0`, exit 0.

- [ ] **Step 5: Lint**

Run: `shellcheck scripts/t3-watchdog.sh tests/t3-watchdog-gate.test.sh`
Expected: no output (exit 0). Fix any findings (don't suppress).

- [ ] **Step 6: Regression-check the sibling tests still pass**

Run: `bash tests/t3-migrate-idle-gate.test.sh`
Expected: its pass line, `fail=0` (we touched nothing it uses — this is a cheap invariant).

- [ ] **Step 7: Commit**

```bash
cd ~/code/infra/.worktrees/t3-watchdog
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false add scripts/t3-watchdog.sh tests/t3-watchdog-gate.test.sh
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false commit -m "t3-watchdog: probe + safe-restart wedged t3-serve instances

t3-serve survives cgroup OOM wounded (listener dropped / livelocked)
while systemd sees 'active', so nothing auto-recovers it — Viktor's
instance was a listener-less zombie for ~2h on 2026-07-08. Minutely
sweep: 3 failed local-port probes -> backup + shared safe_restart_unit
(pairing-verified, recover+freeze on failure), 120s boot grace,
3-per-30min flap cap -> WATCHDOG-EXHAUSTED. Gate logic is pure +
unit-tested (tests/t3-watchdog-gate.test.sh).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: systemd units + installer wiring

**Files:**
- Create: `scripts/t3-watchdog.service`
- Create: `scripts/t3-watchdog.timer`
- Modify: `scripts/workstation/setup-devvm.sh` (§9a install block ~line 211-215; §9d unit list ~line 247-253; §9d enable line ~line 268-269; §9a lib comment line 212)

- [ ] **Step 1: Create `scripts/t3-watchdog.service`** (no `Documentation=` line — doc pointers live in comments, sidestepping URI-syntax pickiness)

```ini
[Unit]
# Design: docs/plans/2026-07-08-t3-watchdog-design.md
# Runbook: docs/runbooks/t3-watchdog.md
Description=t3-serve wedge watchdog (probe ports, safe-restart dead/hung instances)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/t3-watchdog
# NO RuntimeDirectory= : systemd wipes it when a oneshot exits, and the
# fail-counters/restart-ledger in /run/t3-watchdog must survive between ticks
# (the script mkdir -p's it itself).
```

- [ ] **Step 2: Create `scripts/t3-watchdog.timer`**

```ini
[Unit]
Description=Minutely t3-serve wedge watchdog

[Timer]
OnCalendar=minutely
# Default AccuracySec=1min would smear ticks; keep detection latency predictable.
AccuracySec=10s
# Persistent deliberately omitted (matches t3-autoupdate.timer): a minutely
# timer needs no catch-up firing.

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Wire into `scripts/workstation/setup-devvm.sh`**

Three small edits (Read the file first; line numbers are as of master 95be090b):

(a) §9a script-install block — after line 213 (`install … t3-migrate-idle`), add:

```bash
install -m 0755 "$SCRIPTS/t3-watchdog.sh"     /usr/local/bin/t3-watchdog
```

(b) same block, line 212 — update the lib's trailing comment to name all callers:

```bash
install -m 0644 "$SCRIPTS/t3-safe-restart.sh" /usr/local/lib/t3-safe-restart.sh   # sourced lib (t3-autoupdate + t3-migrate-idle + t3-watchdog)
```

(c) §9d unit list — in the `for u in …` list, after the `t3-migrate-idle.service t3-migrate-idle.timer \` line add:

```bash
         t3-watchdog.service t3-watchdog.timer \
```

(d) §9d enablement — extend line 269's timer list:

```bash
  t3-autoupdate.timer t3-backup-state.timer t3-provision-users.timer t3-migrate-idle.timer t3-watchdog.timer >/dev/null 2>&1 || \
```

Also update the tally comment on line 271 (`t3-dispatch + 3 timers` → it already says 3 while listing 4; make it `t3-dispatch + timers`).

- [ ] **Step 4: Lint the touched shell**

Run: `shellcheck scripts/workstation/setup-devvm.sh` — expected: same findings as before the edit (it's a big script; only NEW findings block). Quick check: `gcgit stash && shellcheck scripts/workstation/setup-devvm.sh > /tmp/claude-1000/-/004779bc-7db4-4a19-bd91-fd9af6a94dbe/scratchpad/sc-before.txt; gcgit stash pop && shellcheck scripts/workstation/setup-devvm.sh > /tmp/claude-1000/-/004779bc-7db4-4a19-bd91-fd9af6a94dbe/scratchpad/sc-after.txt; diff /tmp/claude-1000/-/004779bc-7db4-4a19-bd91-fd9af6a94dbe/scratchpad/sc-before.txt /tmp/claude-1000/-/004779bc-7db4-4a19-bd91-fd9af6a94dbe/scratchpad/sc-after.txt` — expected: empty diff.

- [ ] **Step 5: Commit**

```bash
gcgit add scripts/t3-watchdog.service scripts/t3-watchdog.timer scripts/workstation/setup-devvm.sh
gcgit commit -m "t3-watchdog: systemd units + setup-devvm install/enable wiring

Minutely oneshot timer, installed and enabled by setup-devvm.sh §9
exactly like its t3-autoupdate/t3-migrate-idle siblings, so a devvm
rebuild reproduces the watchdog.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Loki alert rules (widen identifier filter + two watchdog rules)

**Files:**
- Modify: `stacks/monitoring/modules/monitoring/loki.tf` (group `t3 Auth & Upgrades`: lines ~299, ~312, ~326 + append two rules after the `T3AutoUpdateFrozen` block ending ~line 334)

- [ ] **Step 1: Widen the three identifier filters**

In the three exprs (T3AutoUpdateRolledBack ~299, T3AutoUpdateRollbackFailed ~312, T3AutoUpdateFrozen ~326) replace:

`identifier=\"t3-autoupdate\"` → `identifier=~\"t3-autoupdate|t3-migrate-idle|t3-watchdog\"`

Rationale (add one line to the group's header comment block, after the "Runbook:" line ~263): `# The identifier regex covers every t3-safe-restart.sh caller — rollback/freeze log lines are identical regardless of which timer triggered them.`

- [ ] **Step 2: Append the two watchdog rules**

Insert after the closing `},` of the `T3AutoUpdateFrozen` rule (before the `WorkstationClaudeAuthInvalid` rule), matching the existing style exactly:

```hcl
            {
              # The wedge watchdog detected a dead/unresponsive t3-serve listener
              # and safe-restarted it (2026-07-08 class: OOMPolicy=continue keeps
              # the main proc alive but it drops its listener after a cgroup OOM).
              # Self-healed — skim why it wedged (cgroup OOM is the usual suspect).
              alert  = "T3WatchdogRestarted"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-watchdog\"} |~ \"WATCHDOG: restarted\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3-watchdog auto-restarted a wedged t3-serve instance"
                description = "A t3-serve instance stopped answering its local port while its unit stayed active; the watchdog safe-restarted it and pairing verified. Self-healed. Check the devvm journal (identifier=t3-watchdog) for which user and the failure reason."
                runbook     = "docs/runbooks/t3-watchdog.md"
              }
            },
            {
              # The watchdog hit its flap cap (default 3 restarts/30m) and stood
              # down while the instance is still unhealthy — restarting isn't
              # curing it. That user's t3 is DOWN until a human intervenes.
              alert  = "T3WatchdogExhausted"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-watchdog\"} |~ \"WATCHDOG-EXHAUSTED\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3-watchdog EXHAUSTED — a t3-serve instance keeps wedging and stays down"
                description = "The watchdog restarted the same t3-serve instance to its flap cap within the window and it is still failing probes, so it stood down. Investigate: cgroup OOM kills (journalctl -k), state.sqlite size, the running build; restart manually once the cause is addressed."
                runbook     = "docs/runbooks/t3-watchdog.md"
              }
            },
```

- [ ] **Step 3: Format + sanity-check the HCL**

Run: `terraform fmt stacks/monitoring/modules/monitoring/loki.tf` — expected: no output or the filename (reformat OK). Then `gcgit diff --stat` — expected: only loki.tf changed.
(Do NOT `tg plan/apply` from the worktree — git-crypt'd tfvars read as ciphertext there; CI applies after landing.)

- [ ] **Step 4: Commit**

```bash
gcgit add stacks/monitoring/modules/monitoring/loki.tf
gcgit commit -m "monitoring: T3Watchdog{Restarted,Exhausted} alerts; widen T3AutoUpdate* identifier

The three T3AutoUpdate* rules matched identifier=t3-autoupdate exactly,
so rollback/freeze lines logged by other t3-safe-restart callers
(t3-migrate-idle today, t3-watchdog now) never alerted. Widened to a
regex over all three tags, and added warning/critical rules for the
new watchdog's restarted/exhausted signals.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Docs (runbook + post-mortem addendum + multi-tenancy paragraph)

**Files:**
- Create: `docs/runbooks/t3-watchdog.md`
- Modify: `docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md` (append addendum after the 2026-07-02 one)
- Modify: `docs/architecture/multi-tenancy.md` (add a paragraph after the "Web-terminal session persistence" block, ~line 568)

- [ ] **Step 1: Write `docs/runbooks/t3-watchdog.md`**

```markdown
# t3-watchdog — wedged t3-serve auto-recovery

**What:** `t3-watchdog.timer` (minutely, devvm) probes every running
`t3-serve@<user>` on `127.0.0.1:$T3_PORT/` (10s timeout). Three consecutive
failures on a unit that is `active` and up >120s → pre-restart DB snapshot →
shared `safe_restart_unit` (restart, verify pairing through the real dispatch;
on failure: restore that user's DB + freeze the updater). Flap cap: 3 watchdog
restarts per 30 min per unit, then it stands down and logs `WATCHDOG-EXHAUSTED`.
Design + full rationale: `docs/plans/2026-07-08-t3-watchdog-design.md`.

**Alerts** (Loki, `#alerts`): `T3WatchdogRestarted` (warning — self-healed,
skim why), `T3WatchdogExhausted` (critical — that user's t3 is down and the
watchdog gave up). A restart that lands broken additionally fires the widened
`T3AutoUpdate{RolledBack,RollbackFailed,Frozen}` family.

**Inspect:**
- `journalctl -t t3-watchdog --since -2h` — every probe failure and action.
- `systemctl list-timers t3-watchdog.timer` / `systemctl status t3-watchdog.service`
- Counters/ledger: `/run/t3-watchdog/<user>.fails` + `<user>.restarts` (tmpfs).

**On T3WatchdogExhausted:** find the cause before restarting by hand —
`journalctl -k | grep -i oom` (cgroup OOM kills in the t3-serve slice),
`ls -lh /home/<user>/.t3/userdata/state.sqlite` (DB bloat), current build
(`t3 --version` vs `/var/lib/t3-autoupdate/last-good`). Then
`sudo systemctl restart t3-serve@<user>` and watch the next probes go green.

**Pause the watchdog:** `sudo systemctl disable --now t3-watchdog.timer`
(re-enable with `enable --now`). It deliberately IGNORES
`/etc/t3-autoupdate.freeze` — freeze stops version changes, not recovery
restarts (the watchdog re-execs the already-installed binary).

**Tune** via a drop-in (`systemctl edit t3-watchdog.service`) setting
`Environment=T3_WD_FAILS_REQUIRED=… T3_WD_GRACE_SECONDS=… T3_WD_MAX_RESTARTS=…
T3_WD_WINDOW_SECONDS=… T3_WD_PROBE_TIMEOUT=…`.

**Known limits:** probes only the HTTP listener (a serve that answers 200 but
is otherwise sick won't trip it); counters reset on reboot (deliberate — /run).
```

- [ ] **Step 2: Append to the 2026-06-22 post-mortem**

After the existing "Addendum (2026-07-02)" section, append:

```markdown

## Addendum 2 (2026-07-09): OOMPolicy=continue leaves survived-but-wounded — watchdog added

2026-07-08 falsified the remaining assumption that "`OOMPolicy=continue` keeps
t3-serve itself alive": after two ~10G children were cgroup-OOM-killed inside
`t3-serve@wizard` (07:24/07:26), the surviving main process degraded and at
~18:58 silently dropped its `:3773` listener — unit still `active`,
`NRestarts=0`, journal dark — a listener-less zombie for ~2h until a manual
restart (graceful stop timed out; SIGKILL). `continue` remains correct (see
2026-06-10 rationale above); what was missing is recovery for the wounded
survivor. Closed by **t3-watchdog** (`scripts/t3-watchdog.sh`, minutely timer):
local-port probes, 3-strike confirmation, pairing-verified safe restart, flap
cap + Loki alerts. Design: `../plans/2026-07-08-t3-watchdog-design.md`;
runbook: `../runbooks/t3-watchdog.md`.
```

- [ ] **Step 3: Add the multi-tenancy.md paragraph**

Insert after the "Web-terminal session persistence (2026-06-10)" paragraph (grep for `Web-terminal session persistence` to locate), matching the surrounding bold-lead-in style:

```markdown

**t3-serve wedge watchdog (2026-07-09):** `t3-watchdog.timer` (minutely) probes
every running `t3-serve@<user>` on its local `T3_PORT`; three consecutive
failures on an `active`, past-grace unit trigger a pre-restart DB snapshot and
the shared `safe_restart_unit` (pairing-verified; recover+freeze on failure),
with a 3-per-30-min flap cap (`WATCHDOG-EXHAUSTED` → critical alert). Exists
because `OOMPolicy=continue` can leave a wounded main process holding an
`active` unit with a dead or livelocked listener that `Restart=on-failure`
never sees (2026-07-08 + 2026-07-02 incidents). It ignores the updater freeze
(availability ≠ version policy) and restarts regardless of "active" sessions —
a dead port means they're already broken. Alerts `T3WatchdogRestarted` /
`T3WatchdogExhausted`; runbook `../runbooks/t3-watchdog.md`.
```

- [ ] **Step 4: Commit**

```bash
gcgit add docs/runbooks/t3-watchdog.md docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md docs/architecture/multi-tenancy.md
gcgit commit -m "docs: t3-watchdog runbook + post-mortem addendum + multi-tenancy entry

Same-commit docs for the new watchdog per the repo's docs-with-every-
change rule: operator runbook, addendum 2 on the 2026-06-22 containment
post-mortem (the survived-but-wounded gap it closes), and the devvm
timer roster in multi-tenancy.md.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Land on master

- [ ] **Step 1: Merge latest master into the branch, re-verify**

```bash
cd ~/code/infra/.worktrees/t3-watchdog
gcgit fetch forgejo
gcgit merge forgejo/master   # resolve conflicts if any (loki.tf is the likely spot)
bash tests/t3-watchdog-gate.test.sh && bash tests/t3-migrate-idle-gate.test.sh
shellcheck scripts/t3-watchdog.sh
terraform fmt -check stacks/monitoring/modules/monitoring/loki.tf
```
Expected: merge clean (or resolved), both test files `fail=0`, shellcheck silent, fmt silent.

- [ ] **Step 2: Push to master**

```bash
gcgit push forgejo HEAD:master
```
Non-fast-forward → another agent landed first: `gcgit fetch forgejo && gcgit merge forgejo/master`, re-run step 1 checks, push again. If branch protection rejects: fall back to pushing `wizard/t3-watchdog` and opening a PR via the Forgejo API (token = password field in ~/.git-credentials) per the org recipe.

- [ ] **Step 3: Watch CI apply the monitoring stack**

The push triggers the Woodpecker `default.yml` terragrunt apply (infra repo pipeline). Watch it complete (Woodpecker API, infra Forgejo forge repo 82) and confirm success. Then verify the ruler actually LOADED the rules — ask Loki itself over a port-forward (authoritative; the `.lan` ingress 504s on heavy queries per repo docs):

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
PF=$!
until curl -s -o /dev/null --max-time 2 localhost:3100/ready; do :; done
curl -s localhost:3100/loki/api/v1/rules | grep -c 'T3Watchdog'          # expected: ≥2 (both new rules)
curl -s localhost:3100/loki/api/v1/rules | grep -c 't3-watchdog'         # expected: ≥5 (2 new + 3 widened filters)
kill $PF
```

---

### Task 6: Deploy to the devvm + healthy-cycle verification

- [ ] **Step 1: Claim presence** (service restarts on shared infra)

```bash
~/code/scripts/presence claim infra:devvm-t3-watchdog --purpose "install+enable t3-watchdog timer (auto-recovery for wedged t3-serve; live-fire drill on wizard's own instance)"
```
If already claimed by another session: release, surface to Viktor, wait for OK.

- [ ] **Step 2: Install exactly what setup-devvm.sh §9 would** (targeted — not the whole script; use the MAIN checkout after the master pull, or the worktree copy of the new files which are not git-crypt'd)

```bash
cd ~/code/infra && git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false pull --ff-only forgejo master
sudo install -m 0755 scripts/t3-watchdog.sh /usr/local/bin/t3-watchdog
sudo install -m 0644 scripts/t3-watchdog.service /etc/systemd/system/t3-watchdog.service
sudo install -m 0644 scripts/t3-watchdog.timer   /etc/systemd/system/t3-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now t3-watchdog.timer
```

- [ ] **Step 3: Verify a healthy tick**

```bash
systemctl list-timers t3-watchdog.timer --no-pager        # NEXT within 60s
sudo /usr/local/bin/t3-watchdog                            # manual tick: exit 0, no output for healthy instances
sudo journalctl -t t3-watchdog --since -5m --no-pager      # empty or skip-lines only; NO probe-FAILED lines
ls /run/t3-watchdog/                                       # exists, empty (no fail counters)
```
Expected: all instances silent-healthy. Any `probe FAILED` line on a healthy instance = false positive → STOP, investigate before proceeding.

- [ ] **Step 4: Release nothing yet** — presence stays claimed through the drill (Task 7).

---

### Task 7: Live-fire drill (approved) + wrap-up

- [ ] **Step 1: Fake the livelock class on wizard's own instance**

```bash
MAINPID=$(systemctl show -p MainPID --value t3-serve@wizard.service)
sudo kill -STOP "$MAINPID"
date -u   # note T0
```
(SIGSTOP: unit stays `active`, port stops answering → probe timeouts. This is the 2026-07-02 signature. Brief self-inflicted outage on wizard's instance only — approved by Viktor 2026-07-08.)

- [ ] **Step 2: Watch detection + recovery (expect ≤ ~4.5 min end-to-end)**

```bash
sudo journalctl -t t3-watchdog -f
```
Expected sequence: three `probe FAILED … reason=timeout consecutive=1/2/3` lines ~60s apart, then backup + `WATCHDOG: restarted t3-serve@wizard … recovered, pairing verified`. Then confirm service health: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3773/` → 200, and `systemctl show -p ExecMainStartTimestamp --value t3-serve@wizard` is fresh. (The STOPped old process is SIGKILLed by the restart; no SIGCONT needed.)

- [ ] **Step 3: Confirm the alert fired**

Loki/Alertmanager: `T3WatchdogRestarted` visible in #alerts (or `amtool` / Alertmanager UI within ~2-3 min of the log line). If the ruler misses it, check the rule landed (Task 5 step 3) before debugging further.

- [ ] **Step 4: Confirm no residue**

```bash
cat /run/t3-watchdog/wizard.restarts   # exactly one epoch (the drill)
ls /run/t3-watchdog/*.fails 2>/dev/null || echo clean   # expect clean
```

- [ ] **Step 5: Release presence + clean up the worktree**

```bash
~/code/scripts/presence release infra:devvm-t3-watchdog
cd ~/code/infra
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false worktree remove .worktrees/t3-watchdog
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false branch -d wizard/t3-watchdog
```

- [ ] **Step 6: 24h false-positive soak (per design)**

Next day: `sudo journalctl -t t3-watchdog --since -24h | grep -c 'probe FAILED' ` — expected 0 outside the drill window (plus whatever real wedges it caught, which is the tool working). Report the soak result to Viktor; only then is the task fully done.
