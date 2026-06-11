# 2026-06-11 — devvm dead ~90 min: QEMU-internal I/O stall on the legacy LSI disk path

## Impact

- devvm (VM 102, the shared multi-user Claude Code workstation) effectively
  dead 15:21–16:48 UTC (18:21–19:48 EEST): all ssh/tmux and t3 sessions for
  wizard/emo/anca lost, every in-flight agent killed.
- Detection was human (~90 min) — no `up{instance="devvm"} == 0` alert
  exists (follow-up below).
- Recovery was manual: kill of the wedged QEMU process + `qm start` (the
  kill left no autopsy — see "What we could not prove").

## Timeline (UTC; host journal runs EEST = UTC+3)

- **15:01** — hourly `apply-mbps-caps` run live-rewrites VM 102's scsi0
  throttle via `qm set` (as it had done every hour for weeks — see Root
  cause #4).
- **15:18–15:20** — guest healthy by every metric: CPU 7–16% of 16 vCPUs,
  load 1.4, 17 GiB MemAvailable, swap flat at 2.0 GiB, host `sdc` 2–8%
  utilized. Heavy claude/bwrap sandbox activity (normal workload).
- **15:19:08** — last journal line the guest ever writes (mid normal
  traffic, zero kernel distress — not even a hung-task warning).
- **15:21** — host RRD (pvestatd polling QEMU over QMP once a minute) shows
  `diskwrite` drop to **exactly 0 and stay 0 for 87 minutes** — not even
  journal flushes. netout collapses 380K→7K/s. **QEMU keeps answering QMP
  the whole time** — the process and its main loop are alive; only the
  block path is dead.
- **15:21→15:39** — guest CPU (host's view) ramps 11% → ~50% and plateaus:
  processes progressively piling up behind dead storage (dirty-page
  writeback stuck → direct reclaim spins). Classic starvation cascade, not
  a panic (a panic halts or spins flat from t=0).
- **16:47:42** — QMP socket resets: the wedged QEMU is killed out-of-band
  (root shell; no PVE task, no snoopy line — shell-builtin `kill`).
- **16:48:31** — `qmstart` task; guest boots clean on kernel 6.8.0-124
  (wedged boot ran 6.8.0-117).

## Ruled out (evidence, not vibes)

- **Guest CPU/memory/swap pressure** — healthy at last scrape (Prometheus)
  and per-minute host RRD.
- **Host storage** — `pve` thin pool 68% data / 15.5% meta; zero kernel
  I/O errors on the host all day; `sdc` quiet through the window.
- **Host-side kill/OOM** — no OOM-killer lines, no segfault, no QEMU crash
  log; 113 of 114 monitored targets stayed up. Only the devvm died.
- **Guest kernel panic** — would not keep QMP-visible blockstats frozen at
  0 while netout ACKs trickle; and the guest kernel logged nothing.

## Root cause

**Class pinned, exact line unprovable** (see below): the devvm's disk I/O
stalled *inside the QEMU process* — below the guest kernel (all guest I/O
froze simultaneously with nothing logged) and above host storage (host
clean, neighbors fine, QEMU main loop responsive). Contributing stack,
unique to this VM:

1. **`scsihw: lsi`** — the emulated LSI 53C895A (1997 chip, QEMU's legacy
   default for OSes without virtio drivers). The devvm was the **only VM
   on the host** running its disk through this path; every healthy
   neighbor uses `virtio-scsi-pci`. The LSI model is documented as
   hang-prone under intensive I/O.
2. **No `iothread`** — all disk emulation ran on QEMU's single main event
   loop, sharing it with timers and QMP.
3. **QEMU-level mbps throttle (60/60)** — a token bucket inside QEMU whose
   queued I/O completes only when its re-arm timer fires.
4. **Hourly live throttle rewrites** — `apply-mbps-caps.sh`'s idempotency
   check compared raw config strings, but `qm config` prints keys in its
   own canonical order, so the check **never matched** and the script
   re-issued `qm set` (→ live QMP `block_set_io_throttle` against the
   running QEMU) every hour, 24×/day, for weeks — each poke a chance to
   race the throttle machinery while queued I/O is in flight. The wedge
   came 20 min after the 15:01 poke.

## What we could not prove

Whether the stuck queue was the LSI device model, the throttle-group
timer, or their interaction. The discriminating evidence (QMP
`query-block`, a stack trace of the QEMU process) existed in RAM at 16:47
and was destroyed by the recovery kill. If a wedge recurs **autopsy before
shooting**: `qm guest exec` will fail but `qm monitor`/QMP `query-block`,
`query-status`, and `gdb -p <pid> -batch -ex 'thread apply all bt'` on the
kvm process pin it to the line.

## Fixes

| Status | Fix |
|---|---|
| shipped (this commit) | `apply-mbps-caps.sh` compares **normalized option sets** — hourly runs are now true no-ops; running VMs' throttle state is no longer rewritten 24×/day. Verified: reordered-key configs compare equal, real drift still triggers `qm set`, post-restart iothread configs compare equal. |
| staged, awaiting Viktor's cold stop→start | VM 102: `scsihw: virtio-scsi-single` + `scsi0 …,iothread=1,aio=threads` — replaces the LSI path with the paravirt controller all healthy VMs use, moves disk emulation off the main loop, swaps io_uring for boring thread-pool AIO. Guest pre-flight passed (`CONFIG_SCSI_VIRTIO=y` built-in; fstab on LVM dm-uuid/UUID). Must be a **full stop→start** — a guest reboot reuses the old QEMU process. |

## Open follow-ups (discussed 2026-06-11, not yet built)

- `DevvmDown` alert (`up{job="devvm"} == 0 for 3m` → Slack) — closes the
  90-min detection gap.
- Freeze forensics: netconsole → pve listener, serial console,
  `kernel.panic=60`, and a capture-before-kill runbook (above) so any
  recurrence is pinned, not mourned.
- The recurring *crawl* class (agent storms → swap-thrash; journald
  watchdog-killed 3× on 2026-06-10) is a separate failure mode —
  ssh/tmux sessions remain memory-uncontained by explicit decision
  (swap-only, 2026-06-10).

## Lessons

- **A VM can die of QEMU-userspace causes that no guest or host kernel log
  will ever show.** The host's per-VM RRD (pvestatd's QMP polls) is the
  only witness — `diskwrite=0` with a live QMP socket is the signature.
- **"Idempotent" reconcilers must prove idempotency against the system's
  canonical output format**, not against the string they themselves
  constructed. A compare that never matches turns a safety net into a
  24×/day fault injector — and its own journal said `updating scsi0`
  every hour, in plain sight, for weeks.
- The May-26 mbps caps fixed the sdc-saturation freeze class and
  introduced this one's trigger surface. Layered mitigations fail in
  layers — audit what a fix *adds*, not only what it removes.
- pve host logs are **EEST (UTC+3)**; guest logs are UTC. Every
  cross-machine correlation in this incident initially looked 3h off.
