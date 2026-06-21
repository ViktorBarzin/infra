# t3 idle-migrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small idle-gated overnight job that restarts a `t3-serve@<user>` deferred by the daily autoupdate, so a chronically-busy user's server migrates onto the current t3 binary during a real quiet gap instead of staying version-skewed for days.

**Architecture:** Extract the daily job's per-unit "dangerous" restart routine (backup→restart→verify→recover) into a sourced shared library `t3-safe-restart.sh`; the daily `t3-autoupdate` and a new `t3-migrate-idle` job both call it. The daily job records each deferral as a marker file; the new job drains markers overnight, restarting only when `state.sqlite` shows no in-flight turn and a quiet buffer has elapsed. Self-limiting (only acts on a recorded deferral), fail-closed.

**Tech Stack:** bash, systemd timers, sqlite3 (reading t3's `state.sqlite`), the existing `t3-autoupdate` machinery. Deployed via `scripts/workstation/setup-devvm.sh` on the hand-managed devvm (no Terraform).

**Design:** `docs/plans/2026-06-21-t3-idle-migrate-design.md`.

---

## File structure

- **Create `scripts/t3-safe-restart.sh`** — sourced library: shared config defaults, `LOG`/`ver`/`osusers`/`ak_for`/`verify_pairing`/`backup_user`/`prebump_of`/`rollback_binary`, and `safe_restart_unit`. One responsibility: the audited per-unit safe restart + its recovery.
- **Modify `scripts/t3-autoupdate.sh`** — source the lib; replace the inline helpers + step-6 body with calls into it; write/clear the deferral marker. Behavior unchanged.
- **Create `scripts/t3-migrate-idle.sh`** — the new job: the idle gate (`gate_query`/`gate_is_safe`/`safe_to_restart`) + the marker-drain loop. Main logic behind a `main`-guard so it's source-safe for tests.
- **Create `scripts/t3-migrate-idle.service`** + **`scripts/t3-migrate-idle.timer`** — oneshot + overnight timer.
- **Create `tests/t3-migrate-idle-gate.test.sh`** — pure-bash TDD for the gate predicates against fixture SQLite DBs (no root, no bats).
- **Modify `scripts/workstation/setup-devvm.sh`** — install + enable the new files.
- **Modify `docs/runbooks/t3-version-bump.md`** + **`.claude/reference/service-catalog.md`** — document the new job.

**Recovery semantics note (load-bearing):** `safe_restart_unit` is reused verbatim. In the *daily* path a canary failure happens when `last_good < target`, so its `rollback_binary` genuinely reverts the global binary (correct — a bad build is bad for everyone). In the *idle* path `last_good == installed == target` (the build was already accepted), so `rollback_binary` is a **harmless no-op reinstall** — recovery reduces to "restore the failing user's DB + freeze + alert" and does NOT downgrade other users. Known rare-tail limitation: if that user's forward migration genuinely fails at idle time (already gated against a copy of their real DB at install), their server may crashloop on the restored DB until a human acts on the freeze+alert. Documented, not hidden.

---

## Task 1: Shared library `t3-safe-restart.sh`

**Files:**
- Create: `scripts/t3-safe-restart.sh`

- [ ] **Step 1: Create the library**

```bash
#!/usr/bin/env bash
# t3-safe-restart.sh — SOURCED library (not executed). Shared by t3-autoupdate.sh
# (daily gated tracker) and t3-migrate-idle.sh (overnight deferral drainer).
#
# Holds the per-unit "dangerous" routine — backup -> restart -> verify pairing ->
# recover (restore DB + roll global binary back to last-good + freeze) — extracted
# verbatim from t3-autoupdate.sh step 6, plus the small helpers it depends on.
# The only change from the inline original: safe_restart_unit RETURNS non-zero on
# failure (after performing recovery+freeze) instead of `exit 1`, so the CALLER
# decides what to do (the daily job exits; the idle job stops draining).
#
# Callers must set, before calling safe_restart_unit: $target (version being moved
# TO, for log lines + the prebump filename) and $last_good (rollback target).
# Set $LOG_TAG before sourcing to tag syslog ("t3-autoupdate" / "t3-migrate-idle").

# ---- shared config defaults (override via env before sourcing) ------------------
: "${LOG_TAG:=t3-safe-restart}"
: "${FREEZE_FILE:=/etc/t3-autoupdate.freeze}"
: "${STATE_DIR:=/var/lib/t3-autoupdate}"
: "${LAST_GOOD_FILE:=$STATE_DIR/last-good}"
: "${DEFER_DIR:=$STATE_DIR/deferred}"
: "${BACKUP_DIR:=/var/backups/t3-state}"
: "${DISPATCH:=127.0.0.1:3780}"
: "${USER_MAP:=/etc/ttyd-user-map}"
: "${T3_BACKUP_TIMEOUT:=900}"

LOG() { logger -t "$LOG_TAG" "$*"; echo "$LOG_TAG: $*"; }
ver() { t3 --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//'; }
# OS users owning a ~/.t3 (RHS of each non-comment "authentik=os_user" map line).
osusers() { awk -F= '!/^[[:space:]]*#/&&NF==2{gsub(/[[:space:]]/,"",$2);print $2}' "$USER_MAP" 2>/dev/null | sort -u; }
# authentik username for an OS user (reverse map; first match) — for dispatch verify.
ak_for() { awk -F= -v u="$1" '!/^[[:space:]]*#/&&NF==2{gsub(/[[:space:]]/,"",$1);gsub(/[[:space:]]/,"",$2);if($2==u){print $1;exit}}' "$USER_MAP" 2>/dev/null; }

# Online consistent snapshot of ONE user's state.sqlite (run AS the owner so the
# WAL stays owned; never stops the serve). Uses global $target for the filename.
# Echoes the backup path on success; non-zero on failure.
backup_user() {
  local u="$1" src out dst ts
  src="/home/$u/.t3/userdata/state.sqlite"; [ -f "$src" ] || return 1
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$BACKUP_DIR/$u"; dst="$out/state-prebump-$target-$ts.sqlite"
  install -d -o "$u" -g "$u" -m700 "$out" 2>/dev/null || mkdir -p "$out"
  if runuser -u "$u" -- timeout "$T3_BACKUP_TIMEOUT" sqlite3 "$src" "VACUUM INTO '$dst'" 2>/dev/null && [ -s "$dst" ]; then
    printf '%s\n' "$dst"; return 0
  fi
  rm -f "$dst"; return 1
}

# newest pre-bump backup for a user taken for the current $target (restore source).
prebump_of() { ls -1t "$BACKUP_DIR/$1/state-prebump-$target-"*.sqlite 2>/dev/null | head -1; }

# roll the GLOBAL binary back to last-good. In the idle path last_good==installed,
# so this is a harmless no-op reinstall (does NOT downgrade other users).
rollback_binary() {
  LOG "rolling back binary $target -> $last_good"
  if npm i -g "t3@$last_good" >/dev/null 2>&1; then LOG "rolled back to $last_good"; return 0; fi
  LOG "ROLLBACK FAILED — could not reinstall t3@$last_good (t3 may be broken; manual fix per runbook)"; return 1
}

# verify a user's pairing through the REAL dispatch (mint -> exchange -> cookie).
verify_pairing() {
  local u="$1" ak out; ak="$(ak_for "$u")"; [ -n "$ak" ] || { LOG "no authentik mapping for $u — skipping dispatch verify"; return 0; }
  out="$(curl -s -i --max-time 10 -H "X-authentik-username: $ak" -H 'Sec-Fetch-Dest: document' "http://$DISPATCH/" 2>/dev/null)"
  printf '%s' "$out" | grep -qi '^set-cookie:[[:space:]]*t3_session='
}

# safe_restart_unit <unit> <user>: restart the unit, verify pairing; on failure
# restore the user's DB from its pre-restart backup, roll the binary back, freeze.
# Assumes a pre-restart backup already exists for <user> at the current $target
# (the daily job's backup_all, or the idle job's backup_user, takes it first).
# Returns 0 on verified success, non-zero after recovery+freeze on failure.
safe_restart_unit() {
  local unit="$1" u="$2" ok=0 _ bak
  systemctl restart "$unit" || LOG "WARN: systemctl restart $unit returned non-zero"
  for _ in $(seq 1 15); do
    if verify_pairing "$u"; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" = "1" ]; then
    LOG "restarted $unit -> $target (pairing verified via dispatch)"; return 0
  fi
  LOG "HEALTH-CHECK FAILED: $u pairing broken AFTER restart onto $target — rolling back + restoring its DB"
  rollback_binary
  bak="$(prebump_of "$u")"
  if [ -n "$bak" ]; then
    systemctl stop "$unit" 2>/dev/null
    if install -o "$u" -g "$u" -m600 "$bak" "/home/$u/.t3/userdata/state.sqlite" 2>/dev/null; then
      rm -f "/home/$u/.t3/userdata/state.sqlite-wal" "/home/$u/.t3/userdata/state.sqlite-shm"
      LOG "restored $u state.sqlite from $bak"
    fi
    systemctl start "$unit" 2>/dev/null
  fi
  touch "$FREEZE_FILE" 2>/dev/null
  LOG "FROZEN ($FREEZE_FILE) after $u failed on $target; last_good stays $last_good — investigate, then remove the freeze file to resume"
  return 1
}
```

- [ ] **Step 2: Syntax + lint check**

Run: `bash -n scripts/t3-safe-restart.sh && (command -v shellcheck >/dev/null && shellcheck -x scripts/t3-safe-restart.sh || echo "shellcheck absent — skipped")`
Expected: no syntax errors. (shellcheck may warn on the intentional global `$target`/`$last_good` references — acceptable; they are documented caller-set globals.)

- [ ] **Step 3: Source-and-define smoke test**

Run:
```bash
bash -c 'LOG_TAG=test; . scripts/t3-safe-restart.sh; for f in LOG ver osusers ak_for backup_user prebump_of rollback_binary verify_pairing safe_restart_unit; do declare -F "$f" >/dev/null || { echo "MISSING $f"; exit 1; }; done; echo "all functions defined"'
```
Expected: `all functions defined` (sourcing has no side effects — no exit, no output beyond the echo).

- [ ] **Step 4: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/t3-safe-restart.sh
git "${GC[@]}" commit -m "t3-safe-restart: extract shared safe-restart library from t3-autoupdate

Pull the per-unit backup->restart->verify->recover routine (and the small
helpers it needs) out of t3-autoupdate.sh into a sourced library, so a second
job (the upcoming idle migrator) can reuse the exact same audited recovery path
instead of forking safety-critical code. safe_restart_unit returns non-zero on
failure (after recovery+freeze) rather than exiting, so callers control flow.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Refactor `t3-autoupdate.sh` to use the library + record deferrals

**Files:**
- Modify: `scripts/t3-autoupdate.sh` (config block 32–42, helpers 44–165, step 6 loop 194–225)

- [ ] **Step 1: Source the library; drop the now-shared helpers**

Replace lines 32–52 (the `T3_*` config block through the `newer()` helper) with — keep the autoupdate-only config, source the lib for the shared bits:

```bash
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
```

(The lib now provides `FREEZE_FILE`, `STATE_DIR`, `LAST_GOOD_FILE`, `DEFER_DIR`, `BACKUP_DIR`, `DISPATCH`, `USER_MAP`, `LOG`, `ver`, `osusers`, `ak_for`, `verify_pairing`, `prebump_of`, `rollback_binary`, `backup_user`, `safe_restart_unit`.)

- [ ] **Step 2: Simplify `backup_all` to call the shared `backup_user`**

Replace the `backup_all()` definition (lines 90–105) with:

```bash
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
```

Delete the now-duplicated standalone `prebump_of`, `rollback_binary`, and `verify_pairing` definitions (lines 107–108, 146–152, 160–165) — they come from the lib. Keep `health_check` and `unit_busy` (autoupdate-only).

- [ ] **Step 3: Use `safe_restart_unit` + write/clear the deferral marker in step 6**

Replace the step-6 loop body (lines 196–225) with:

```bash
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
```

- [ ] **Step 4: Syntax check + behavior-preserving dry-run diff**

Run:
```bash
bash -n scripts/t3-autoupdate.sh
# Confirm the only remaining defer/restart decisions are unchanged vs HEAD~1 logic:
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false diff HEAD scripts/t3-autoupdate.sh | grep -E '^\+|^-' | grep -vE 'safe_restart_unit|backup_user|DEFER_DIR|source|\. "|LOG_TAG|^\+\+\+|^---' | head -40
```
Expected: no syntax errors; the diff shows only the extraction (calls replacing inline bodies) + the two marker lines — no change to install/health-gate/canary decision logic.

- [ ] **Step 5: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/t3-autoupdate.sh
git "${GC[@]}" commit -m "t3-autoupdate: source the shared safe-restart lib + record deferrals

Behavior-preserving refactor: the per-unit restart/recover body and small helpers
now come from t3-safe-restart.sh (one audited copy). Additionally, when a unit is
deferred for an active agent, write a marker under /var/lib/t3-autoupdate/deferred/
so the new idle migrator can drain it later; clear the marker on a successful
restart. Install/health-gate/canary logic is unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: The idle gate (TDD) — `gate_query` + `gate_is_safe`

**Files:**
- Create: `tests/t3-migrate-idle-gate.test.sh`
- Create (incremental): `scripts/t3-migrate-idle.sh` (gate functions only this task)

- [ ] **Step 1: Write the failing test**

Create `tests/t3-migrate-idle-gate.test.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash unit tests for the t3-migrate-idle gate. No root, no bats, no Docker.
# Sources t3-migrate-idle.sh (main-guarded) with the lib path pointed at the worktree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (tests/ is one level down)
export T3_SAFE_RESTART_LIB="$HERE/scripts/t3-safe-restart.sh"
# shellcheck source=/dev/null
. "$HERE/scripts/t3-migrate-idle.sh"        # defines functions; main-guard prevents the drain from running

pass=0; fail=0
ok()   { if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $*"; fi; }
notok(){ if "$@"; then fail=$((fail+1)); echo "FAIL (expected non-zero): $*"; else pass=$((pass+1)); fi; }

# --- gate_is_safe <active> <idle_seconds> with QUIET_SECONDS=900 ---
QUIET_SECONDS=900
ok    gate_is_safe 0 1000      # idle, quiet long enough -> safe
notok gate_is_safe 1 1000      # a turn in flight -> unsafe
notok gate_is_safe 0 100       # idle but not quiet enough -> unsafe
ok    gate_is_safe 0 ""        # no threads at all (NULL idle) -> safe
notok gate_is_safe x 1000      # unparseable active -> unsafe
notok gate_is_safe 0 -30       # negative idle (clock skew) -> unsafe

# --- gate_query <db> against fixture SQLite DBs ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkfix() { # mkfix <file> ; reads rows "active_turn_id|updated_at" on stdin
  local f="$1"; sqlite3 "$f" "CREATE TABLE projection_thread_sessions(active_turn_id TEXT, updated_at TEXT NOT NULL);"
  while IFS='|' read -r a u; do sqlite3 "$f" "INSERT INTO projection_thread_sessions VALUES ($([ "$a" = NULL ] && echo NULL || echo "'$a'"), '$u');"; done
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
OLD="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"

# active turn present -> "1|<small idle>"
printf '%s\n' "abc|$NOW" "NULL|$OLD" | mkfix "$TMP/active.db"
res="$(gate_query "$TMP/active.db")"; ok test "${res%%|*}" = "1"

# all idle, last activity 1h ago -> "0|>=3500"
printf '%s\n' "NULL|$OLD" "NULL|$OLD" | mkfix "$TMP/idle.db"
res="$(gate_query "$TMP/idle.db")"; ok test "${res%%|*}" = "0"; ok test "${res##*|}" -ge 3500

# empty table -> "0|" (NULL idle)
sqlite3 "$TMP/empty.db" "CREATE TABLE projection_thread_sessions(active_turn_id TEXT, updated_at TEXT NOT NULL);"
res="$(gate_query "$TMP/empty.db")"; ok test "${res%%|*}" = "0"

echo "PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/t3-migrate-idle-gate.test.sh`
Expected: FAIL — `scripts/t3-migrate-idle.sh` does not exist yet (source error).

- [ ] **Step 3: Create `scripts/t3-migrate-idle.sh` with the gate functions + main-guard skeleton**

```bash
#!/usr/bin/env bash
# t3-migrate-idle.sh — drains t3-autoupdate's deferral markers (via the overnight
# t3-migrate-idle.timer). For each deferred t3-serve@<user>, if nothing is actively
# working in that instance (no in-flight turn + a quiet buffer), restart it onto the
# current binary using the shared safe_restart_unit, then clear the marker.
# Why this exists: t3-autoupdate defers a user with an active agent at its single
# daily window; a user busy every night never migrates and their client shows
# "Client and server versions differ". See docs/plans/2026-06-21-t3-idle-migrate-*.
set -uo pipefail

LOG_TAG=t3-migrate-idle
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

QUIET_SECONDS="${T3_MIGRATE_QUIET_SECONDS:-900}"   # required idle before a restart (15 min)
DRY_RUN="${T3_DRY_RUN:-0}"

# pure logic: is it safe given <active_turns> and <idle_seconds>? fail closed.
gate_is_safe() {
  local active="$1" idle="$2"
  case "$active" in ''|*[!0-9]*) return 1;; esac     # unparseable/empty active -> unsafe
  [ "$active" -eq 0 ] || return 1                     # a turn is running -> unsafe
  [ -z "$idle" ] && return 0                          # no threads at all -> safe
  case "$idle" in ''|*[!0-9-]*) return 1;; esac       # non-numeric -> unsafe
  [ "$idle" -ge "$QUIET_SECONDS" ]                    # negative or < quiet -> unsafe
}

# query a state.sqlite (path or file: URI). Echoes "<active_turns>|<idle_seconds>".
# idle_seconds is empty when there are no rows. Normalizes ISO 'T'/'Z' for julianday.
gate_query() {
  local db="$1"
  sqlite3 -batch -noheader -separator '|' "$db" \
    "SELECT
       (SELECT count(*) FROM projection_thread_sessions WHERE active_turn_id IS NOT NULL),
       CAST((julianday('now') - julianday(replace(replace(max(updated_at),'T',' '),'Z',''))) * 86400 AS INT)
     FROM projection_thread_sessions;"
}

# safe_to_restart <user>: wire runuser + the user's DB into gate_query/gate_is_safe.
safe_to_restart() {
  local u="$1" db row
  db="/home/$u/.t3/userdata/state.sqlite"; [ -f "$db" ] || return 1
  row="$(runuser -u "$u" -- sqlite3 -batch -noheader -separator '|' "file:$db?mode=ro" \
    "SELECT
       (SELECT count(*) FROM projection_thread_sessions WHERE active_turn_id IS NOT NULL),
       CAST((julianday('now') - julianday(replace(replace(max(updated_at),'T',' '),'Z',''))) * 86400 AS INT)
     FROM projection_thread_sessions;" 2>/dev/null)" || return 1
  gate_is_safe "${row%%|*}" "${row##*|}"
}

main() {
  :   # drain loop added in Task 4
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/t3-migrate-idle-gate.test.sh`
Expected: `PASS=10 FAIL=0` (exit 0).

- [ ] **Step 5: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/t3-migrate-idle.sh tests/t3-migrate-idle-gate.test.sh
git "${GC[@]}" commit -m "t3-migrate-idle: idle gate (no in-flight turn + quiet buffer), TDD

The gate reads t3's state.sqlite: safe to restart only when zero threads have an
active_turn_id AND the most-recent thread activity is older than the quiet buffer
(default 15m). Fail-closed on any parse/query error. Pure-bash unit tests cover
the boundaries against fixture DBs (no root/bats/Docker).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: The marker-drain loop in `t3-migrate-idle.sh`

**Files:**
- Modify: `scripts/t3-migrate-idle.sh` (replace the `main()` skeleton)

- [ ] **Step 1: Implement `main()` (the drain loop)**

Replace the `main() { : ; }` skeleton with:

```bash
main() {
  # a frozen build must not be auto-migrated (shared switch with t3-autoupdate)
  if [ -e "$FREEZE_FILE" ]; then LOG "FROZEN: $FREEZE_FILE present — not draining deferrals"; exit 0; fi
  [ -d "$DEFER_DIR" ] || exit 0                       # nothing deferred
  last_good="$(tr -d '[:space:]' <"$LAST_GOOD_FILE" 2>/dev/null)"   # rollback target for the helper

  local marker u unit started mwritten migrated=0 skipped=0
  for marker in "$DEFER_DIR"/*; do
    [ -e "$marker" ] || continue                      # empty-dir glob
    u="$(basename "$marker")"; unit="t3-serve@$u.service"
    if ! systemctl is-active --quiet "$unit"; then
      LOG "clearing marker for $u: $unit not active"; rm -f "$marker"; continue
    fi
    started="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)" +%s 2>/dev/null || echo 0)"
    mwritten="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"
    if [ "$started" -gt "$mwritten" ]; then
      LOG "clearing marker for $u: $unit already restarted $((started-mwritten))s after the deferral"; rm -f "$marker"; continue
    fi
    if ! safe_to_restart "$u"; then skipped=$((skipped+1)); continue; fi

    target="$(tr -d '[:space:]' <"$marker" 2>/dev/null)"; [ -n "$target" ] || target="$(ver)"
    if [ "$DRY_RUN" = "1" ]; then LOG "DRY_RUN: would migrate $unit -> $target (idle gate satisfied)"; continue; fi
    if ! backup_user "$u" >/dev/null; then
      LOG "WARN: pre-restart backup failed for $u — skipping (fail closed)"; skipped=$((skipped+1)); continue
    fi
    if safe_restart_unit "$unit" "$u"; then
      LOG "migrated $unit -> $target (idle restart)"; rm -f "$marker"; migrated=$((migrated+1))
    else
      LOG "migrate FAILED for $unit — recovery+freeze handled by safe_restart_unit; stopping drain"; exit 1
    fi
  done
  LOG "idle-migrate pass complete (migrated=$migrated skipped=$skipped)"
}
```

- [ ] **Step 2: Re-run the gate tests (regression — main-guard still source-safe)**

Run: `bash tests/t3-migrate-idle-gate.test.sh`
Expected: `PASS=10 FAIL=0` (sourcing still defines functions without running the loop).

- [ ] **Step 3: Syntax + lint**

Run: `bash -n scripts/t3-migrate-idle.sh && (command -v shellcheck >/dev/null && shellcheck -x scripts/t3-migrate-idle.sh || echo "shellcheck absent — skipped")`
Expected: no syntax errors.

- [ ] **Step 4: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/t3-migrate-idle.sh
git "${GC[@]}" commit -m "t3-migrate-idle: drain deferral markers when safe

For each /var/lib/t3-autoupdate/deferred/<user> marker: skip+clear if the unit is
gone or was already restarted after the deferral; otherwise, when the idle gate is
satisfied, take a pre-restart backup and restart via the shared safe_restart_unit,
clearing the marker on verified success. DRY_RUN logs decisions without acting.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: systemd units

**Files:**
- Create: `scripts/t3-migrate-idle.service`, `scripts/t3-migrate-idle.timer`

- [ ] **Step 1: Create the service unit**

`scripts/t3-migrate-idle.service`:
```ini
[Unit]
Description=t3 idle migrator — restart deferred t3-serve instances onto the current binary when idle
Documentation=https://forgejo.viktorbarzin.me/viktor/infra/src/branch/master/docs/plans/2026-06-21-t3-idle-migrate-design.md
After=network.target t3-dispatch.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/t3-migrate-idle
```

- [ ] **Step 2: Create the timer unit**

`scripts/t3-migrate-idle.timer`:
```ini
[Unit]
Description=Overnight drain of t3-autoupdate deferrals (idle-gated t3-serve migration)

[Timer]
OnCalendar=*-*-* 01..05:00/20
RandomizedDelaySec=120
Persistent=false

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Validate unit syntax**

Run: `systemd-analyze verify scripts/t3-migrate-idle.service scripts/t3-migrate-idle.timer 2>&1 | grep -v 'Unknown\|Cannot find' || echo "units parse OK"`
Expected: no fatal parse errors (warnings about the `[Install]` of a non-installed unit / missing exec on a non-deployed path are acceptable in the worktree).

- [ ] **Step 4: Confirm the OnCalendar expands to the intended overnight slots**

Run: `systemd-analyze calendar '*-*-* 01..05:00/20' --iterations=5`
Expected: next elapses at 01:00/01:20/01:40/02:00/… (every 20 min, hours 01–05).

- [ ] **Step 5: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/t3-migrate-idle.service scripts/t3-migrate-idle.timer
git "${GC[@]}" commit -m "t3-migrate-idle: systemd oneshot + overnight timer (01:00-05:40, /20)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Wire into `setup-devvm.sh`

**Files:**
- Modify: `scripts/workstation/setup-devvm.sh` (9a install ~line 164; 9d unit loop ~line 200; enable ~line 218)

- [ ] **Step 1: Install the lib + the new script (section 9a)**

After the `install -m 0755 "$SCRIPTS/t3-autoupdate.sh" /usr/local/bin/t3-autoupdate` line, add:
```bash
install -m 0644 "$SCRIPTS/t3-safe-restart.sh" /usr/local/lib/t3-safe-restart.sh
install -m 0755 "$SCRIPTS/t3-migrate-idle.sh" /usr/local/bin/t3-migrate-idle
```

- [ ] **Step 2: Install the unit files (section 9d loop)**

Add to the `for u in …` unit list (after the `t3-autoupdate.service t3-autoupdate.timer \` line):
```bash
         t3-migrate-idle.service t3-migrate-idle.timer \
```

- [ ] **Step 3: Enable the timer (section 9 enable line)**

Append `t3-migrate-idle.timer` to the `systemctl enable --now` list:
```bash
systemctl enable --now t3-dispatch.service \
  t3-autoupdate.timer t3-backup-state.timer t3-provision-users.timer t3-migrate-idle.timer >/dev/null 2>&1 || \
  log "WARN: some units failed to enable (check: systemctl status t3-dispatch t3-*.timer)"
```

- [ ] **Step 4: Syntax check**

Run: `bash -n scripts/workstation/setup-devvm.sh`
Expected: no syntax errors.

- [ ] **Step 5: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add scripts/workstation/setup-devvm.sh
git "${GC[@]}" commit -m "setup-devvm: install + enable t3-migrate-idle (lib, script, units, timer)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Deploy to the devvm + validate (dry-run first)

**Files:** none (operational). Presence-claimed, shared-host mutation.

- [ ] **Step 1: Claim the host**

Run: `homelab claim host:devvm --purpose "deploy t3-migrate-idle units (idle-gated t3-serve migration)"`
Expected: claim acquired (if already held by another session, defer per CLAUDE.md).

- [ ] **Step 2: Install the artifacts (mirror setup-devvm.sh 9a/9d)**

Run:
```bash
W=/home/wizard/code/infra/.worktrees/t3-idle-migrate/scripts
sudo install -m 0644 "$W/t3-safe-restart.sh"      /usr/local/lib/t3-safe-restart.sh
sudo install -m 0755 "$W/t3-migrate-idle.sh"      /usr/local/bin/t3-migrate-idle
sudo install -m 0644 "$W/t3-migrate-idle.service" /etc/systemd/system/t3-migrate-idle.service
sudo install -m 0644 "$W/t3-migrate-idle.timer"   /etc/systemd/system/t3-migrate-idle.timer
sudo systemctl daemon-reload
```
Expected: no errors.

- [ ] **Step 2b: Re-point the live daily job at the installed lib (it now sources it)**

The deployed `/usr/local/bin/t3-autoupdate` is the OLD inline version until setup-devvm re-runs; install the refactored one so both jobs share the lib:
```bash
sudo install -m 0755 "$W/t3-autoupdate.sh" /usr/local/bin/t3-autoupdate
sudo /usr/local/bin/t3-autoupdate   # safe: same-version run exits at "already on nightly; nothing to do"
```
Expected: log line `already on <track>=<ver>; nothing to do` (proves the refactored daily job sources the lib and runs clean).

- [ ] **Step 3: DRY-RUN the idle migrator against live state**

Run: `sudo T3_DRY_RUN=1 /usr/local/bin/t3-migrate-idle; echo "exit=$?"`
Expected: with wizard currently busy (mid-turn during the day), a `skipped` count — `idle-migrate pass complete (migrated=0 skipped=N)` — and NO restart. (If wizard happens to be idle+quiet, it logs `DRY_RUN: would migrate t3-serve@wizard …` and still does not act.)

- [ ] **Step 4: Seed a deferral marker for the current skew + dry-run again**

The live daily job already deferred wizard but the marker mechanism is new, so create it once to represent the existing `.605→.613` debt:
```bash
sudo install -d -m755 /var/lib/t3-autoupdate/deferred
printf '%s\n' "$(t3 --version | awk '{print $NF}' | sed 's/^v//')" | sudo tee /var/lib/t3-autoupdate/deferred/wizard >/dev/null
sudo T3_DRY_RUN=1 /usr/local/bin/t3-migrate-idle; echo "exit=$?"
```
Expected: the pass now considers `wizard` — either `DRY_RUN: would migrate t3-serve@wizard.service -> …613` (if idle) or counted in `skipped` (if mid-turn). Confirms marker drain + gate wiring end-to-end without acting.

- [ ] **Step 5: Enable the timer (live)**

Run: `sudo systemctl enable --now t3-migrate-idle.timer && systemctl list-timers t3-migrate-idle.timer --no-pager`
Expected: timer active, next elapse in the 01:00–05:40 window.

- [ ] **Step 6: Release the claim**

Run: `homelab release host:devvm`

> **First live migration** happens overnight at the first idle+quiet tick. Verify next session: `journalctl -u t3-migrate-idle.service --since yesterday | grep -E 'migrated|skipped|DRY|FROZEN'` and `t3 --version` vs the running server's version. (The user-facing resume-after-restart is observed here — design open-question (a).)

---

## Task 8: Docs

**Files:**
- Modify: `docs/runbooks/t3-version-bump.md` (add an idle-migrate section)
- Modify: `.claude/reference/service-catalog.md` (add the unit)
- Modify: `docs/plans/2026-06-21-t3-idle-migrate-design.md` (Status → implemented)

- [ ] **Step 1: Runbook** — add a section after the autoupdate description:

```markdown
## Idle migrator (`t3-migrate-idle.timer`)

`t3-autoupdate` defers a user's `t3-serve` restart when they have an active agent
at the daily window, recording `/var/lib/t3-autoupdate/deferred/<user>`.
`t3-migrate-idle` (overnight, every 20 min 01:00–05:40) drains those markers:
it restarts a deferred instance onto the current binary only when that user's
`state.sqlite` shows no in-flight turn (`active_turn_id`) and ≥15 min quiet, via
the shared `safe_restart_unit` (same backup→verify→recover as the daily canary).
- **Force a migration now:** `sudo systemctl start t3-migrate-idle.service` (still idle-gated).
- **Preview without acting:** `sudo T3_DRY_RUN=1 /usr/local/bin/t3-migrate-idle`.
- **Stop it:** the shared `/etc/t3-autoupdate.freeze` halts both jobs.
- **Rare-tail failure:** a forward-migration failure at idle restart restores the
  user's DB + freezes + alerts (the binary rollback is a no-op since the build was
  already accepted); the user's server may crashloop on the restored DB until the
  freeze is cleared. Investigate per the rollback section above.
```

- [ ] **Step 2: service-catalog** — add a row/line for `t3-migrate-idle.timer` (overnight idle-gated t3-serve migration; sources `t3-safe-restart.sh`).

- [ ] **Step 3: design doc status** — change the header `Status:` to `implemented 2026-06-21 (commits on wizard/t3-idle-migrate)`.

- [ ] **Step 4: Commit**

```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" add docs/runbooks/t3-version-bump.md .claude/reference/service-catalog.md docs/plans/2026-06-21-t3-idle-migrate-design.md
git "${GC[@]}" commit -m "docs: t3-migrate-idle runbook + service-catalog + design status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Land

- [ ] **Step 1: Merge latest master into the branch**

Run:
```bash
GC=(-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false)
git "${GC[@]}" fetch forgejo
git "${GC[@]}" merge --no-edit forgejo/master
```
Expected: clean merge (no conflicts; the files are new or autoupdate-only). Resolve if any.

- [ ] **Step 2: Re-run the gate tests post-merge**

Run: `bash tests/t3-migrate-idle-gate.test.sh`
Expected: `PASS=10 FAIL=0`.

- [ ] **Step 3: Push to master**

Run: `git -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false push forgejo HEAD:master`
Expected: accepted. Non-fast-forward → fetch/merge/retry.

- [ ] **Step 4: Watch CI to completion**

Run: `homelab ci watch`
Expected: green (infra apply pipeline — this change is scripts/docs only, no Terraform, so apply is a no-op for it).

- [ ] **Step 5: Clean up the worktree**

Run (from the main checkout):
```bash
git -C /home/wizard/code/infra worktree remove .worktrees/t3-idle-migrate
git -C /home/wizard/code/infra branch -d wizard/t3-idle-migrate
```

---

## Self-review

- **Spec coverage:** marker mechanism (T2,T4) · shared safe-restart lib / approach C (T1) · idle gate active_turn_id+quiet (T3) · overnight timer (T5) · all-users self-limiting via markers (T4 loop) · failure recovery reuse (T1, note) · observability logs (LOG_TAG throughout) · delivery via setup-devvm (T6) · presence-claimed deploy (T7) · TDD on the gate (T3) · dry-run rollout (T7) · docs (T8). Optional Pushgateway marker-age gauge from the design is **intentionally deferred** (logged here as a follow-up, not built — keeps scope to the shipping mechanism).
- **Placeholders:** none — every file has complete content; every command has expected output.
- **Type/name consistency:** `safe_restart_unit`, `backup_user`, `prebump_of`, `gate_query`, `gate_is_safe`, `safe_to_restart`, `DEFER_DIR`, `QUIET_SECONDS`, `T3_SAFE_RESTART_LIB`, `LOG_TAG` used identically across tasks. `target`/`last_good` are documented caller-set globals consumed by lib functions.
