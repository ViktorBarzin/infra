# lvmcache (dm-cache) for the devvm root LV

Research date: 2026-09-12
Target system: devvm, Ubuntu 24.04, kernel 6.8.0-134-generic, LVM 2.03.16(2),
libdevmapper 1.02.185, driver 4.48.0, dm_cache target v2.2.0, virtio-scsi under
QEMU/Proxmox. Root LV is `ubuntu-vg/ubuntu-lv`, 226 GiB ext4, on a 7200rpm RAID1
HDD. Proposed cache device is a 64 GB virtual disk on a Samsung 850 EVO.

Most claims below were measured on the devvm itself, against LVM 2.03.16 and
dm_cache v2.2.0, using loopback volume groups. Where a claim is documentary
rather than measured, the source is named. Anecdote is labelled as anecdote.

## Verdict

**Yes, with three changes to the plan as written.** dm-cache in writethrough is a
reasonable fit for this workload, the online attach and detach both work and take
under two seconds, and losing the SSD cannot lose data. The plan needs these
corrections:

1. **The conversion as specified will fail.** A 64 GiB cache over a 226 GiB origin
   exceeds LVM's default 1,000,000 chunk ceiling at the default chunk size. Either
   size the cache at 60 GiB, or pass `--chunksize 128k`. Measured, see section 9.
2. **Use a cachepool, not a cachevol.** On this exact LVM and
   thin-provisioning-tools pairing, snapshotting a cachevol-backed LV fails and
   leaves the operation half-done. The same snapshot succeeds with a cachepool.
   Measured, see sections 5 and 8.
3. **Writethrough protects the data but not the uptime.** When the cache device
   dies, the LV returns I/O errors immediately and needs a manual repair before it
   will activate again. On a root LV that repair has to happen from a rescue
   environment. Measured, see section 10.

The three premises carried over from the 2026-04 internal note came out as
follows. The "5-10 min VM downtime" figure is wrong: the measured attach took
1.8 seconds on a mounted LV under load. The same-volume-group requirement is
**confirmed**. The claim about sequential scans is confirmed in its effect, and
the mechanism is not a deliberate bypass, and it is not tunable.

Confidence is high on everything measured on this box, moderate on the kernel bug
survey (the record is thin, see section 1), and low on the comparative claims in
section 7, where no primary benchmark for this workload exists.

## 1. Known data-loss, corruption, deadlock and hang bugs

The record for dm-cache is thin, and that is itself the finding. The full commit
history of `drivers/md/dm-cache-target.c` since 2020 contains roughly a dozen
substantive changes, most of them narrow. This is a quiet, low-churn target, not
one under active repair.

Source: `git log drivers/md/dm-cache-target.c`, `dm-cache-metadata.c` and
`dm-cache-policy-smq.c` in
[torvalds/linux](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/log/drivers/md/dm-cache-target.c),
read 2026-09-12.

### The serious recent cluster is passthrough-only

Six patches merged 2026-02-09 fix real defects including a null pointer
dereference, a write hang, a cache coherency violation on the write path, and a
data-loss risk from dirty block handling:

| commit | subject |
|---|---|
| `7d1f98d668ee` | dm cache: fix null-deref with concurrent writes in passthrough mode |
| `0c5eef0aad50` | dm cache: fix write path cache coherency in passthrough mode |
| `4ca8b8bd952d` | dm cache: fix write hang in passthrough mode |
| `e4f66341779d` | dm cache: fix concurrent write failure in passthrough mode |
| `322586745bd1` | dm cache: fix dirty mapping checking in passthrough mode switching |
| `a373b3d5289e` | dm cache: prevent entering passthrough mode after unclean shutdown |

All six carry `Fixes: b29d4986d0da`, a v4.12 rework, so the defects have existed
since 2017. The series cover letter states the affected mode is **passthrough
only, not writethrough or writeback**
([dm-devel, 2026-02](https://ratatoskr.run/dm-devel/2026/02/12508046/t)). The
final patch bumps the target version 2.3.0 to 2.4.0.

This matters directly: the plan uses writethrough and never enters passthrough, so
this cluster does not apply. LVM does not put a cached LV into passthrough during
normal operation, attach, or detach.

### What does touch writethrough

| commit | date | what it fixes | relevance here |
|---|---|---|---|
| `6b9973861cb2` | 2022-11-30 | needs_check flag set after aborting metadata; `Cc: stable` | Found by code inspection, no reported failure |
| `352b837a5541` | 2022-11-30 | ABBA deadlock between shrink_slab and dm_cache_metadata_abort; `Cc: stable` | Real deadlock, reached only on the metadata-abort error path |
| `6a459d8edbdb` | 2022-11-29 | use-after-free in destroy() | Teardown path |
| `5b1fe7bec8a8` | 2018-08-09 | dirty bits not restored after a crash, causing data corruption | Fixed long before 6.8, see section 6 |

The 2018 fix is worth reading even though it predates our kernel, because its
commit message is the clearest statement of the crash model: a regression in 4.9
"results in data corruption on an unclean shutdown with dirty cache blocks on the
fast device". Writethrough has no dirty blocks in normal operation, which is the
structural reason it is the safer mode.

### A resize cluster that lands after our kernel

Four fixes merged 2024-10-22 and one in 2025-03 all concern resizing a cached
device:

- `c0ade5d98979` out-of-bounds access on the first resume when the fast device is expanded
- `792227719725` out-of-bounds access to the dirty bitset when shrinking the fast device (KASAN report in the commit message)
- `235d2e739fcb` wrong origin block count, reached specifically through `lvreduce`
- `135496c208ba` flushing uninitialized delayed_work on a `cache_ctr` error path
- `5da692e2262b` (2025-03-06) BUG_ON when a failed device resume is retried

These landed in v6.13 and later. Our kernel is 6.8.0-134 and reports target
version 2.2.0, so it predates all of them unless Ubuntu backported them, which we
did not verify. Every one of these is reached by **shrinking or expanding** the
cache or origin. Growing the origin was tested here and worked (section 8), but
the safe reading is to treat resize of a cached LV on this kernel as the least
well-tested path, and to detach the cache before any resize.

### Distribution bug trackers

One open Ubuntu bug is directly on point and is discussed in section 8:
[LP #1423796, "Unable to mount lvmcache root device at boot time"](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1423796),
Confirmed, open since 2015. Its stated causes are resolved on Ubuntu 24.04, which
we verified on this box.

We did not find a Red Hat Bugzilla or Debian entry alleging data loss in
writethrough. That is a weak negative: our search was not exhaustive, and absence
of a filed bug is not evidence of correctness.

## 2. Is attaching the cache an online operation

**Yes, fully online, measured at 1.8 seconds on a mounted LV under active write
IO.** The "5-10 min VM downtime" figure in the 2026-04 internal note is not
supported by anything we can find or reproduce.

Measured on this box, LVM 2.03.16, with a 300 MB random file written first and a
400 MB `dd` running concurrently across the conversion:

```
##### Q2: attach cache to a MOUNTED, ACTIVE, IN-USE LV
    Logical volume lvmctest1602255/main is now cached.
  attach rc=0 elapsed=1.833912708s
  STILL MOUNTED: yes
  md5 after attach: 07ea1d5f96c362c79755bd1dfd5af67d  (expect 07ea1d5f96c362c79755bd1dfd5af67d)
```

The filesystem stayed mounted, the concurrent writer was not interrupted, and the
checksum matched. Internally the conversion is a device-mapper table reload with a
brief suspend, which is why it is fast and why in-flight IO is queued rather than
failed.

lvmcache(7) on this system describes the operation as something done to an
existing LV in use, under "3. Start caching the main LV", with no unmount step and
no downtime caveat anywhere in the page. The preceding step says the main LV "may
already exist". Red Hat's own manual page publication of the same text is at
[man7.org lvmcache(7)](https://man7.org/linux/man-pages/man7/lvmcache.7.html).

### The same-volume-group requirement is real

Confirmed. Every syntax form in lvmcache(7) addresses both volumes within one VG
(`vg/main`, `vg/fast`), `lvconvert --cachevol` takes an LV rather than a device,
and an LV cannot exist outside a VG. The `--cachedevice PV` form takes a bare
device, and lvmcache(7) states it "can be used in place of `--cachevol`, in which
case a cachevol LV will be created using the specified device", which still places
the resulting LV in the same VG. The plan's approach of adding the SSD as a second
PV to the existing VG is the correct and only way to do this.

## 3. Is `lvconvert --uncache` reliably online and non-destructive

**Yes in writethrough, measured at 1.2 seconds on a mounted LV under active write
IO**, with the filesystem still mounted and the data verified byte-identical
afterwards:

```
##### Q3: lvconvert --uncache while MOUNTED and under IO
    Logical volume "fast" successfully removed.
    Logical volume lvmctest1602255/main is not cached and lvmctest1602255/fast is removed.
  uncache rc=0 elapsed=1.180025450s
  STILL MOUNTED: yes
  md5 after uncache: 07ea1d5f96c362c79755bd1dfd5af67d  (expect 07ea1d5f96c362c79755bd1dfd5af67d)
```

The LV returned to `linear` layout. As a backout plan this is sound.

lvconvert(8) on this system defines the operation: "Separates a cache pool from a
cache LV, and deletes the unused cache pool LV. Before the separation, the cache
is flushed." In writethrough there is nothing to flush, because every write has
already reached the origin, which is why the operation completes in about a
second rather than taking as long as the dirty set requires.

Two things to know about the backout:

- `--uncache` **destroys the cache volume**. `lvconvert --splitcache` is the
  variant that detaches the cache and keeps the fast LV intact for reuse, per
  lvmcache(7) step 6. Prefer `--splitcache` if you might reattach.
- If interrupted, the risk in writethrough is bounded by the fact that the origin
  is already authoritative. We did not test an interrupted uncache, so this is
  reasoning from the writethrough invariant rather than a measurement. See "what
  we could not determine".

## 4. What the substantive negative feedback actually says

Separating the real complaints from the folklore, and separating fixed bugs from
inherent design:

### Inherent design, not a bug: sequential reads are barely cached

This is real and we reproduced it. Reading a 300 MB file sequentially four times,
1.2 GB of reads in total, promoted **8 to 15 chunks**, under 1 MB of a 512 MB
cache. The same cache under a repeated random read workload promoted **813
chunks** within three passes (section 9).

The mechanism is not an explicit sequential bypass filter. smq tracks hotspots at
a coarse granularity and a one-pass sequential stream never accumulates enough
hotspot weight to earn promotion. The kernel documentation describes smq tracking
"performance of the hotspot queue, which is used to decide which blocks to
promote" and contains no sequential detection or bypass logic
([cache-policies.rst, v6.8](https://www.kernel.org/doc/html/v6.8/admin-guide/device-mapper/cache-policies.html)).

So the internal note's claim is correct about the outcome. It is **not tunable**,
because smq has no tunables at all (section 9). The old mq policy had
`sequential_threshold`, and that policy no longer exists as an implementation.

For this workload this is the right behaviour, not a limitation. Git repositories,
`node_modules` trees and re-read transcripts are random small-file access, which
is the case smq handles well.

### Real and current on this stack: snapshots of a cachevol-backed LV fail

Reproduced twice, on two independently built test volume groups:

```
    Check of pool lvmcd3/fast_cvol failed (status:1). Manual repair required!
    Failed to suspend logical volume lvmcd3/main.
    Aborting. Manual intervention required.
```

`cache_check` is version 0.9.0 from `thin-provisioning-tools 0.9.0-2ubuntu5.1`.
LVM runs it before suspending the LV to take the snapshot, it exits non-zero, and
LVM aborts partway. The same snapshot **succeeds** against a cachepool-backed LV
(section 5). We did not determine the root cause of the `cache_check` failure.

### Fixed, not current: metadata corruption after unclean shutdown

The real incident behind this complaint is commit `5b1fe7bec8a8` (2018), where a
4.9 regression stopped restoring the dirty state of cache blocks after a crash, so
blocks that were dirty were treated as clean and could be evicted, losing the only
current copy. Fixed in 2018, five years before our kernel. It only ever affected
writeback, because writethrough has no dirty blocks.

### Anecdote, not verified

A [Proxmox forum thread, "LVM failure caused by cache SSD
failure"](https://forum.proxmox.com/threads/lvm-failure-caused-by-cache-ssd-failure.73314/)
reports a volume group rendered unusable by a failed cache SSD. We did not verify
the cache mode, the LVM version, or the recovery steps taken. Our own measurement
of that scenario is in section 10 and is the more reliable guide. Treat the thread
as corroboration that the failure is disruptive, not as evidence about data loss.

Reports of "worse than no cache" performance generally describe either sequential
workloads, which is the design behaviour above, or a cache too small to hold the
working set. We found no primary-source benchmark showing a correctly sized
dm-cache being slower than the bare spindle for random reads.

## 5. cachepool versus cachevol

**Use a cachepool here.** Two reasons, one documentary and one measured.

lvmcache(7) as shipped with LVM 2.03.16 is explicit, in the section titled
"dm-cache with separate data and metadata LVs":

> Preferred way of using dm-cache is to place the cache metadata and cache data on
> separate LVs. To do this, a "cache pool" is created, which is a special LV that
> references two sub LVs, one for data and one for metadata.

and under `--cachepool`:

> When using a cache pool, lvm places cache data and cache metadata on different
> LVs. This has a bit better performance for dm-cache and permits specific
> placement and segment type selection for data and metadata volumes.

This corrects a common assumption that cachevol is the modern replacement.
cachevol is the **newer** form and is the only form dm-writecache supports, and
for dm-cache upstream still names cachepool as preferred.

The measured reason is stronger. On this box, snapshotting a cached LV fails with
a cachevol and succeeds with a cachepool:

| cache format | `lvcreate -s` on the cached LV |
|---|---|
| cachevol | `Check of pool fast_cvol failed (status:1). Manual repair required!` then `Failed to suspend logical volume` |
| cachepool | `Logical volume "snapp" created.` |

Practical differences:

| | cachepool | cachevol |
|---|---|---|
| layout | two sub-LVs, `_cdata` and `_cmeta` | one LV, split internally |
| targets | dm-cache only | dm-cache and dm-writecache |
| upstream preference for dm-cache | preferred, per lvmcache(7) | supported |
| snapshot of the cached LV, this stack | works | fails, measured |
| extra volumes created | also allocates a `_pmspare` metadata spare | none |
| metadata placement control | yes, can pin metadata to a separate device | no |

At our sizes a cachepool allocated an 8 MiB `_cmeta` plus an 8 MiB `_pmspare`.

## 6. Does the cache survive a reboot warm

**Yes, the metadata is persistent and the mapping survives a clean stop.** Measured
across a full `vgchange -an` then `vgchange -ay` cycle, which is what a clean
shutdown and boot does to the device:

```
  before:          CacheUsedBlocks 8   CacheReadHits 5    CacheReadMisses 49
  after-reactivate: CacheUsedBlocks 15  CacheReadHits 92   CacheReadMisses 79
```

Used blocks did not reset to zero and the hit counters continued from their prior
values rather than restarting, so the block mapping was loaded from disk rather
than rebuilt. The cache starts **warm**, not cold.

Caveat on scope: this is a deactivate and reactivate cycle, not a real reboot. It
exercises the same suspend, metadata commit, and reload path, but we did not
reboot the devvm.

### After an unclean shutdown

The kernel documentation states the model plainly
([cache.rst, v6.8](https://www.kernel.org/doc/html/v6.8/admin-guide/device-mapper/cache.html)):

> The metadata should always be consistent in spite of any crash.

and separately, about the dirty bit:

> The 'dirty' state for a cache block changes far too frequently for us to keep
> updating it on the fly. So we treat it as a hint. In normal operation it will be
> written when the dm device is suspended. If the system crashes all cache blocks
> will be assumed dirty when restarted.

For writeback that means a post-crash writeback storm. **For writethrough it is
harmless**: every block already matches the origin, so treating them as dirty
causes redundant migration IO rather than incorrect data. Commit `a373b3d5289e`
(2026-02) confirms the reasoning from the other direction, blocking passthrough
activation after an unclean shutdown because "the passthrough mode doesn't handle
dirty blocks ... we'll risk data loss while updating an actually dirty block".
Writethrough is not blocked, because in writethrough the assumption is merely
pessimistic rather than wrong.

We did not test a real unclean shutdown. This section is documentary.

## 7. Comparison with the alternatives

Confidence here is lower than elsewhere. We found no primary benchmark for this
specific workload, and the frequently cited comparisons are from 2013 and predate
smq entirely. The table reflects design properties, which are verifiable, rather
than performance claims, which are not.

| | dm-cache writethrough | dm-writecache | bcache | move hot dirs to SSD |
|---|---|---|---|---|
| caches reads | yes | **no** | yes | n/a, data lives there |
| fixes our actual problem, page-cache refault on re-read | yes | no | yes | yes, for what you move |
| works on an existing populated filesystem | yes | yes | **no**, needs a fresh device with a superblock | yes |
| can be removed online | yes, 1.2 s measured | yes | requires detach and generally a rebuild | yes |
| data at risk if SSD dies | none | yes, it is a write cache | depends on mode | yes, whatever lives there |
| in-tree and shipped by Ubuntu 24.04 | yes | yes | yes | n/a |

**dm-writecache is disqualified.** It caches writes only. lvmcache(7) states:
"Data read from the main LV is not stored in the cache, only newly written data."
Our workload is 1.8:1 read-heavy and the stated problem is re-reading evicted
pages, so a write cache does not address it.

**bcache is disqualified on migration cost, not merit.** It requires the backing
device to be registered with a bcache superblock before use, which means the
existing 226 GiB root filesystem cannot be converted in place. That is a rebuild
of the VM root, against a 1.8 second online attach for dm-cache. bcache's design
is genuinely aimed at random IO and is a reasonable choice for a new system.

**Moving hot directories to the SSD** avoids the cache layer entirely and gives
predictable performance for what you move, at the cost of manual placement
decisions, no adaptation as the working set shifts, and 64 GB being a hard ceiling
per directory rather than an adaptive pool. For a working set spread over many git
repositories and `node_modules` trees whose hot subset changes with what is being
worked on, the adaptive cache is a better match. This is a judgement, not a
measurement.

The newer `dm-pcache` target has been discussed upstream
([LWN](https://lwn.net/Articles/1048510/)) but is not in 6.8 and is not an option.

## 8. Interactions

### ext4

No issue found. The filesystem stayed mounted across attach and detach, checksums
matched, and `e2fsck -fn` reported a clean filesystem afterwards.

One trap in lvmcache(7) applies to xfs, not to us, but is worth knowing: a cache
pool created on a 4096-byte logical block device cannot be attached to a main LV
carrying a filesystem built for 512-byte sectors, and "the main LV will likely fail
to mount". Our root is ext4 and the check is worth doing before conversion anyway.

### discard and TRIM

Works. `fstrim` on the cached LV trimmed 1.8 GiB and `discard_max_bytes` was
non-zero on the cache device mappings.

```
  /…/cachelab/mnt: 1.8 GiB (1939652608 bytes) trimmed
```

### QEMU guest on virtio-scsi

No dm-cache-specific interaction found in the kernel documentation or commit
history. dm-cache operates on block devices and is indifferent to the transport.
The relevant consideration is that the cache device must be backed by genuinely
fast storage, so the Proxmox disk should use `cache=none` to avoid double caching
in the host page cache. We did not test on the real virtio-scsi disk, only on
loopback devices, so this is reasoning rather than measurement.

### Growing a cached LV

Works on this version. `lvextend` grew the cached LV from 2.00 GiB to 2.50 GiB
while mounted, and `resize2fs` completed:

```
    Size of logical volume lvmctest…/main_corig changed from 2.00 GiB to 2.50 GiB.
    Logical volume lvmctest…/main successfully resized.
```

Tempered by section 1: the kernel resize fixes from 2024-10 and 2025-03 are not in
6.8. They are reached by shrinking, and by expanding the fast device before first
resume. Growing the origin is the case we tested and the case not implicated by
those commits. Detaching the cache before any resize remains the conservative
choice.

### Snapshotting a cached LV

Depends on the cache format, see section 5. Fails with a cachevol on this stack,
works with a cachepool.

### fsck

Normal. Unmount, `e2fsck -fn`, remount, checksum still matched. The cache does not
have to be detached first.

### Booting from a cached root LV

[LP #1423796](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1423796) is open
and Confirmed since 2015 and reports exactly this plan failing: the initramfs
lacked the dm-cache modules and the `cache_check` binary, so a cached root LV could
not be activated at boot. Reported against 15.04 and confirmed through 20.04.

**Both causes are resolved on this box**, verified directly against the running
initramfs:

```
usr/lib/modules/6.8.0-134-generic/kernel/drivers/md/dm-bio-prison.ko.zst
usr/lib/modules/6.8.0-134-generic/kernel/drivers/md/dm-bufio.ko.zst
usr/lib/modules/6.8.0-134-generic/kernel/drivers/md/dm-cache-smq.ko.zst
usr/lib/modules/6.8.0-134-generic/kernel/drivers/md/dm-cache.ko.zst
usr/lib/modules/6.8.0-134-generic/kernel/drivers/md/persistent-data/dm-persistent-data.ko.zst
usr/sbin/cache_check
```

`/etc/initramfs-tools/initramfs.conf` sets `MODULES=most`, which is why the modules
are present. Note that the lvm2 initramfs hook itself only does
`copy_exec /sbin/dmsetup` and `copy_exec /sbin/lvm`, so `cache_check` arrives by
another path. **If `MODULES` is ever changed to `dep`, re-verify before rebooting**,
because a cached root LV with a stripped initramfs is an unbootable VM.

## 9. Tunables that matter for this workload

### The chunk size decision is forced, and the default fails

The most important measured finding in this section. LVM enforces a ceiling of
1,000,000 chunks per cache. At a 226 GiB origin these are the combinations that
actually convert:

| cache size | chunk size | result |
|---|---|---|
| 64 GiB | default (64 KiB) | **FAIL** `Cache data blocks 134119424 and chunk size 128 exceed max chunks 1000000` |
| 64 GiB | `--chunksize 128k` | OK, metadata 14.82% used |
| 64 GiB | `--chunksize 32k` | **FAIL**, same ceiling |
| 61 GiB | default (64 KiB) | OK, metadata 16.37% |
| 60 GiB | default (64 KiB) | OK, metadata 16.11% |
| 32 GiB | default (64 KiB) | OK, metadata 14.82% |
| 32 GiB | `--chunksize 32k` | **FAIL**, same ceiling |

Note also that the default chunk size LVM selects is **64 KiB, not the 32 KiB
minimum** the brief assumed. 32 KiB chunks are unreachable at any cache size above
roughly 30 GiB without raising `allocation/cache_pool_max_chunks`.

**Recommendation: a 60 GiB cache at the default 64 KiB chunk size.** Giving up
4 GiB of SSD keeps the chunk at 64 KiB, which is 3.2x the 20 KB average read,
rather than moving to 128 KiB, which is 6.4x. Every cache miss that promotes pulls
one whole chunk from the spindle, so a larger chunk costs more read amplification
on exactly the random small reads this is meant to accelerate. lvmcache(7) makes
the same point: "Using a chunk size that is too large can result in wasteful use of
the cache, in which small reads and writes cause large sections of an LV to be
stored in the cache."

If you want all 64 GiB, `--chunksize 128k` is the supported way and it converted
cleanly.

### Raising the ceiling to get 32 KiB chunks, and why not to

32 KiB chunks are reachable at 64 GiB only by overriding
`allocation/cache_pool_max_chunks`, which needs to go to at least 2,097,152.
Measured, it does then work, and LVM objects:

```
    WARNING: Configured cache_pool_max_chunks value 3000000 is higher then recommended 1000000.
    Logical volume lvmcd8/main is now cached.
```

The option's own documentation in `lvmconfig --withcomments` explains the ceiling:

> The maximum number of chunks in a cache pool. For cache target v1.9 the
> recommended maximumm is 1000000 chunks. Using cache pool with more chunks may
> degrade cache performance.

The measured metadata cost at 32 KiB over 64 GiB is 23,552 metadata blocks, about
92 MiB, of which **17.87% is consumed at zero cache occupancy**. Comparable figures
are 16.11% for 60 GiB at 64 KiB and 14.82% for 64 GiB at 128 KiB. smq also tracks
2,094,208 entries in memory instead of roughly one million.

The gain is real but small: 64 KiB is already only 3.2x the 20 KB average read.
The recommendation stays at 60 GiB with the default 64 KiB chunk, which keeps the
configuration inside a limit upstream set deliberately.

### smq has no tunables, and the mq knobs are inert

The brief asks about `sequential_threshold` and `read_promote_adjustment`. These
exist in the interface and **do nothing**. The kernel source is explicit
([dm-cache-policy-smq.c, v6.8](https://raw.githubusercontent.com/torvalds/linux/v6.8/drivers/md/dm-cache-policy-smq.c)):

> smq has no config values, but the old mq policy did. To avoid breaking software
> we continue to accept these configurables for the mq policy, but they have no
> effect.

`mq` is registered in that same file as an alias of smq. The old mq implementation
is gone. Confirmed on the live device, where every one of them reads zero:

```
migration_threshold=2048,random_threshold=0,sequential_threshold=0,
discard_promote_adjustment=0,read_promote_adjustment=0,write_promote_adjustment=0
```

The kernel documentation puts it positively: "smq also does not have any cumbersome
tuning knobs."

### migration_threshold

The one knob that does work. Default 2048 sectors, 1 MiB, confirmed live. It caps
migration bandwidth between cache and origin. lvmcache(7) notes "dm-cache is not
taking any account of normal io traffic going to the devices", so this is the only
throttle. **Leave it at the default.** Raising it makes the cache warm faster at
the cost of competing with foreground IO on a 7200rpm spindle, which is the exact
resource under pressure. Revisit only if warming proves too slow in practice.

Note the interaction with chunk size documented in lvmcache(7): "Lvm2 ensures
migration threshold is at least 8 chunks in size." At 64 KiB chunks, 8 chunks is
512 KiB, below the 2048-sector default, so the default stands. At 128 KiB chunks,
8 chunks is 1 MiB, exactly the default.

### smq promotes this workload well, measured

The decision-relevant experiment. A 1 GiB cache, 64 KiB chunks, against a repeated
random 20 KB O_DIRECT read workload over a fixed roughly 50 MB hot set, 4000 reads
per pass:

| pass | used blocks | read hits | read misses |
|---|---|---|---|
| baseline | 13 | 0 | 0 |
| 1 | 232 | 611 | 4393 |
| 2 | 594 | 2866 | 7142 |
| 3 | 813 | 7651 | 7361 |
| 4 | 813 | 12655 | 7361 |
| 8 | 813 | 32671 | 7361 |

The hot set was fully resident after three passes and **the miss count stopped
increasing entirely** from pass 4 onward, a 100% hit rate. 813 chunks at 64 KiB is
52 MB, matching the hot set. Promotion is not too conservative for random
small-file reads.

Absolute IOPS from this test are not reported because the backing store was a
loopback file on the devvm's own storage, so the numbers say nothing about a real
spindle. The hit and miss counts are dm-cache's own accounting and are independent
of backing speed.

### Settings to use

```sh
lvconvert --type cache --cachepool fast --cachemode writethrough vg/main
```

Everything else at default: smq policy, 64 KiB chunks (with a 60 GiB cache),
`migration_threshold=2048`, `cache_metadata_format=auto`. The defaults are right
for this workload, and the only real decision is the cache size and chunk size
pairing above.

## 10. What happens to the data if the SSD dies in writethrough

**The data is safe. The availability is not.** This is the sharpest correction in
this document, because the documentation only addresses the first half.

The documentary claim, lvmcache(7) under "dm-cache cache modes":

> The default dm-cache cache mode is "writethrough". Writethrough ensures that any
> data written will be stored both in the cache and on the origin LV. **The loss of
> a device associated with the cache in this case would not mean the loss of any
> data.**

and the kernel documentation, cache.rst:

> If writethrough is selected then a write to a cached block will not complete
> until it has hit both the origin and cache devices. Clean blocks should remain
> clean.

Both statements are about **data**, and both are correct. Neither says anything
about whether the volume keeps working, and it does not.

### Measured

We built a writethrough cache, warmed it, then flipped the cache device's backing
to `dm-error`, which is a total instantaneous device failure with no warning:

```
  reading 300MB file through the now-dead cache:
dd: error reading '…/mnt/data.bin': Input/output error
  read rc=1
  dmstatus: 0 4194304 cache Error
  dmesg: device-mapper: cache: 252:8: aborting current metadata transaction
  dmesg: device-mapper: cache: 252:8: failed to abort metadata transaction
  dmesg: device-mapper: cache: 252:8: unable to read needs_check flag, setting failure mode.
  dmesg: device-mapper: cache: 252:8: switching cache to fail mode
```

The entire cached LV entered `cache Error` state and every read returned EIO,
**including reads of blocks that were never cached**. dm-cache cannot read its own
metadata, so it fails the whole target rather than serving from the origin. There
is no automatic fallback to the origin device.

### Recovery, and it does work

With the cache PV permanently removed from the machine:

```sh
lvconvert --yes --force --uncache vg/main     # detach the dead cache
vgreduce --removemissing --force vg           # drop the missing PV
vgchange -ay vg
```

Result: the LV came back as plain `linear`, mounted, and the checksum matched the
value taken before the cache was ever attached. `e2fsck -fn` reported a clean
filesystem.

```
  RECOVERED md5: 7883c5b747af0e5da9d682f754c098c0
  GOLD         : 7883c5b747af0e5da9d682f754c098c0
  fsck: /dev/lvmcd3/main: 12/131072 files (0.0% non-contiguous), 102956/524288 blocks
```

So: **zero data loss, confirmed by checksum, and a hard outage requiring three
manual commands.**

Two things to plan for:

- On a **root** LV, that repair cannot be run from the running system, because the
  root filesystem is the thing returning EIO. It needs a rescue boot or a Proxmox
  recovery ISO. Budget for that, and keep the three commands somewhere reachable
  from outside the VM.
- During the uncache, LVM prints `WARNING: Data may be lost by detaching writeback
  cache without flushing` **even in writethrough mode**. It is a generic message
  and is benign here, and it is alarming at exactly the wrong moment. Expect it.

The 850 EVO is consumer hardware roughly a decade old. Weigh that against an
outage whose repair path runs from a rescue environment.

## What we could not determine

- **Whether Ubuntu backported the 2024-10 and 2025-03 kernel resize fixes into
  6.8.0-134.** We established they are not in mainline 6.8 and did not audit the
  Ubuntu kernel changelog. This matters only if you resize a cached LV.
- **The root cause of the `cache_check` failure on cachevol snapshots.** Reproduced
  reliably, and we did not establish whether it is an LVM 2.03.16 bug, a
  thin-provisioning-tools 0.9.0 bug, or a metadata format interaction. The
  workaround, using a cachepool, is verified.
- **Behaviour under a real unclean shutdown.** Section 6 is documentary. We tested
  a clean deactivate and reactivate, not a power cut.
- **Behaviour of an interrupted `lvconvert --uncache`.** Not tested. The
  writethrough invariant says the origin is always current, which bounds the risk,
  and that is reasoning rather than measurement.
- **Real performance on the actual hardware.** Every measurement here used loopback
  devices on the devvm's own storage. Promotion behaviour and hit ratios transfer;
  latency and IOPS numbers do not.
- **Whether `cache=none` is set on the Proxmox disk** that would back the cache
  device. Worth checking before building it, so the SSD is not double-cached in the
  host page cache.
- **An exhaustive bug tracker survey.** We checked kernel git, dm-devel, and
  Launchpad. We did not systematically work Red Hat Bugzilla or the Debian BTS, so
  the "no reported writethrough data loss" finding in section 1 is a weak negative.

## How this was tested

All measurements ran on the devvm against loopback volume groups, isolated from
real storage with an LVM `global_filter` so the test PVs could not be confused with
system devices. Scripts are in the session scratchpad at
`/tmp/claude-1000/-home-wizard-code/5ebaa9d9-b107-4597-b433-551f1bdd756b/scratchpad/`
(`cachetest.sh`, `cachetest3.sh`, `cachetest5.sh`, `ct6b.sh`, `ct7.sh`, `rr.py`).
They are not durable, and the numbers they produced are quoted inline above.

Two earlier runs were discarded rather than reported. One had both PVs visible
through two device paths, so LVM refused the VG and the filesystem never landed on
the LV. One called `fio`, which is not installed on this box, so the counters never
moved and the run measured nothing.
