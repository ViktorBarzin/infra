# t3-cgroup-snap — process-level black box for the t3-serve cgroup (design)

**Date:** 2026-07-09 · **Author:** wizard (approved by Viktor) · **Status:** approved · **Lifetime:** diagnostic — removed after we identify the ballooning tool

## Problem

`t3-serve@wizard`'s 16 GiB cgroup has been cgroup-OOM-killed on **2026-07-08 07:24 & 07:26** and **2026-07-09 22:26 & 22:27**. Every incident kills a subprocess whose `Comm` string is `2.1.205` (identical across the four events; anon RSS 5–7 GiB). The comm is not a known tool's binary name — no installed tool (`mypy`, `pyright`, `ruff`, `poetry`, `uv`, `pytest`, `tsc`, `node`, `docker-buildx` …) reports version `2.1.205`, so it is a subprocess renamed via `prctl(PR_SET_NAME)` and we cannot identify it after the fact from `journalctl -k` alone (which only records the comm + PID + RSS, not the argv).

Today's `t3-watchdog` closes the recovery gap (unit stays `active` with a dead listener → auto-safe-restart), and the underlying containment layers (`OOMPolicy=continue`, `MemoryMax=16G`, `MemorySwapMax=0`, earlyoom) all work as designed. What's still open: **which tool** is ballooning to 5–7 GiB in an already-busy cgroup, so we can decide whether to constrain it directly or add a structural mitigation.

## Goal

Non-invasively capture, at ~5 s cadence, a per-PID snapshot of every process in every `t3-serve@<user>` cgroup (`pid, ppid, uid, rss, comm, exe, argv[:512]`), retained ~24 h locally, so that after the next OOM we can look up the killed PID's real identity in the snapshot ~5 s before its death.

## Non-goals (explicit, YAGNI)

- **The mitigation itself** (per-child sub-cgroup limits / kill-heaviest / raise cap / configure the tool). Comes back as a separate task once the target is known.
- **Cluster-wide log shipping**. A local JSONL on the devvm is enough for this investigation; adding a Loki stream costs cardinality budget for zero gain.
- **Anything on non-devvm hosts**. Only the devvm has the pattern.
- **Permanent infrastructure**. As soon as we identify the tool, the service + files come out in the same PR that lands the mitigation.

## Design

### Shape

A single long-lived `Type=simple` systemd service (**`t3-cgroup-snap.service`**), matching the existing `nfs-change-tracker.service` shape from the storage stack. Continuous internal `sleep 5`; no `.timer` — a timer firing every 5 s costs more (fresh cgroup + fork per tick) than a bash loop and gains nothing.

The service runs `/usr/local/bin/t3-cgroup-snap`, a bash script that:

1. Enumerates every `system-t3\x2dserve.slice/t3-serve@*.service` cgroup on the box (all present users).
2. Reads each cgroup's `cgroup.procs`.
3. For each PID: reads `/proc/<PID>/{status,comm,cmdline}` and `readlink /proc/<PID>/exe`.
4. Emits **one JSONL line per (snapshot, pid)** to `/var/log/t3-cgroup-snap.jsonl` with:
   ```
   {"ts":"2026-07-09T22:26:40Z","user":"wizard","pid":2544629,"ppid":2547744,"uid":1000,"rss_kb":5394176,"comm":"2.1.205","exe":"/usr/lib/…","argv":"…truncated to 512 bytes, NULs replaced with spaces…"}
   ```
5. Sleeps 5 s (fixed; no jitter — a metronome makes correlation easier).

Every ~60 s (12 sleeps), the script checks the log's size; if ≥ 50 MiB, it rotates in-script: `t3-cgroup-snap.jsonl.2 → .3` (drop), `.1 → .2`, current → `.1`, open new. Zero external dep (no `logrotate` config). 3 rotations × 50 MiB = **150 MiB max**, well within budget on the devvm root fs.

### Argv handling

`/proc/<PID>/cmdline` is NUL-separated. Read up to **512 bytes**, replace NULs with spaces, JSON-escape (bash `printf %s` piped through `jq -Rc .` for correctness — jq is on the box). Truncation is deliberate — 512 bytes captures the tool name + a few args; extremely long argvs (pytest with hundreds of tests, an agent's `--mcp-config <giant blob>`) don't blow the log.

### Permissions

`User=root` — needed for cross-user `/proc/*/cmdline` reads (kernel restricts to owner + root). Log at mode 0640, owned root:adm. This is a shared devvm; other OS users cannot read the log.

### Missing-file tolerance

Processes die between the `cgroup.procs` read and the `/proc/<pid>` read. A failed open on any of the three per-PID files is silently skipped (short-lived proc gone). The main loop must never abort on one bad PID.

### Startup and teardown

- `systemctl enable --now t3-cgroup-snap.service` — begins snapshotting immediately.
- `Restart=on-failure` (short backoff) so a temporary bash bug doesn't blind us for the next OOM.
- Once the target is identified, the diagnostic is removed in one commit: delete `scripts/t3-cgroup-snap.{sh,service}`, unwire from `setup-devvm.sh`, `sudo systemctl disable --now t3-cgroup-snap.service`, `sudo rm /var/log/t3-cgroup-snap.jsonl*`.

## Analysis path (post-OOM)

1. Time of OOM + killed PID from `journalctl -k --since -24h | grep -B1 "Killed process"`.
2. `jq 'select(.pid==<PID>)' /var/log/t3-cgroup-snap.jsonl | tail -1` — last snapshot before the kill; the argv reveals the tool.
3. If the process was too short-lived to appear: `jq 'select(.ppid==<PPID>)' …` — the launcher is usually one of `bash`, `python`, `node`, or `claude`; the launcher's argv usually names the invoked binary.

## Testing

- **Unit test** (`tests/t3-cgroup-snap.test.sh`, same pure-bash harness pattern as `t3-watchdog-gate.test.sh` / `t3-migrate-idle-gate.test.sh`): source the script (main-guarded), then exercise the pure functions:
  - `emit_line <pid> <fixture_proc_root>` against a fixed `/proc`-shaped test dir → expected JSONL (validates NUL-replacement, RSS extraction, missing-file tolerance, jq escaping of `"` / `\` / newlines in argv).
  - `rotate_if_needed <path>` against a pre-created 51 MiB file → three renamed files exist.
- **Live smoke** (post-install, section of Task 4 in the plan): `sudo systemctl start t3-cgroup-snap.service`, `sleep 60`, expect ≥ 10 snapshots for every currently-running `t3-serve@*` PID; JSONL parses cleanly (`jq . </var/log/t3-cgroup-snap.jsonl >/dev/null`).

## Deployment

- Files in the infra repo (canonical, git-tracked):
  - `scripts/t3-cgroup-snap.sh` — the script (main-guarded so tests can source).
  - `scripts/t3-cgroup-snap.service` — the systemd unit.
  - `tests/t3-cgroup-snap.test.sh` — unit tests.
- Wired into `scripts/workstation/setup-devvm.sh` §9a (install to `/usr/local/bin/t3-cgroup-snap`) + §9d (unit list + `systemctl enable --now`), matching every other t3 timer/service in that section.
- One-shot targeted install on the devvm the same day (same recipe as today's watchdog deploy) — no need to wait for a devvm rebuild.

## Docs updates

Same-commit docs (light — this is a diagnostic):
- `docs/runbooks/t3-cgroup-snap.md` — short: what it is, how to grep the log after an OOM, how to remove when done.
- A one-line pointer in the 2026-06-22 devvm mem/IO post-mortem (Addendum 3: "Ongoing — snapshotter deployed to identify the recurring 5–7 GiB ballooning subprocess; see runbook").

## Rejected alternatives

- **auditctl on `execve`**: catches short-lived spawns the sampler misses, but the audit stream on a shared devvm is noisy and the /var/log/audit stream competes for the same disk we already trimmed for the code-oflt effort. Kept in reserve if the sampler misses.
- **bpftrace probe on `sched_process_exec` + RSS threshold**: cleanest identification, but `bpftrace` isn't installed on the devvm and requires a kernel with BTF the current 6.8.0-124-generic has, plus root — worth it only if the bash sampler proves insufficient.
- **Correlate against `~/.claude/**/*.jsonl` transcripts alone**: I tried this already; it names the agent's Bash command (e.g. `poetry run pytest -q`) but not the specific ballooning subprocess (Poetry / pytest / mypy / …) — needed the process view too.
- **Just raise the cap**: not a diagnostic; would silence the signal we're trying to read. Also unsafe: 3 users × new cap > devvm 23.5 GiB physical.
