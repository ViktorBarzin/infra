# What is left of the read-IOPS problem

Status: executing. Measured 2026-09-15 by four parallel investigations, after the
first fix of the day removed 34.7% of the host's read operations.

This is a follow-on to
[the IO bottleneck plan](2026-09-12-io-bottleneck-ssd-vs-spindles.md), which
asked whether to use the idle SSD or fit spare spindles. Neither question is
answered here, because the work keeps finding application bugs instead of
hardware limits.

## Summary

The host is short of random read IOPS on `sdc`, a mirror of two 7200rpm drives.
Four workloads were investigated in parallel. Two turned out to need no work at
all, one has a real fix that is cheap, and one is deep.

The headline correction is about **when** the disk is actually in trouble.
Ranking workloads by their share of read operations over a week points at the
wrong things, because most of those operations land in hours when the disk keeps
up comfortably. Ranked instead by queue depth, only one hour of the day is
consistently bad.

| UTC hour | queue depth p50 | p95 |
|---|---|---|
| **00:00** | **6.6** | 36.7 |
| 01:00 | 0.6 | 15.9 |
| 02:00 | 0.8 | 15.2 |
| 03:00 | 1.5 | 10.9 |
| 12:00 | 0.3 | 18.2 |
| 21:00 | 0.6 | 11.3 |
| 22:00 | 0.8 | 101.8 |
| 23:00 | 0.7 | 91.1 |

Midnight UTC is the only hour whose **median** is elevated, roughly eight times
every other hour. The 22:00 and 23:00 p95 figures come from a single night,
2026-09-13, which was almost certainly this work's own session activity; their
medians are 0.8 and 0.7. A p95 over seven days can be one bad night, and reading
it as a pattern is the recurring error of this whole investigation.

Ten leader-election clients across four nodes lost their leases at
**00:01:52** on 2026-09-15, which sits inside that hour.

## What runs at midnight

| time (UTC) | job | what it reads |
|---|---|---|
| 00:00 | `dbaas/postgresql-backup` | `pg_dumpall`, 37 databases, 6.56 GiB |
| 00:02 | `lvm-pvc-snapshot` (host timer) | 78 snapshots, 3m10s |
| 00:15 | `dbaas/postgresql-backup-per-db` | `pg_dump -Fc` per database, **the same 6.56 GiB** |
| 00:30 | `dbaas/mysql-backup` | all databases |
| 00:45 | `dbaas/mysql-backup-per-db` | the same databases again |

The whole hour is the plan's first target, and it is the only one where the
disk is measurably in trouble.

Read volume through the thin pool is flat at 7.9 to 10.3 MB/s across all four
quarter-hour slots, so the disk is kept busy for a continuous hour with reads
scattered across roughly 350 volumes. `pg_dumpall` alone runs 13 minutes.

Postgres also caps a sequential scan of any table larger than
`shared_buffers / 4`, here 512 MB, to a 256 KB ring buffer, so these scans
deliberately never populate the buffer pool and always reach the platter. That
is by design, not a fault, and it is also the full explanation for the 0.02%
cache hit rate on `health.health_records`: 90 scans at 89,197 blocks each
against a 711 MB heap of 91,008 blocks.

## The order of work

| # | change | effect | blocked on |
|---|---|---|---|
| 1 | `pg_dumpall --globals-only`, keep per-db | 6.56 GiB/night, 18.4% of that device's reads | nothing |
| 2 | move `lvm-pvc-snapshot` off 00:02 | removes an overlap in the worst hour | nothing |
| 3 | `Delegate=pids memory cpu io` on `user@.service` | 0 IO, but unblocks per-session attribution | nothing |
| 4 | devvm memory, from node1's 33 GB of slack | up to 56% of devvm's reads are refaults | a reboot each side |
| 5 | reap 66 Claude sessions idle over 24h | up to 13.7 GB on devvm | other people's sessions, needs a policy call |
| 6 | dawarich: PVC, archival, geocoding tail, repack | 4.8% of host reads | four steps, see below |

Items 1 to 3 are free and uncontested. Item 4 is the largest single effect
available. Items 5 and 6 need decisions that are not the author's to make.

## Decisions

### 1. Stop dumping every database twice (recommended, cheap)

`postgresql-backup` and `postgresql-backup-per-db` read the same 6.56 GiB every
night. The per-db job excludes only `postgres`, which has no user tables. That
redundant half is **18.4% of every byte `pg-cluster-4`'s device reads**, 46 GiB
a week, against the container's own measured 35.7 GiB/day.

Nothing ever asked for two copies. The per-db job is 153 days old against the
other's 661; it was added for selective restore and the older one was never
retired. `docs/architecture/backup-dr.md:339` records only the selective-restore
rationale.

Change the 00:00 job to `pg_dumpall --globals-only`. Globals live in shared
catalogs, so it reads no table data at all, and roles, passwords and grants stay
covered while per-database `pg_restore` keeps working.

What this gives up is a genuinely independent second copy, and
`docs/runbooks/restore-postgresql.md:148` exists because per-db dumps once went
useless. The substitute is already written down at `:36`: a per-db dump whose
byte size is identical across consecutive days is schema-only, which is a size
check rather than a nightly 6.56 GiB re-read.

Pointing the dumps at `pg-cluster-ro` was considered and rejected.
`hot_standby_feedback` is off with `max_standby_streaming_delay=30s`, and a
multi-GB dump takes far longer than 30 seconds, so recovery conflict would
cancel it.

### 2. Move the snapshot pass off 00:02 (recommended, trivial)

`lvm-pvc-snapshot` takes 3m10s and currently starts two minutes into the
heaviest hour of the day. Nothing requires that time. Moving it costs nothing
and removes an overlap.

### 3. Immich integrity checks stay on (no action)

`immich-worker`'s nightly `IntegrityService` is 96% of `/srv/nfs` reads and
roughly 27% of the host's weekly read operations: 238.7 GiB and 4,295,502
operations in a single hour, 03:00 to 04:00.

It stays, for two reasons.

It works. An earlier reading of the logs suggested it restarted from the
beginning every night and never completed, which was wrong. The percentage in
the log is a per-run counter, so every run begins at 0.05% by construction. The
real cursor is a separate line that advances nightly, and the job wrapped to the
beginning on 2026-09-11 after completing a pass. A full pass over 182,240 assets
and 1,377 GiB takes about six nights.

It covers a gap nothing else covers. ext4 has no data checksums. A two-disk
mirror without checksums cannot tell which copy is right when they silently
differ, so the controller's patrol read sees a consistent mirror of wrong bytes.
`nfs-mirror` and the offsite rsync faithfully propagate corruption into both
backup copies. The only thing catching corruption introduced above the block
layer is this job.

It also runs at 03:00, where median queue depth is 1.5. Its share of read
operations is large; its contribution to the hour that actually hurts is not.

Worth knowing: on a mismatch it writes an `IntegrityReport.ChecksumFail` row and
a log line, with no alert, no quarantine and no repair. The report table already
holds 5,329 `missing_file` and 2,069 `untracked_file` rows, unactioned. The
channel exists and nobody is watching it. `checksum_fail` is currently zero,
though rows are deleted once a file passes again, so that is current state
rather than history.

### 4. The thin pool and the 234 snapshots (no action)

Pruning is exact: 78 origins by 3 dates, zero orphans, 78 created and 78 pruned
daily for over a month. Retention was corrected on 2026-06-29 and the memory
describing it as twice-daily with 7-day retention and a 14-per-LV cap is stale;
it is once daily at 03:00 with 3-day retention.

The metadata device `dm-4` is a symptom rather than a cause. It correlates with
`dm-8` data reads at r=+0.624 and with the snapshot service not at all, which
contributes under 1% of its weekly total. At 21 IOPS against `sdc`'s 476 it is
4.4% of the spindle, and its 26.46 ms per read is queueing behind other traffic.

Moving the pool metadata to the SSD was evaluated and rejected. `pvmove` cannot
cross volume groups, VG `pve`'s 16.25 GB of free extents are all on the same
spindle, and the path means evacuating 200 GB of `nfs-ssd-data`, destroying VG
`ssd` and taking a storage outage to hand a 931 GB disk to a 16 GB LV.

Raising `dm_bufio.max_age_seconds` was proposed and then withdrawn by its own
author. No hit-rate counters exist, normalising against `sdc` or `dm-8` raises
the coefficient of variation rather than lowering it (0.84 raw, 0.88, 1.09), and
a perfect cache removes at most 2.8% of `sdc`'s read operations. At that
variance, detecting a 20% change needs roughly 13 days per arm.

### 5. Raising memory on `pg-cluster-4` (rejected)

The container sits at 99.88% of its 4 GiB limit with 67,848 lifetime
`memory.events max`, which looked like permanent reclaim. It is not.
`memory.pressure` carries a cumulative total: **284 seconds of memory stall over
12.9 days, 22 seconds a day, 0.025% of wall time**, across a window containing
twelve nightly dump pairs. That is the ceiling on any memory change, against
8.5M reads waiting 44.72 ms each.

A second bound agrees. `workingset_restore_file / workingset_refault_file` is
2.90%, so only that fraction of refaults are near enough to benefit from a
larger page cache.

Working set is p50 77.6%, p99 88.1%, 14-day high-water 3.80 GiB, `oom_kill` 0.

### 6. `dawarich.points` (real, but four steps deep)

`dawarich` is 56.15% of a fully subscribed 2 GiB buffer pool, and `points` is
210.6M of the instance's 278M disk block reads. The cause is application-side,
the same shape as the `wrongmove` bug fixed earlier today.

- **74% of the table is two JSONB columns the hot path never reads.** `geodata`
  1,195 MB and `raw_data` 759 MB, together 1,954 MB of a 2,656 MB heap.
  `country_name` and `city` are already denormalized into their own columns.
- **The heap is shuffled.** Correlation 0.225 on id and 0.227 on timestamp, for
  an append-only GPS log that should be near 1.0. Only 0.76% of updates were
  HOT, 11,042 of 1,449,659, so 99.24% moved the row to a new page. A
  115,213-row range scan therefore touches about 115k distinct blocks instead of
  18,700.

Fixing both takes heap plus TOAST from 2,656 MB to roughly 700 MB, putting the
whole dawarich working set near 1.8 GB and inside the existing 2 GiB pool with
no extra memory.

The ordering is forced, and it is long:

1. **A PVC or S3 for ActiveStorage.** The archival is fully built and guarded
   behind `ARCHIVE_RAW_DATA=true`, its cron is live and its queue is processed,
   and `Clearer` only touches rows with `verified_at` set and never deletes a
   point. But `STORAGE_BACKEND` is unset, so ActiveStorage writes to
   `/var/app/storage` on the pod's ephemeral overlay. Setting the flag today
   archives into a directory that evaporates on restart. It fails closed rather
   than losing data.
2. **Then the archival**, for -759 MB.
3. **Then settle the reverse-geocoding tail.** 490,346 rows, 31%, still have
   `reverse_geocoded_at IS NULL`, and `index_points_on_not_reverse_geocoded`
   shows 22,128 scans, so something is still working through them. Completing
   them means 490k more non-HOT updates and about +390 MB of geodata.
4. **Then `pg_repack`**, which is pointless before step 3 because the remaining
   geocoding would re-shuffle the heap behind it. The extension is not
   installed.

Separately and cheaply: four never-scanned indexes on `points` are 152 MB, and
85 unused indexes across the whole dawarich database are 168 MB.

## What was already fixed today

The `wrongmove` daily aggregator, which was 34.7% of the host's read operations.
`OFFSET` pagination made a 123,272-row walk cost 7.7M row reads, and `SELECT *`
dragged a 15,050 byte JSON column the loop never read. Both fixed in `94aaa43`,
with a missing `visibility_timeout` that had been running the whole job twice.
Verified live: 64,055 rows examined per execution became 996, the task went from
4,148 seconds to 7.3, and physical reads for a run went from roughly 5.2M to
985. Trend-column checksums were byte-identical before and after.

### 7. devvm is short of memory, not of disk (the largest remaining item)

devvm is 24.2% of the host's read operations and the worst-served device on the
box at 54.69 ms per read. The reads are real, and almost none of them need to
happen.

**56% of everything devvm has read since boot is a re-read.**
`workingset_refault_file` is 350,765,009 pages, 1,437 GB of the 2,557 GB read
since boot, and 80% of those refaults were for pages the kernel still judged
part of the working set. Evictions outran cache fills 2.7 to 1 in a clean
trace. `pgscan_direct` is 239.7M, so this is direct reclaim rather than kswapd
keeping ahead, and IO pressure `full avg300` sits at 25.1%.

The arithmetic behind it: page cache is 6.40 GB on a 31 GB box serving a 203 GB
filesystem, because anonymous memory is 18.27 GB resident with a further 8 GB
in swap. That is 26.3 GB of anonymous demand on 30.6 GB usable.

**71 Claude processes hold 13.7 GB of RSS and 66 of them are older than 24
hours.** That is 44% of the box's memory held by detached sessions.

By page-cache fills over a clean 150 second window, `claude` is 69% and `grep`
27%, together 96%. The hottest single file is the 216.6 MB Claude Code binary.
The work itself is genuine: Claude Code searching roughly 200 GB of repositories
and re-reading a transcript on resume are both real. What makes them expensive
is a cache too small to hold a 217 MB file even once.

Two options, and they are not exclusive:

| change | frees | cost |
|---|---|---|
| reap the 66 Claude processes idle over 24h | up to 13.7 GB | touches other people's detached sessions |
| take memory from k8s-node1's slack | 8 to 16 GB | one reboot each side |

**node1 is where the memory is.** It has 49,152 MB allocated and uses 15,972,
so 33,180 MB of slack, while every other node runs 32,768. Its requests are
21,852 Mi against 49,226,796 Ki allocatable, 45%, so shrinking it to 40,960 MB
leaves requests at 56% of the new allocatable and hands devvm 8 GB. Going
further to 32,768 would put requests at 70% and raise limit overcommit from
116% to 183%, which is a real increase in burst risk for a memory the host
cannot spare elsewhere: allocations already total 269,436 MB against 267 GB
physical.

Two things ruled out by measurement rather than assumed. Pruning old Claude Code
versions recovers 0.62 GB of disk and roughly nothing in IO, checked against
`/proc/*/maps`. Archiving old transcripts is pointless: only 0.15 GB of
wizard's are older than 30 days.

Also worth landing regardless, because it costs nothing: `user@1000.service` and
`user@1002.service` delegate `cpu memory pids` but not `io`, so every tmux pane
and Claude session collapses into one cgroup with no `io.stat` beneath it. That
is why 752.4 GB of read IO could not be attributed further, and why the
per-cgroup exporter added earlier today cannot see individual sessions. The
declarative fix is a drop-in:

```ini
# /etc/systemd/system/user@.service.d/10-io-delegation.conf
[Service]
Delegate=pids memory cpu io
```

**A measurement rule worth keeping, which cost this investigation an hour.**
`/proc/<pid>/io` `read_bytes` names the process that was scheduled when the bio
was submitted, not the process that wanted the bytes. `task_io_account_read()`
charges `current` at `submit_bio`, so readahead, reclaim and writeback land on
whatever long-lived poll loop was running. A 143.5 MB `dd iflag=direct` moved
`user-1000.slice` by exactly 152,629,248 bytes and moved PID 1 by zero, while
PID 1's lifetime `read_bytes` is 1,693 GB against a cgroup holding 0.93 GB.
Ranked that way, PID 1, the two `systemd --user` managers and tmux are 91.5% of
the box and cause almost none of it. Rank block reads with
`tracepoint:filemap:mm_filemap_add_to_page_cache`, which fires once per page
filled and carries `i_ino` and `s_dev` so it names the file, or with cgroup
`io.stat`. Never with `/proc/<pid>/io`.

## Open questions

1. **What stops the Immich job at exactly 04:00.** A one-hour `timeLimit` of
   3600000 ms is configured by default; that it is the binding constraint is
   inferred rather than confirmed.
3. **A 2.08 TB gap in the thin pool.** Origins map 4,762 GB and snapshots
   604 GB, total 5,367 GB, against 7,497 GB reported used. No read-only
   explanation was found and none was guessed.
4. **Whether any of this moves the stalls.** Answered 2026-09-16, and the
   answer retires the measure. `pvestatd` stall count does not track disk
   health, so this plan should not be judged against it. Stalls run at 307 per
   hour, 85% of all 10-second polls, in a tight 11.1 to 14.1 s band with a
   median of 11.7 s, while `sdc` sits at queue depth 0.2. A narrow band points
   at a fixed cost rather than contention, which produces a long tail. The host
   has nine guests with `agent: 1` and each guest-agent ping takes 1.2 to 1.4 s;
   polled serially that sums to the observed median. `pvesm status` across all
   three storages takes 1.33 s and does not account for it. The measure that
   replaces it is **`sdc` queue depth during the hours people use the
   machine**, which is already collected and needs no new instrumentation.

## A note on reading historical `dm-N` series on this host

The host rebooted on **2026-07-18 09:33** and device-mapper reassigned minor
numbers. `dm-4` averaged 42 to 48 KB per read before that date, as a data
volume, and is exactly 4.0 KB per read after it, as the pool metadata device.
Any `dm-N` figure from before that reboot describes a different logical volume.
An apparent 25x improvement over 120 days turned out to be exactly this.

## Outcome, 2026-09-16

The plan opened by saying neither the SSD nor the spare spindles question was
answered. Both are now answered, and the answer is neither.

**Not IOPS-bound during the hours people use the machine.** Over the 13 hours
from 05:00 UTC on 2026-09-16, `sdc` queue depth held a median of 0.1 and a p95
of 2.2, with the whole host reading 31.9 GB across that window. Nothing waits
on the disk. The 24-hour figures look worse (queue depth p99 18.6, one 5-minute
window at 293) and every one of those samples falls inside the nightly backup
hours, which are deliberately out of scope.

**Read latency did not improve and is not expected to.** 7.5 ms at the median,
unchanged from the 7.4 ms measured on 2026-08-15 and from the 7.6 ms measured
the day before this work. That figure is the seek and rotation time of a
7200 rpm spindle. Write reduction cannot move it and did not.

**What did help was page cache, not the disk.** k8s-master was allocated 32 GB
and its guest used 7.2 GB, holding roughly 12 GB of host RAM the guest had
already freed, because a VM with `balloon: 0` never returns freed pages.
Resizing it to 16 GB took host page cache from 9.1 GiB to 25.5 GiB. Reads
reaching the platter roughly halved, from a median of 29.2/s to 12.9/s, while
per-read latency stayed flat. More cache does not make a seek faster, it stops
the seek happening. Some of that halving is workload rather than cache, since
the comparison window contains this investigation's own activity.

**The read-heavy application bug was real and is fixed.** The wrongmove market
aggregator ran 4,149 s and then again 5,833 s on 2026-09-15; on 2026-09-16 it
ran once in 18.2 s. It had been exceeding Celery's one-hour visibility timeout
and being redelivered, so the duplicate nightly execution disappeared along
with the runtime.

**Still open.** Dawarich was never touched. MySQL does 55 physical reads per
second sustained at a 99.19% buffer pool hit rate, noticed but not
investigated. The 2.08 TB thin-pool gap in the open questions above is
unchanged. Roughly 44 GB of VM over-allocation remains across the other
guests, on the same `balloon: 0` ratchet that k8s-master was on.

**A measurement trap worth recording.** `pve_disk_read_bytes_total` resets when
a VM restarts, so `increase()` over it extrapolates wildly. It reported
k8s-node2 reading 2,889 GB in 24 hours on a disk that read 379 GB in total.
Per-guest read attribution has to come from the host's `dm-N` device stats,
mapped back through `dmsetup` to the logical volume.
