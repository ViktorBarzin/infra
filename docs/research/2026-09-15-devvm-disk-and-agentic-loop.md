# devvm: where the disk goes, and where the agentic loop's time goes

Measured 2026-09-15. Two questions asked in sequence, both of which changed
what the answer to the IO work should be.

1. The root filesystem was 190 GB of 223 GB, 90% full, on a box that "should
   have mostly code". Where is it going?
2. How much faster would the agentic loop be on flash? If the bottleneck is
   inference, a faster disk buys nothing.

Companion to [the read-IOPS plan](../plans/2026-09-15-remaining-read-iops.md),
which covers the cluster side. This one is the developer VM.

## Answer to 1: code is 5.5% of the disk

| path | GB | nature |
|---|---|---|
| `/home/wizard/.cache` | 42.8 | regenerable |
| `/var/lib` (docker 11.8, containerd 1.5) | 16.6 | mostly regenerable |
| `/var/backups/t3-state` | 14.2 | state backups, 6 generations |
| `/usr` | 11.7 | the OS |
| **`/home/wizard/code`** | **10.4** | **the actual work** |
| `.npm` | 6.9 | regenerable |
| `/home/emo`, entire | 7.6 | |
| `.vscode-server` | 5.1 | regenerable |
| `go` | 4.6 | regenerable |
| `.local` | 4.4 | |
| `.claude` | 3.9 | |
| `reel-archive-countries` | 3.6 | unclassified |
| `.t3` | 2.9 | |
| `.virtualenvs` | 2.8 | regenerable |
| `claude-yt` | 2.3 | unclassified |
| `.terraform.d` | 1.9 | regenerable |
| `bg-bakeoff-venv` | 1.7 | regenerable |
| `vault-audit-archive` | 1.6 | unclassified |

Inside the 42.8 GB of `.cache`: `uv` 20.2, `go-build` 4.8, `pip` 4.2, `yarn`
2.5, `ms-playwright` 2.4, `huggingface` 2.4, `claude-yt` 2.3, `pypoetry` 1.6,
`viu-poc` 0.8, `puppeteer` 0.6.

So `uv` and `pip` together held 24.4 GB of downloaded Python wheels, more than
twice all the code on the machine.

Nothing was hidden: deleted-but-still-open files accounted for 0.0 GB, so
`df` and `du` agree and there is no process holding a large unlinked file.

### Which caches were actually being used

"Do we even use them" has a different answer per cache, and only last-access
time answers it. The root filesystem is `relatime`, so atime updates at least
daily on read, which makes it a usable signal at day granularity.

| cache | not accessed in 30 days | verdict |
|---|---|---|
| `uv` | ~12 GB of 20.2 | prune |
| `pip` | **0 bytes** | actively used, leave |
| `go-build` | **0 bytes** | actively used, leave |

Zero bytes of `uv` were older than 90 days, so a 90-day policy would have been
a no-op. 30 days was chosen.

**A `find` sum over the `uv` cache overcounts by roughly 1.6x.** It reported
33.2 GB for a 20.2 GB directory, because uv hardlinks out of the cache into
each virtual environment rather than copying, and 705,847 files carried more
than one link. `find -printf '%s'` counts every link. That same hardlinking is
why deleting a cached file is safe while a venv uses it: the cache path is one
link, the venv keeps its own, and the data survives until the last one goes.

### What was reclaimed

| step | reclaimed |
|---|---|
| docker volumes, 84 of 85 dangling | 3.45 GB |
| `.vscode-server` | 5.1 GB |
| `uv` cache, 30-day age pass plus `uv cache prune` | **12.6 GB** |
| gzip of the t3 state backups | ~12 GB |
| **total** | **~33 GB** |

190 GB to 164 GB, 90% to 77%, free space 24 GB to 50 GB.

`uv cache prune` alone removed 386,540 files for 8.8 GiB after the age pass,
so the two are worth running together rather than either alone.

Two figures worth distrusting next time. `docker system df` reported 12.02 GB
reclaimable in volumes; the prune returned 3.45. And the t3 backups compress
6.6x, measured on a 10 MB sample, which made gzipping worth more than cutting
the retention: six generations compressed beat three generations uncompressed.

### The largest single item is swap, and it hid from every listing

After the reclaim the filesystem sat at 158 GB with 136 GB visible across
`/home`, `/var`, `/usr`, `/root` and `/opt`. The missing 24 GB is two swap
files at the filesystem root:

| file | size | in use |
|---|---|---|
| `/swapfile` | 14 GB | 8.9 GB |
| `/swapfile2` | 10 GB | **9.4 MB** |

**`du -x -d1 /` never named them.** It summarises at depth 1 and rolls plain
files directly under `/` into the total line rather than listing them, so a
24 GB pair of files is present in the number and absent from every row. The
gap read as an accounting error for several measurements before anyone looked
for files rather than directories. `find / -maxdepth 1 -type f` is the check.

This is not really a storage finding. Swap is 24 GB because 26.3 GB of
anonymous demand sits on a 31 GB box, which is the same shortage that drives
the 56% refault rate above. `/swapfile2` holding 9.4 MB of its 10 GB says it
has effectively never been needed, and it exists as a second file rather than
a larger first one because a swapfile cannot be extended in place.

It also sharpens the memory recommendation. Moving 8 to 16 GB from
k8s-node1's idle 33 GB would cut the refaults, reduce paging, and allow
`/swapfile2` to be dropped for 10 GB of disk. One change, three effects.

### Complete accounting after the reclaim

158 GB, nothing unexplained:

| | GB |
|---|---|
| swap files | 24.0 |
| `.cache` (uv 7.6, pip 4.2, go-build 3.6, yarn 2.5, playwright 2.4, huggingface 2.4, claude-yt 2.3) | 28.9 |
| `/var/lib`, docker 11.8 of it | 13.4 |
| `/usr` | 11.6 |
| **`/home/wizard/code`** | **10.7** |
| `/home/emo`, entire | 7.6 |
| `.npm` | 7.0 |
| the three kept archives | 7.5 |
| `go` | 4.6 |
| `.local` | 4.4 |
| `.claude` | 4.0 |
| t3 backups | 4.0 |
| `.virtualenvs` + `bg-bakeoff-venv` | 4.5 |
| `.terraform.d` | 1.9 |
| `.rustup` | 1.4 |
| `/root`, `/opt`, `/var/cache`, `/var/log` | 4.5 |

Real work is `code` 10.7 plus emo 7.6, **18.3 GB**. `/usr` at 11.6 GB is not
Ubuntu base; it is the toolchains installed into it.

The remaining candidates with no expiry are `.npm` at 7.0 and the two
virtualenv trees at 4.5. Everything else is work, OS, or a cache measured as
actively used.

### What was deliberately left

`reel-archive-countries` 3.6 GB, `vault-audit-archive` 1.6 GB and `claude-yt`
2.3 GB, 7.5 GB together. None is a cache by name, none was inspected, and the
owner chose to keep them pending a look.

## Answer to 2: the loop is inference-bound, so flash buys ~3.6%

Measured by parsing the transcripts directly rather than from a metric. Every
`tool_use` carries a timestamp and so does its matching `tool_result`, so the
gap between them is tool execution and the gap from a `tool_result` to the
next assistant message is inference. **246 sessions, 443.4 hours.**

| phase | hours | share |
|---|---|---|
| inference (model) | 173.7 | 39.2% |
| Bash | 170.7 | 38.5% |
| other tools | 93.7 | 21.1% |
| network tools | 4.4 | 1.0% |
| local disk tools | 0.8 | 0.2% |
| subagents | 0.1 | 0.0% |

**21.1% of that is waiting for a human, not for IO**, and it does not belong
in the denominator:

| tool | hours | mean |
|---|---|---|
| `AskUserQuestion` | 78.6 | 255 s |
| `TaskOutput` | 14.7 | 284 s |
| everything else | 0.5 | ~1 s |

Removing that 93.3 hours leaves **350.1 hours of actual working time**:

| phase | hours | share of working time |
|---|---|---|
| **inference (model)** | 173.7 | **49.6%** |
| Bash, unclassified | 127.7 | 36.5% |
| Bash, disk-ish (`git`, `grep`, `find`, `pytest`) | 22.6 | 6.5% |
| Bash, network-ish (`kubectl`, `curl`, `homelab`) | 20.5 | 5.9% |
| network tools | 4.4 | 1.3% |
| local disk tools | 0.8 | 0.2% |

`Read`, `Write`, `Edit`, `Grep` and `Glob` together are **0.2%**, 48 minutes
across 443 hours at 0.46 s a call. Clearly disk-attributable work is 23.4
hours, **6.7%**. Halving the 4.5 s mean of the disk-ish Bash calls, which is
generous because `git status` and `pytest` are partly CPU, gives roughly
**3.6% of working wall clock**.

Against inference at 49.6%, which no local change touches.

**Caveat, stated plainly: the 36.5% unclassified Bash is poorly categorised.**
The classifier reads only the first word of the command, and most commands in
this corpus begin `cd … &&`. The 6.7% is a floor, not a ceiling.

## Why the machine looks worse than the sessions feel

The devvm is fully IO-stalled far more often than 6.7% of the time, and both
things are true at once.

| | someone active | box idle |
|---|---|---|
| p50 | 0.8% | 0.1% |
| p90 | **42.5%** | 5.5% |
| p99 | **79.4%** | 28.5% |

`node_pressure_io_stalled_seconds_total`, working hours, 7 days. It is 8x
worse when someone is on the box, so this is real and user-correlated rather
than night maintenance bleeding into the day. Coverage is 819 samples, about
2.8 days, not the full week.

The two reconcile because a session spends half its life waiting on the model,
and the machine can be stalled throughout without the session noticing. The
stall is felt only inside that 6.7%.

### The cause is memory, not the disk

**56% of everything devvm has read since boot is a re-read.**
`workingset_refault_file` is 350,765,009 pages, 1,437 GB of the 2,557 GB read
since boot, and 80% of those refaults were for pages the kernel still judged
part of the working set. Evictions outran cache fills 2.7 to 1.

Page cache is 6.40 GB on a 31 GB box serving a 203 GB filesystem, because
anonymous memory is 18.27 GB resident with a further 8 GB in swap: 26.3 GB of
anonymous demand on 30.6 GB usable. `pgscan_direct` is 239.7M, so this is
direct reclaim rather than kswapd keeping ahead.

**71 Claude processes hold 13.7 GB of RSS and 66 of them are older than 24
hours**, which is 44% of the box's memory held by detached sessions.

By page-cache fills over a clean 150 s window, `claude` is 69% and `grep` 27%.
The hottest single file is the 216.6 MB Claude Code binary.

## Decision: do not move devvm to the SSD

The case looked strong on the storage numbers and does not survive the loop
numbers.

For: devvm is 24.2% of the host's read operations, the worst-served device on
the box at 54.69 ms per read, its 228 GB LV fits the 475 GB free on VG `ssd`,
and at a measured 28.5 GB/day of writes and 1.43x amplification that is 7.2
years of the 850 EVO's remaining 107 TB warranty headroom. The drive is 3%
worn with 0 reallocated sectors and sits at 0.1% utilisation.

Against, and decisive: it buys about 3.6% of working wall clock.

The `iops_rd=400` QEMU cap was also examined and rejected as the cause. It
does pin devvm at 398 reads/s, but only in the top 1.6% of samples (32 of a
week's 5-minute buckets), and when devvm reads hardest the host sits at 62 to
76% utilisation, so neither the cap nor the spindle is the usual constraint.
Raising it was tried on 2026-09-12, misattributed to an etcd correlation, and
reverted with nothing changed.

`mbps_rd=60` never binds: p99 read bandwidth is 5.7 MB/s.

## What was done instead

One timer. `devvm-cleanup`, daily 04:00, `Nice=15` and
`IOSchedulingClass=idle` so it can never be what competes with a person.

| | policy |
|---|---|
| docker containers, images, builder | `until=24h` |
| docker volumes | dangling |
| `uv` cache | 30-day atime, then `uv cache prune` |
| t3 state backups | gzip all but the newest |

It replaces `docker-disk-gc`, which pruned three of Docker's four object types
and left volumes alone. The old unit is disabled and its files removed rather
than masked, because a mask symlink cannot sit at the path its unit file
already occupies.

## Open questions

1. **What the three unclassified archives are.** 7.5 GB, kept by decision,
   not inspected.
2. **Whether trimming detached Claude sessions is wanted.** 66 processes over
   24 hours old holding 13.7 GB. It would free more than any disk change, and
   it touches other people's sessions, so it is a policy call.
3. **Whether to move memory from k8s-node1.** It holds 49,152 MB and uses
   15,972, so 33,180 MB of slack, while every other node runs 32,768. Its
   requests are 21,852 Mi against 49,226,796 Ki allocatable, 45%, so shrinking
   it to 40,960 leaves requests at 56% of the new allocatable and hands devvm
   8 GB. The host has no spare: allocations total 269,436 MB against 267 GB.
4. **Why `pip` and `go-build` show zero bytes older than 30 days.** Plausible
   that something walks them, and worth knowing before trusting atime on those
   two.
5. **A better classifier for the 36.5% unclassified Bash**, which is the
   single largest uncertainty in the loop split.
