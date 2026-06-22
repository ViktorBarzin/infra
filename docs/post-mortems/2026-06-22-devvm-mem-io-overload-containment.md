# 2026-06-22 — devvm memory/IO overload: per-user containment + OOM backstop

## Impact

- devvm (VM 102, the shared multi-user Claude Code workstation) became
  unresponsive under combined memory + IO pressure and had to be **hard-killed +
  rebooted** by the admin on 2026-06-22 (morning). All ssh/tmux + t3 sessions for
  wizard/emo/anca lost, in-flight agents killed.
- Signature on the last htop before the kill: **load avg ~60** on 32 vCPU, **RAM
  22.5/23.5G**, **swap 13.9/14.0G (full)**, a wall of **D-state** (uninterruptible
  IO-wait) processes, and a single `ugrep` in emo's tmux holding **~10G RES /
  64% CPU**. Many `claude --effort max/xhigh` sessions + playwright-chrome MCP
  instances across three users on top.

## This is the "crawl" class, not the QEMU-stall class

The 2026-06-11 post-mortem (`2026-06-11-devvm-qemu-io-stall.md`) fixed a
*different* failure mode — a QEMU-userspace block-path wedge on the legacy LSI
controller. That fix shipped (verified 2026-06-22: the guest now boots on
`virtio_scsi`, `scsihw: virtio-scsi-single + iothread`). Its post-mortem
explicitly deferred **this** class:

> The recurring *crawl* class (agent storms → swap-thrash; journald
> watchdog-killed 3× on 2026-06-10) is a separate failure mode — ssh/tmux
> sessions remain memory-uncontained by **explicit decision (swap-only,
> 2026-06-10)**.

That explicit decision is the root cause closed here.

## Root cause

Work on the devvm lives in **two independent cgroup-v2 trees per user**, and only
one was capped:

| Tree | cgroup | Cap before today |
|---|---|---|
| t3 web sessions | `system.slice/system-t3\x2dserve.slice/t3-serve@<user>` | `MemoryHigh=12G MemoryMax=16G MemorySwapMax=0 OOMPolicy=continue` ✓ |
| **ssh/tmux sessions** | `user.slice/user-<uid>.slice` | **`MemoryMax=infinity`, swap unlimited** ✗ |

The uncapped `user-<uid>.slice` was the hole. A runaway there (the 10G `ugrep`;
stacked max-effort agents) grew unbounded, spilled into the **14G disk swap**, and
swap-thrashed the **host-mbps-throttled (60/60 MB/s) virtual disk**. That is the
overload chain:

```
uncapped tmux growth → disk-swap thrash on a throttled spindle
   → IO storm (D-state pileup) → load ~60 → box unresponsive → hard kill
```

i.e. **memory pressure becomes the IO storm**. There was also **no global OOM
backstop** (no systemd-oomd / earlyoom) to shed the worst offender before the
kernel OOM or the thrash-wedge. And even the existing t3 caps don't sum safely
(3 users × 16G = 48G > 32G RAM) — nothing reasoned about the *whole box*.

## Fix (shipped this commit — `setup-devvm.sh` §10, applied live 2026-06-22)

Design decisions (interviewed with the admin via `/grill-me`): **soft-generous
per-user caps + a hard ceiling + an oomd backstop**, maximising single-user
utilisation while making a box-wide wedge impossible.

| Layer | What |
|---|---|
| **Per-user caps, BOTH trees** | `user-.slice.d` drop-in gives every `user-<uid>.slice` the same `MemoryHigh=12G / MemoryMax=16G / MemorySwapMax=0` the t3 tree already had. A user is now bounded in whichever surface they work in. |
| **No disk swap for work** | `MemorySwapMax=0` on every work cgroup → a spike OOMs **locally** at the ceiling instead of thrashing the throttled disk. Kills the IO-storm-via-swap mechanism at the source. The 14G swapfile stays for system cold pages only. |
| **systemd-oomd backstop (PSI)** | New package. Kills the single worst-pressured descendant of a policed slice when memory-pressure (`full`) stays **>60% for 20s**; global swap guard **80%**. Polices `user.slice`, `system-t3\x2dserve.slice`, `docker.slice`. **`system.slice` is deliberately NOT policed** — sshd + services + the admin's way in always survive; only a runaway *user* session is ever sacrificed, locally, under genuine box-wide pressure. |
| **Fair-share CPU/IO** | `CPUWeight`/`IOWeight` per slice (system.slice 200, users + docker 100 each). Work-conserving — a lone user still gets all 32 cores + the full IO budget when others idle; weights only bite under contention. No hard CPU/IO caps. |
| **Docker containment** | Containers previously landed in `system.slice` — uncapped AND protected from oomd, so a ballooning container would mis-target oomd onto an innocent user. Now `cgroup-parent: docker.slice` in `daemon.json` routes every container into a capped (`MemoryMax=8G`, swap 0), oomd-policed slice. |

Durable in `setup-devvm.sh` (survives a VM rebuild); `systemd-oomd` added to
`packages.txt`. The numbers are tunable — `MemoryHigh=12G` will throttle a *lone*
heavy user between 12–16G even with RAM free; bump to 16/20 if that bites.

## Verification (live, 2026-06-22)

- **Caps live on running cgroups**: all three `user-<uid>.slice` report
  `memory.high=12G memory.max=16G memory.swap.max=0`; `docker.slice` `memory.max=8G`;
  daemon.json kept buildkit/nvidia/insecure-registries; paperless-mcp recovered
  under `docker.slice`.
- **oomd armed**: `oomctl` shows `Dry Run: no`, swap-limit 80%, pressure-limit
  60% / 20s, and the 5 policed cgroups — `system.slice` absent (protected).
- **Stress test A (hard cap)**: a 2G-capped, swap=0 balloon was killed at exactly
  2G by the cgroup-local OOM (`constraint=CONSTRAINT_MEMCG`) with **swap flat at
  0MB throughout** — no thrash. This is the mechanism protecting every slice.
- **Stress test B (oomd backstop)**: a self-policed balloon (256M soft / 20%
  pressure limit) was killed by **systemd-oomd on memory pressure**, confirming
  the backstop fires, not just arms.

## Out of scope / follow-ups

- **Alerting** (tracked, fast-follow bead): `DevvmDown` (closes the 90-min
  detection gap the 2026-06-11 PM flagged), sustained-memory-PSI/swap pressure
  early-warning, and an "oomd-killed-something" alert. devvm node-exporter is
  already scraped (`job=devvm`, `10.0.10.10:9100`), so only alert *rules* are new
  (a monitoring-stack Terraform change).
- **zram cushion**: considered, deferred. Could let work cgroups absorb spikes in
  compressed RAM instead of OOMing at the ceiling; not needed for the wedge fix.
- **Per-user docker isolation**: containers share one `docker.slice` budget, not
  per-user. Fine for current usage (krr + short-lived tools).
- **Host-side IO**: the 60/60 mbps cap + the shared `sdc` HDD IO domain are
  host-level (bead `code-oflt`); unchanged here.

## Lessons

- **"Swap as the safety valve" is an IO-storm amplifier on a throttled disk.**
  Leaving ssh/tmux memory-uncontained (the 2026-06-10 decision) traded a clean
  local OOM for a box-wide swap-thrash wedge. `MemorySwapMax=0` + a hard cap turns
  the failure back into a contained, local kill.
- **Cap the box, not one surface.** t3 sessions were capped for months while the
  same user's tmux was unbounded — and the caps that existed didn't sum to < RAM.
  Containment has to reason about every tree and the aggregate.
- **A backstop must protect the operator's way in.** oomd polices the work trees
  only; `system.slice` (sshd, the daemons) is never a victim, so the box always
  stays reachable to recover.
