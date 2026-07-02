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

## Fix (`setup-devvm.sh` §10, applied live 2026-06-22)

Design decisions (interviewed with the admin via `/grill-me`): **soft-generous
per-user caps + a hard ceiling + a kill-the-worst backstop**, maximising
single-user utilisation while making a box-wide wedge impossible. (The backstop
was first built on systemd-oomd, then switched to earlyoom mid-rollout when oomd
proved inert with `swap=0` — see Verification + Lessons.)

| Layer | What |
|---|---|
| **Per-user caps, BOTH trees** | `user-.slice.d` drop-in gives every `user-<uid>.slice` the same `MemoryHigh=12G / MemoryMax=16G / MemorySwapMax=0` the t3 tree already had. A user is now bounded in whichever surface they work in. |
| **No disk swap for work** | `MemorySwapMax=0` on every work cgroup → a spike OOMs **locally** at the ceiling instead of thrashing the throttled disk. Kills the IO-storm-via-swap mechanism at the source. The 14G swapfile stays for system cold pages only. |
| **earlyoom backstop (free-RAM threshold)** | New package — used **instead of systemd-oomd** (which is inert with `swap=0`; see Lessons). Watches `MemAvailable%` and SIGTERMs the biggest task at **5%**, SIGKILL at **3%**, swap ignored (`-s 100`). `--avoid` keeps sshd/systemd/dockerd/containerd/t3-dispatch/tmux off the victim list (**the admin's way in always survives**); `--prefer` targets the agent/browser hogs (python3/node/chrome/…). Swap-independent and reliable, where oomd's pressure-kill was not. |
| **Fair-share CPU/IO** | `CPUWeight`/`IOWeight` per slice (system.slice 200, users + docker 100 each). Work-conserving — a lone user still gets all 32 cores + the full IO budget when others idle; weights only bite under contention. No hard CPU/IO caps. |
| **Docker containment** | Containers previously landed in `system.slice` — uncapped. Now `cgroup-parent: docker.slice` in `daemon.json` routes every container into a capped (`MemoryMax=8G`, swap 0) slice, so a runaway container is cgroup-OOM'd locally instead of escaping into the uncapped `system.slice`. |

Durable in `setup-devvm.sh` (survives a VM rebuild); `earlyoom` added to
`packages.txt`. The numbers are tunable — `MemoryHigh=12G` will throttle a *lone*
heavy user between 12–16G even with RAM free; bump to 16/20 if that bites.

## Verification (live, 2026-06-22)

- **Caps live on running cgroups**: all three `user-<uid>.slice` report
  `memory.high=12G memory.max=16G memory.swap.max=0`; `docker.slice` `memory.max=8G`;
  daemon.json kept buildkit/nvidia/insecure-registries; paperless-mcp recovered
  under `docker.slice`.
- **Stress test A (hard cap)** — the PRIMARY guard: a 2G-capped, swap=0 balloon was
  killed at exactly 2G by the cgroup-local OOM (`constraint=CONSTRAINT_MEMCG`) with
  **swap flat at 0MB throughout** — no thrash. Same mechanism protects every user
  slice (16G) and `docker.slice` (8G).
- **Soft cap observed**: a balloon pushed past `MemoryHigh` sat at ~220M / 99%
  memory.pressure, throttled to a crawl, making no progress and harming nothing —
  a runaway is throttled, not just killed.
- **systemd-oomd disproven, then dropped**: a self-policed balloon held
  `memory.pressure full avg10 = 96–99%` (≫ its 20% limit) for >70s but oomd never
  killed it — `Pgscan: 0`. oomd's pressure-kill only acts on cgroups doing active
  reclaim, which a `swap=0` anon workload never does. oomd was purged.
- **earlyoom backstop** — verified via `--dryrun`: at the threshold it logs
  `low memory! … mem 90% swap 100%` (fires on RAM alone, swap ignored) and selects
  `SIGTERM … "chrome"` (a `--prefer` hog), never an `--avoid`'d daemon. Live
  earlyoom v1.7 confirms `SIGTERM mem<=5% / SIGKILL mem<=3%, swap<=100%`.

## Out of scope / follow-ups

- **Alerting** (tracked, fast-follow bead): `DevvmDown` (closes the 90-min
  detection gap the 2026-06-11 PM flagged), sustained-memory-PSI/swap pressure
  early-warning, and an "earlyoom-killed-something" alert (earlyoom logs each kill;
  `-N /script` can push a metric). devvm node-exporter is already scraped
  (`job=devvm`, `10.0.10.10:9100`), so only alert *rules* are new (a
  monitoring-stack Terraform change).
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
- **A backstop must protect the operator's way in.** earlyoom `--avoid`s
  sshd/systemd/dockerd/containerd/t3-dispatch/tmux, so the box always stays
  reachable to recover; only the agent/browser hogs are eligible victims.
- **systemd-oomd is the wrong backstop for a no-swap box — verify, don't assume.**
  oomd's memory-pressure killer only fires on cgroups doing active reclaim
  (`pgscan` rising). With `MemorySwapMax=0` + anonymous memory there is nothing to
  reclaim, so a cgroup sat at 99% `memory.pressure` indefinitely and oomd never
  acted (proven with `oomctl` + a balloon). The very `swap=0` that kills the IO
  storm also neuters oomd. earlyoom (free-RAM threshold, swap-independent) is the
  correct pairing. A famous tool that "does OOM" still has to be proven to fire
  under *your* configuration.

## Addendum (2026-07-02): the MemoryHigh throttle band livelocks — removed

The soft-cap layer of this design was falsified in production on 2026-07-02
(~15:42–16:35 UTC): an agent-spawned `ugrep` (12.35G RSS; `-o` with wide
alternation captures over a multi-GB `.jsonl` transcript) **plateaued inside
t3-serve@wizard's `MemoryHigh=12G..MemoryMax=16G` band**. With
`MemorySwapMax=0` its anonymous pages were unreclaimable, so the kernel parked
every allocating task of the cgroup in `mem_cgroup_handle_over_high`
(`memory.pressure full avg60 ≈ 80%`, `memory.events high=882948`, `oom_kill=0`)
— including the `t3 serve` event loop (~0.5G RSS, pure collateral). The accept
queue backed up (21 pending connections), t3-probe logged `t3serve: [Errno 104]
Connection reset by peer`, t3-dispatch logged `proxy error: context canceled`,
and t3.viktorbarzin.me was dead for its user until the hog was SIGKILLed by
hand (the D-state high-throttle sleep IS killable; the cgroup dropped 14G→1.4G
and the service recovered in seconds with no restart).

The Verification bullet above — a soft-capped balloon "throttled to a crawl,
making no progress and **harming nothing**" — holds only when the hog is alone
in its cgroup. Sharing the cgroup with a latency-sensitive server, the crawl
IS the harm: a hog that stabilises below `MemoryMax` never triggers the local
OOM the design counted on, so the band converts "runaway dies" into "everyone
in the cgroup stalls forever".

**Fix (same day, admin-approved): `MemoryHigh=infinity` on all three work
cgroup definitions** — `scripts/t3-serve@.service`, the `user-.slice.d`
drop-in, and `docker.slice` (`setup-devvm.sh` §10a/§10c). A runaway now runs
unthrottled into `MemoryMax` and is cgroup-OOM-killed immediately
(`OOMPolicy=continue` keeps t3-serve itself alive; in slices the kernel kills
the biggest task). `MemoryMax`, `MemorySwapMax=0`, and earlyoom — the layers
the stress tests actually validated — are unchanged. Applied live via
`daemon-reload` + runtime `set-property` on the running cgroups; no session
restarts.

Lesson: **with `swap=0`, `memory.high` is not a gentler `memory.max` — it is
an unbounded stall injector for everything sharing the cgroup.** Cap-and-kill
beats throttle-and-pray for multi-tenant interactive services.
