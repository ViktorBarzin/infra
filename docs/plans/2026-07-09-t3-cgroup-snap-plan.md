# t3-cgroup-snap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Diagnostic snapshotter that records `(pid,ppid,uid,rss,comm,exe,argv[:512])` for every process in every `t3-serve@<user>` cgroup at 5 s cadence, so the next OOM's killed-PID can be identified from the log by `journalctl -k` timestamp; per approved spec `docs/plans/2026-07-09-t3-cgroup-snap-design.md`.

**Architecture:** One long-lived `Type=simple` root systemd service running a bash loop; iterates each `t3-serve@*.service` cgroup's `cgroup.procs`, reads `/proc/<pid>` for each, appends one JSONL line per (snapshot, pid) to `/var/log/t3-cgroup-snap.jsonl`, rotates in-script at 50 MiB × 3. Wired into `scripts/workstation/setup-devvm.sh` §9 like every other t3 timer/service. Pure-bash + `jq -Rc .` for argv escaping (both already on the box).

**Tech Stack:** bash (main-guarded, pure functions unit-tested), systemd Type=simple service, `jq` for JSON escaping, pure-bash tests (`tests/*.test.sh` harness).

**Worktree:** `~/code/infra/.worktrees/t3-cgroup-snap`, branch `wizard/t3-cgroup-snap`. ALL git commands need the git-crypt filter flags. Define this helper once per shell and use it for every git command below (`gcgit` in the code blocks):

```bash
gcgit() { git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false "$@"; }
```

Stage files BY NAME, never `-A`/`.`.

---

### Task 1: Snapshotter — pure functions first (TDD), then the loop

**Files:**
- Test: `tests/t3-cgroup-snap.test.sh` (new)
- Create: `scripts/t3-cgroup-snap.sh` (new)

- [ ] **Step 1: Write the failing test file**

Create `tests/t3-cgroup-snap.test.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# Pure-bash unit tests for t3-cgroup-snap. No root, no bats, no Docker.
# Sources t3-cgroup-snap.sh (main-guarded) and exercises pure functions against
# a fixture /proc-shaped directory.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-cgroup-snap.sh"          # defines functions; main-guard prevents the loop from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }
eq()   { if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: got '$1' want '$2' ($3)"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture builder: fake /proc/<pid> ---
mkproc() { # mkproc <pid> <rss_kb> <comm> <exe_target> <cmdline_NUL_sep>
  local pid="$1" rss="$2" comm="$3" exe="$4" cmd="$5" d="$TMP/proc/$pid"
  mkdir -p "$d"
  printf 'Name:\t%s\nVmRSS:\t%s kB\nUid:\t1000\t1000\t1000\t1000\n' "$comm" "$rss" >"$d/status"
  printf '%s\n' "$comm" >"$d/comm"
  ln -sf "$exe" "$d/exe"
  printf '%b' "$cmd" >"$d/cmdline"
}

# --- read_pid_status <procroot> <pid> ---
mkproc 100 5394176 '2.1.205' '/usr/bin/python3' 'python3\0/tmp/tool\0--verbose\0'
RES="$(read_pid_status "$TMP/proc" 100 | jq -c '{pid,uid,rss_kb,comm}')"
eq "$RES" '{"pid":100,"uid":1000,"rss_kb":5394176,"comm":"2.1.205"}' "read_pid_status basics"

# short-lived proc: partial fixture (no status file) -> silent skip (empty stdout, rc 0)
mkdir -p "$TMP/proc/999"; printf 'gone\n' >"$TMP/proc/999/comm"
RES="$(read_pid_status "$TMP/proc" 999)"; eq "$RES" "" "missing status -> empty"

# --- emit_line <procroot> <user> <pid> [ts_override] ---
mkproc 200 128 'claude' '/usr/bin/node' 'node\0/usr/bin/claude\0--output-format\0stream-json\0'
LINE="$(emit_line "$TMP/proc" wizard 200 '2026-07-09T22:26:40Z')"
eq "$(printf '%s' "$LINE" | jq -r .user)" "wizard" "emit_line user"
eq "$(printf '%s' "$LINE" | jq -r .ts)" "2026-07-09T22:26:40Z" "emit_line ts"
eq "$(printf '%s' "$LINE" | jq -r .comm)" "claude" "emit_line comm"
eq "$(printf '%s' "$LINE" | jq -r .exe)" "/usr/bin/node" "emit_line exe"
eq "$(printf '%s' "$LINE" | jq -r .argv)" "node /usr/bin/claude --output-format stream-json" "argv NUL->space"
ok  test "$(printf '%s' "$LINE" | wc -l)" -eq 1                       # SINGLE line (JSONL invariant)

# argv > 512 bytes -> truncated
LONG=$(printf 'X%.0s' $(seq 1 800))
mkproc 300 64 'bash' '/bin/bash' "bash\0-c\0$LONG\0"
LINE="$(emit_line "$TMP/proc" wizard 300 t)"
ARGV="$(printf '%s' "$LINE" | jq -r .argv)"
ok test "${#ARGV}" -le 512  &&  ok test "${#ARGV}" -ge 500     # truncated near the cap, not empty

# JSON-poisoning argv: quotes, backslashes, newlines survive as VALID JSON
mkproc 400 32 'sh' '/bin/sh' 'sh\0-c\0echo "hi"\nrm\\-rf\0'
LINE="$(emit_line "$TMP/proc" wizard 400 t)"
ok  printf '%s' "$LINE" | jq -e . >/dev/null                   # parses cleanly = escaping works
eq "$(printf '%s' "$LINE" | jq -r .argv | tr -d '\n')"  'sh -c echo "hi"rm\-rf'  "poisonous argv escaped"

# --- rotate_if_needed <path> <max_bytes> ---
F="$TMP/log.jsonl"; : >"$F"
head -c 100 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200   # under threshold: rc 0, no rename
ok test ! -e "$F.1"                                              # no rotation happened
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200   # over threshold: rotates
ok test -e "$F.1"  &&  ok test ! -s "$F"                         # .1 exists, current is empty
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
head -c 300 </dev/urandom >"$F"; ok rotate_if_needed "$F" 200
ok test -e "$F.3"; ok test ! -e "$F.4"                          # ring is bounded to 3 rotations

echo; echo "t3-cgroup-snap: pass=$pass fail=$fail"
[ "$fail" = 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ~/code/infra/.worktrees/t3-cgroup-snap && bash tests/t3-cgroup-snap.test.sh`
Expected: FAIL immediately — `scripts/t3-cgroup-snap.sh: No such file or directory` (non-zero exit).

- [ ] **Step 3: Write the script**

Create `scripts/t3-cgroup-snap.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# t3-cgroup-snap.sh — diagnostic. Samples every process in every t3-serve@<user>
# cgroup at 5s cadence; appends one JSONL line per (snapshot,pid) to a rotated
# local log so that after the next cgroup OOM we can identify the killed PID's
# real argv (the kernel log records the prctl-renamed Comm but not the args).
# Design + rationale: docs/plans/2026-07-09-t3-cgroup-snap-design.md.
# Runbook: docs/runbooks/t3-cgroup-snap.md. Removed same-PR as the mitigation.
set -uo pipefail

SNAP_INTERVAL="${T3_SNAP_INTERVAL:-5}"                    # seconds between snapshots
SNAP_LOG="${T3_SNAP_LOG:-/var/log/t3-cgroup-snap.jsonl}"
SNAP_MAX_BYTES="${T3_SNAP_MAX_BYTES:-52428800}"           # 50 MiB per rotation slot
SNAP_ARGV_MAX="${T3_SNAP_ARGV_MAX:-512}"                  # per-proc argv cap
SNAP_CGROUP_ROOT="${T3_SNAP_CGROUP_ROOT:-/sys/fs/cgroup/system.slice/system-t3\x2dserve.slice}"

# read_pid_status <procroot> <pid> -> single JSON object on stdout, empty on missing.
# Emits just the pid/uid/rss_kb/comm fields — full-line assembly happens in emit_line.
# The unit test asserts against exactly these four keys for a fixture PID.
read_pid_status() {
  local proc="$1" pid="$2" s="$1/$2/status" c="$1/$2/comm"
  [ -r "$s" ] && [ -r "$c" ] || return 0
  local rss uid comm
  read rss uid < <(awk '
    /^VmRSS:/ { rss = $2 }
    /^Uid:/   { uid = $2 }
    END { print (rss?rss:0), (uid?uid:0) }
  ' "$s" 2>/dev/null)
  comm="$(tr -d '\n' <"$c" 2>/dev/null)"
  jq -cn --argjson pid "$pid" --argjson uid "${uid:-0}" --argjson rss "${rss:-0}" --arg comm "$comm" \
    '{pid:$pid,uid:$uid,rss_kb:$rss,comm:$comm}'
}

# emit_line <procroot> <user> <pid> [ts_override] -> ONE JSONL line, empty if pid gone.
# Assembles the full record; partial /proc/<pid> (short-lived proc) => empty stdout, rc 0.
emit_line() {
  local proc="$1" user="$2" pid="$3" ts_override="${4:-}"
  local ts argv exe ppid rss uid comm
  [ -r "$proc/$pid/status" ] && [ -r "$proc/$pid/comm" ] || return 0
  if [ -n "$ts_override" ]; then ts="$ts_override"; else ts="$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')"; fi
  # Extract fields with a single awk (VmRSS + Uid + PPid); tolerate missing.
  read rss uid ppid < <(awk '
    /^VmRSS:/ { rss = $2 }
    /^Uid:/   { uid = $2 }
    /^PPid:/  { ppid = $2 }
    END { print (rss?rss:0), (uid?uid:0), (ppid?ppid:0) }
  ' "$proc/$pid/status" 2>/dev/null)
  comm="$(tr -d '\n' <"$proc/$pid/comm" 2>/dev/null)"
  argv="$(head -c "$SNAP_ARGV_MAX" "$proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | sed 's/ *$//')"
  exe="$(readlink "$proc/$pid/exe" 2>/dev/null || echo '')"
  jq -cn \
    --arg ts "$ts" --arg user "$user" \
    --argjson pid "$pid" --argjson ppid "$ppid" --argjson uid "$uid" --argjson rss "${rss:-0}" \
    --arg comm "$comm" --arg exe "$exe" --arg argv "$argv" \
    '{ts:$ts,user:$user,pid:$pid,ppid:$ppid,uid:$uid,rss_kb:$rss,comm:$comm,exe:$exe,argv:$argv}'
}

# rotate_if_needed <path> <max_bytes>: rotate current -> .1, .1 -> .2, .2 -> .3, drop .3.
# Returns rc 0 always; caller doesn't branch on it.
rotate_if_needed() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  [ "$sz" -ge "$max" ] || return 0
  rm -f "$f.3" 2>/dev/null
  [ -f "$f.2" ] && mv -f "$f.2" "$f.3" 2>/dev/null
  [ -f "$f.1" ] && mv -f "$f.1" "$f.2" 2>/dev/null
  mv -f "$f" "$f.1" 2>/dev/null
  : >"$f"
}

# users_with_cgroup: emit one line per t3-serve@<user> cgroup dir that exists AND has a cgroup.procs.
users_with_cgroup() {
  local d u
  for d in "$SNAP_CGROUP_ROOT"/t3-serve@*.service; do
    [ -r "$d/cgroup.procs" ] || continue
    u="${d##*t3-serve@}"; u="${u%.service}"
    printf '%s\t%s\n' "$u" "$d/cgroup.procs"
  done
}

snapshot_once() {
  local u pf pid
  while IFS=$'\t' read -r u pf; do
    while IFS= read -r pid; do
      emit_line /proc "$u" "$pid" || true
    done <"$pf"
  done < <(users_with_cgroup)
}

main() {
  # ensure log exists with the right perms; the systemd unit runs as root.
  install -m 0640 -o root -g adm /dev/null "$SNAP_LOG" 2>/dev/null || : >"$SNAP_LOG"
  while true; do
    snapshot_once >>"$SNAP_LOG"
    rotate_if_needed "$SNAP_LOG" "$SNAP_MAX_BYTES"
    sleep "$SNAP_INTERVAL"
  done
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `chmod 755 scripts/t3-cgroup-snap.sh && bash tests/t3-cgroup-snap.test.sh`
Expected: last line `t3-cgroup-snap: pass=17 fail=0`, exit 0.

- [ ] **Step 5: Lint**

Run: `shellcheck scripts/t3-cgroup-snap.sh tests/t3-cgroup-snap.test.sh`
Expected: no NEW findings vs. sibling `scripts/t3-watchdog.sh` / `scripts/t3-migrate-idle.sh` baseline (the pre-existing SC2034 for `LOG_TAG` / info SC1091 patterns are fine; the SC2012 "use find not ls" on siblings is fine too). Fix any real findings — do NOT suppress.

- [ ] **Step 6: Regression-check the sibling tests**

Run: `bash tests/t3-watchdog-gate.test.sh && bash tests/t3-migrate-idle-gate.test.sh`
Expected: both `fail=0` (this task touched nothing they depend on — cheap invariant).

- [ ] **Step 7: Commit**

```bash
cd ~/code/infra/.worktrees/t3-cgroup-snap
gcgit add scripts/t3-cgroup-snap.sh tests/t3-cgroup-snap.test.sh
gcgit commit -m "t3-cgroup-snap: diagnostic snapshotter for t3-serve cgroup

Sample every process in every t3-serve@<user> cgroup at 5s cadence;
append one JSONL line per (snapshot,pid) with (pid,ppid,uid,rss,comm,
exe,argv[:512]) to /var/log/t3-cgroup-snap.jsonl; in-script rotate at
50 MiB x 3 slots (150 MiB cap). Pure functions (read_pid_status,
emit_line, rotate_if_needed) unit-tested against a fixture /proc.
Diagnostic only: identifies the recurring 5-7 GiB Comm='2.1.205'
process ballooning wizard's cgroup (2026-07-08 + 2026-07-09 OOMs)
so we can decide on a targeted mitigation. Design:
docs/plans/2026-07-09-t3-cgroup-snap-design.md.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: systemd unit + setup-devvm wiring

**Files:**
- Create: `scripts/t3-cgroup-snap.service`
- Modify: `scripts/workstation/setup-devvm.sh` (§9a install block, §9d unit list, §9d enable line)

- [ ] **Step 1: Create `scripts/t3-cgroup-snap.service`**

```ini
[Unit]
# Design: docs/plans/2026-07-09-t3-cgroup-snap-design.md
# Runbook: docs/runbooks/t3-cgroup-snap.md
# Diagnostic: identifies the recurring 5-7 GiB Comm='2.1.205' OOM victim
# in t3-serve@wizard so we can pick a targeted mitigation. Removed in
# the same PR that lands the mitigation.
Description=t3-serve cgroup process-level snapshotter (diagnostic)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/t3-cgroup-snap
Restart=on-failure
RestartSec=15
# Read /proc for other users + write /var/log -> root; unavoidable.
# Own memory footprint is trivial (bash loop) - no MemoryMax needed;
# don't want this to live in t3-serve@'s cgroup either.
StandardOutput=journal
StandardError=journal
# Diagnostic isn't security-sensitive but tighten low-cost surface:
ProtectSystem=strict
ReadWritePaths=/var/log
ProtectHome=read-only
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Wire into `scripts/workstation/setup-devvm.sh`**

Three edits — Read that file first to find the current line numbers (the previous t3-watchdog commit landed on master, so numbers may have shifted).

Locate the §9a install block (starts with `# 9a) scripts the units exec`, contains lines like `install -m 0755 "$SCRIPTS/t3-watchdog.sh"     /usr/local/bin/t3-watchdog`). Add BELOW the `t3-watchdog.sh` install:

```bash
install -m 0755 "$SCRIPTS/t3-cgroup-snap.sh"  /usr/local/bin/t3-cgroup-snap
```

Locate the §9d `for u in ...` unit list (contains `t3-watchdog.service t3-watchdog.timer \`). Add BELOW that line:

```bash
         t3-cgroup-snap.service \
```

Locate the §9d `systemctl enable --now` line (contains `t3-watchdog.timer >/dev/null 2>&1 || \`). Extend it to include the new service — insert `t3-cgroup-snap.service` before the `>/dev/null` redirect:

```bash
systemctl enable --now t3-dispatch.service \
  t3-autoupdate.timer t3-backup-state.timer t3-provision-users.timer t3-migrate-idle.timer t3-watchdog.timer t3-cgroup-snap.service >/dev/null 2>&1 || \
```

(The exact "before" line is what's currently in the repo — merge the three timers + `t3-watchdog.timer` + the new `t3-cgroup-snap.service` on one line, preserving the trailing `\` and the `|| \` continuation.)

- [ ] **Step 3: Lint the touched shell**

```bash
S=/tmp/claude-1000/-/004779bc-7db4-4a19-bd91-fd9af6a94dbe/scratchpad
shellcheck scripts/workstation/setup-devvm.sh >"$S/sc-after.txt" 2>&1 || true
gcgit stash -q
shellcheck scripts/workstation/setup-devvm.sh >"$S/sc-before.txt" 2>&1 || true
gcgit stash pop -q
diff "$S/sc-before.txt" "$S/sc-after.txt" && echo 'NO NEW SHELLCHECK FINDINGS'
```
Expected: empty diff, message printed.

- [ ] **Step 4: Commit**

```bash
gcgit add scripts/t3-cgroup-snap.service scripts/workstation/setup-devvm.sh
gcgit commit -m "t3-cgroup-snap: systemd unit + setup-devvm install/enable wiring

Long-lived Type=simple service (matches nfs-change-tracker.service
shape); installed + enabled by setup-devvm.sh §9 like the other t3
timers so a devvm rebuild reproduces the diagnostic.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Runbook + post-mortem addendum

**Files:**
- Create: `docs/runbooks/t3-cgroup-snap.md`
- Modify: `docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md` (append after Addendum 2)

- [ ] **Step 1: Write `docs/runbooks/t3-cgroup-snap.md`**

```markdown
# t3-cgroup-snap — diagnostic snapshotter for t3-serve cgroups

**What:** `t3-cgroup-snap.service` on the devvm samples every process in every
`t3-serve@<user>` cgroup every 5 s and appends one JSONL line per (snapshot,
pid) to `/var/log/t3-cgroup-snap.jsonl` (rotated at 50 MiB × 3 = 150 MiB max).
Diagnostic only, deployed 2026-07-09 to identify the recurring 5-7 GiB
`Comm='2.1.205'` OOM victim in `t3-serve@wizard`. **Removed in the same PR
that lands the eventual mitigation** — this is not permanent infrastructure.
Design: `../plans/2026-07-09-t3-cgroup-snap-design.md`.

## Look up the last OOM's identity

```bash
# 1. When + who did the kernel kill?
sudo journalctl -k --since -24h --no-pager | grep -B1 "Killed process"
# -> ... "Killed process 2544629 (2.1.205)..." at 22:26:44

# 2. What was that PID actually running (last snapshot before the kill)?
jq -c 'select(.pid==2544629)' /var/log/t3-cgroup-snap.jsonl* | tail -1
# -> full argv; identifies the tool.

# 3. Who launched it? (if the target's argv is unhelpful, e.g. a python subprocess)
PPID=$(jq -r 'select(.pid==2544629) | .ppid' /var/log/t3-cgroup-snap.jsonl* | tail -1)
jq -c "select(.pid==$PPID)" /var/log/t3-cgroup-snap.jsonl* | tail -1

# 4. Top-N heaviest processes in wizard's cgroup at the moment of the kill:
jq -c 'select(.user=="wizard" and .ts>="2026-07-09T22:26:35Z" and .ts<="2026-07-09T22:26:45Z")' \
   /var/log/t3-cgroup-snap.jsonl* | jq -sr 'sort_by(.rss_kb)|reverse|.[:10][]|"\(.rss_kb) \(.comm) \(.argv[:80])"'
```

## Health

Silent = suspicious. Baseline: one line per active PID per 5 s. A single
`t3-serve@wizard` with 5 running processes = 60 lines/min.

```bash
systemctl status t3-cgroup-snap.service --no-pager       # active (running)
tail -3 /var/log/t3-cgroup-snap.jsonl | jq .              # freshest lines parseable
du -shc /var/log/t3-cgroup-snap.jsonl*                    # ≤ 150 MiB total
```

If the service dies: `Restart=on-failure` brings it back within 15 s. If it
loops-restarting: `journalctl -u t3-cgroup-snap -n 50` shows the bash error.

## Retire (when the mitigation lands)

Same commit that adds the mitigation should:

```bash
sudo systemctl disable --now t3-cgroup-snap.service
sudo rm -f /var/log/t3-cgroup-snap.jsonl*
sudo rm -f /etc/systemd/system/t3-cgroup-snap.service /usr/local/bin/t3-cgroup-snap
sudo systemctl daemon-reload
```
… and the corresponding source removal from the infra repo:
`scripts/t3-cgroup-snap.*`, `tests/t3-cgroup-snap.test.sh`, unwire from
`scripts/workstation/setup-devvm.sh` §9a and §9d, this runbook, and the
post-mortem addendum pointer.
```

- [ ] **Step 2: Append to the 2026-06-22 post-mortem**

Find the "Addendum 2 (2026-07-09):" section (added by the t3-watchdog work).
Append after its closing paragraph:

```markdown

## Addendum 3 (2026-07-10): still-unidentified 5-7 GiB balloon — diagnostic deployed

Two more cgroup-OOMs on 2026-07-09 22:26:44 + 22:27:29 killed the same
`Comm='2.1.205'` subprocess pattern as 2026-07-08 (5.4 GiB anon RSS this
time; ~10 GiB then). No installed tool reports version 2.1.205 — this is a
`prctl(PR_SET_NAME)`-renamed subprocess whose real identity isn't in the
kernel OOM record. Deployed `t3-cgroup-snap` (`scripts/t3-cgroup-snap.sh`,
long-lived service, 5 s cadence) to snapshot every process in every
`t3-serve@<user>` cgroup with full argv, so the next OOM's killed PID can
be resolved to its real tool. Diagnostic-only; the mitigation lands in the
PR that removes the snapshotter.
Runbook: `../runbooks/t3-cgroup-snap.md`; design:
`../plans/2026-07-09-t3-cgroup-snap-design.md`.
```

- [ ] **Step 3: Commit**

```bash
gcgit add docs/runbooks/t3-cgroup-snap.md docs/post-mortems/2026-06-22-devvm-mem-io-overload-containment.md
gcgit commit -m "docs: t3-cgroup-snap runbook + PM addendum 3

Operator recipe for looking up an OOM'd PID's real argv in the
snapshotter log, plus explicit retire-checklist so this diagnostic
doesn't outlive its purpose. Same-commit PM addendum records the
2026-07-09 22:26/22:27 OOMs and the diagnostic response.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Land on master

- [ ] **Step 1: Merge latest master into the branch, re-verify**

```bash
cd ~/code/infra/.worktrees/t3-cgroup-snap
gcgit fetch forgejo
gcgit merge forgejo/master --no-edit          # resolve if any (unlikely — separate stack)
bash tests/t3-cgroup-snap.test.sh | tail -1
bash tests/t3-watchdog-gate.test.sh | tail -1
bash tests/t3-migrate-idle-gate.test.sh | tail -1
shellcheck scripts/t3-cgroup-snap.sh
```
Expected: merge clean, three test summaries all `fail=0`, shellcheck silent.

- [ ] **Step 2: Push to master**

```bash
gcgit push forgejo HEAD:master
```
Non-fast-forward → `gcgit fetch forgejo && gcgit merge forgejo/master`, re-verify step 1, push again.

- [ ] **Step 3: Watch Woodpecker apply**

The push triggers `.woodpecker/default.yml` (`monitoring` stack shouldn't change — this commit only adds `scripts/` + `docs/` + edits `setup-devvm.sh`, none of which are Terraform-managed). Confirm the pipeline goes green:

```bash
homelab ci watch "$(cd ~/code/infra && gcgit rev-parse HEAD)"
```

Expected: green (no-op apply, just the tag advance).

---

### Task 5: Deploy to the devvm + healthy-sample verification

- [ ] **Step 1: Presence claim** (service starts on shared devvm)

```bash
~/code/scripts/presence claim infra:devvm-t3-cgroup-snap \
  --purpose "install+enable t3-cgroup-snap diagnostic (identify recurring 2.1.205 OOM culprit)"
```
If already claimed: release yours, surface to Viktor, wait for OK.

- [ ] **Step 2: Pull master, targeted install of the new files**

```bash
cd ~/code/infra
gcgit pull --ff-only forgejo master
sudo install -m 0755 scripts/t3-cgroup-snap.sh /usr/local/bin/t3-cgroup-snap
sudo install -m 0644 scripts/t3-cgroup-snap.service /etc/systemd/system/t3-cgroup-snap.service
sudo systemctl daemon-reload
sudo systemctl enable --now t3-cgroup-snap.service
```
Expected: no output errors, unit enabled.

- [ ] **Step 3: Verify healthy sample cycle**

```bash
sleep 20                                          # let it accumulate ~4 snapshots
systemctl is-active t3-cgroup-snap.service        # active
ls -la /var/log/t3-cgroup-snap.jsonl              # exists, non-empty
tail -3 /var/log/t3-cgroup-snap.jsonl | jq -e .   # parses cleanly (exit 0)
# per-user coverage: expect ≥1 line per t3-serve@* user
jq -r .user /var/log/t3-cgroup-snap.jsonl | sort -u
# recent wizard sample includes the FOUR concurrent claudes + t3 main:
jq -c 'select(.user=="wizard" and .ts>=(now-30|todate))' /var/log/t3-cgroup-snap.jsonl | wc -l
```
Expected: `active`, non-empty file, `jq -e .` exit 0, user list matches
`systemctl list-units 't3-serve@*.service' --state=running`.

- [ ] **Step 4: Release presence**

```bash
~/code/scripts/presence release infra:devvm-t3-cgroup-snap
```

---

### Task 6: Cleanup + soak handoff

- [ ] **Step 1: Remove the worktree, sync main checkout**

```bash
cd ~/code/infra
gcgit pull --ff-only forgejo master
gcgit worktree remove .worktrees/t3-cgroup-snap
gcgit branch -d wizard/t3-cgroup-snap
gcgit worktree list
```
Expected: worktree gone from the list; main checkout on `ca74adc8` or newer.

- [ ] **Step 2: Wait for the next OOM (~24 h; two OOMs in the last 2 days)**

Nothing to do actively. When the next cgroup OOM fires the watchdog will safe-restart the wounded instance, and the snapshotter log will contain the last snapshot before the kill. Look it up per the runbook (Task 3, "Look up the last OOM's identity" section). Report the identified tool to Viktor and open the follow-up task for the targeted mitigation.

- [ ] **Step 3: (After identification) file follow-up work + retire the diagnostic**

The follow-up is a NEW brainstorm→design→plan cycle for the targeted mitigation, and that PR includes the "Retire" checklist from the runbook (Task 3): disable + remove the service, source, tests, runbook, and PM addendum pointer.

## Self-review

**Spec coverage.** Every section of `docs/plans/2026-07-09-t3-cgroup-snap-design.md` has a task: shape (T1+T2), argv handling / permissions / missing-file tolerance / rotation (T1), startup and teardown (T2+T6), analysis path (T3 runbook), testing (T1 unit + T5 live smoke), deployment (T2 + T4 + T5), docs updates (T3), rejected alternatives (not implemented; recorded in the spec itself — no task needed).

**Placeholder scan.** No TBD / TODO / "add validation" / "similar to Task N". Every step has code or exact commands. `scripts/workstation/setup-devvm.sh` line-numbers are deliberately NOT hardcoded — the task tells the executor to grep because the t3-watchdog commit that landed earlier today shifted them.

**Type consistency.** Function names (`read_pid_status`, `emit_line`, `rotate_if_needed`, `users_with_cgroup`, `snapshot_once`, `main`) match between the tests (T1S1), the script (T1S3), and the runbook (T3S1). JSONL keys (`ts`, `user`, `pid`, `ppid`, `uid`, `rss_kb`, `comm`, `exe`, `argv`) match between spec, tests, and script.

**Nits fixed inline.** (a) De-duped the `emit_line` implementation (draft had two definitions); the single canonical version stands. (b) Kept `read_pid_status` even after collapsing `emit_line` — it's a distinct pure function the unit test exercises directly, and separating "extract from status/comm" from "assemble full record" keeps each function small enough to test standalone.
