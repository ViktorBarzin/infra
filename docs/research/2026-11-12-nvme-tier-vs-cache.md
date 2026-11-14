# NVMe mirror: an explicit tier or a read cache

**Status:** research, no decision. Written 2026-11-12 from a read-only pass: Prometheus, `lvs`/`dmsetup`/`qm config` over ssh to the host, `kubectl get`, and repo files. Nothing was changed.

## Summary

I recommend putting the two U.2 drives in their own mirrored VG `nvme` with its own thin pool and proxmox-csi StorageClasses. Then move the volumes people wait on onto it, and do not build a write-through cache. A cache over `pve/data` would have to cover the whole 10.54 TiB pool, media included, because `pve/nfs-data` is a thin LV inside that pool. It would leave etcd's writes on sdc. Any trouble on the cache device would become an outage of every VM on sdc plus `/srv/nfs`. The felt gain from tiering is mostly devvm and the worker roots, plus etcd reliability if Viktor lets etcd move. The databases, Prometheus and the 850 EVO volumes gain less than the 5-minute quantiles suggest. Three things need closing before any data lands: which mirror layer to use, how the host boots with a drive missing, and the backup-script changes beyond the VG list.

## How the approaches compare

Each approach had a proposal and two adversarial critiques. The scores are the proposer's score, then the score after critique.

| Approach | Felt benefit | NVMe used | Failure blast radius | Complexity | Verdict |
|---|---|---|---|---|---|
| Explicit tier, separate VG `nvme` | devvm and worker roots: real, inferred. etcd: reliability, only if moved. DBs: small | ~1,650 GiB used today of a ~3,300 GiB pool | Everything moved onto the pair goes down together. sdc tenants, root and OPNsense are unaffected | Medium. One-time moves, a new VG, alerts, backup-script edits | **Recommended.** 8, then 6 |
| lvmcache writethrough over `pve/data` | A guessed 30-50 r/s off sdc on average. About 0 for media and swap, the two largest stall drivers | Up to 3.4 TiB | The whole pve pool, `/srv/nfs` and OPNsense. A missing cache at boot can drop the host to emergency mode | High | Rejected. 3, then 2-2.5 |
| Other cache layers: bcache, Open-CAS, dm-writecache, dm-pcache, L2ARC, QEMU cache modes | None usable. Only the swap move survives | 16 GiB | Varies. bcache cannot be installed without evacuating 7.65 TB | High, or not possible | Rejected. 2, then 2 |
| Whole host on NVMe | The literal version does not fit. The widened version adds ~6.5 r/s of small PVCs | 2.0-2.5 TiB | Adds a boot dependency on the adapters if root moves | High: ~70 rebinds or a storage-ID swap | Rejected as stated. Its "keep root on sdc" part survives. 4, then 3.3-3.5 |
| Hybrid: tier plus a cache for the rest | The tier as above. The cache adds ~1.4 r/s of daytime interactive reads | Tier plus 200-400 GiB | Tier, plus the whole pve pool | Highest | The tier half is the recommendation. The cache half is rejected. 3, then 3 |

## Explicit tier

**Proposal:** mdadm RAID1 over both drives, VG `nvme`, thin pool `nvme/data` with 64K chunks like `sas/data`, and Proxmox storage `nvme-lvm`. Add StorageClasses `proxmox-lvm-nvme` and `proxmox-lvm-encrypted-nvme` in `stacks/proxmox-csi/modules/proxmox-csi/main.tf`, copied from the sas pair. Leave `/srv/nfs`, Windows, the small PVCs and the Proxmox root on sdc.

### What survived

- **Capacity is comfortable.**
  - The listed hot set is etcd root 64, databases 155, devvm 228, node roots 1,280, Prometheus 433, Loki 100 after a resize, HA 64 and nfs-ssd-data 200 GiB. That sums to 2,524 GiB virtual, 76.5% of a 3,300 GiB pool, and ~1,648 GiB used today.
  - The proposal's own totals of 2,574 GiB and 78% were a sum error, corrected by the critique.
  - The 12-month projection of ~1,950 GiB is the proposer's estimate.
- **devvm is the clearest felt gain.**
  - Its disk is `dm-319`. I re-checked the 7d IO-weighted mean read latency today: 13.5 ms.
  - Daytime, 07-21 UTC, it does 13.6 r/s at a weighted 15.4 ms.
  - Its p50 is 10-15 ms at every hour, including 14.2 ms at 21:00 when it does 1.6 r/s. The latency is the spindle itself, not queueing, so NVMe should cut it. The size of the cut is inferred from the P4510 vendor class.
- **Worker roots.** node2's root (`dm-257`) does 10.9 r/s in the daytime at a weighted 9.6 ms, and 24 ms over 7d. There is no pod-start or image-pull baseline, so the user-visible gain cannot be checked yet.
- **etcd.**
  - WAL fsync p99 per 5-minute window over 7d: median 2.75 ms, p99 484 ms, max 1.92 s.
  - 38-39 of ~2,016 windows were above 300 ms. I re-ran the count today and got 38. 24 of 39 fell at 00-05 UTC.
  - The value of moving etcd is reliability, such as hotplug detach timeouts. That is inferred, not measured.
  - A write-through cache cannot take etcd's writes off sdc. Placement can.
- **Copies stay sparse.** `LvmThinPlugin.pm:422` declares sparseinit, and `QemuServer.pm:7927-7971` passes zero-initialized to the mirror job, so node roots should stay sparse after `qm move-disk`. This was read from source and has not been seen on a real move.
- **Disks with snapshots stay behind.** `qm move-disk --delete` refuses disks with snapshots (`PVE/API2/Qemu.pm:4921`). None of the target VMs (102, 103, 200-205, 220) has a snapshot. Windows 300 and OPNsense 100 do, which is one more reason to leave them on sdc.
- **Standing constraints hold.** No CoW layer is added, every LV keeps its own dm device so per-volume attribution stays, and same-host lvmthin hotplug keeps PVC mobility. `csi-leak-reconcile` and the healthcheck do not hardcode storage ids.
- **Media stays on sdc.** In September `/srv/nfs` re-read 0.05x/day, and host page cache already serves it as a host ext4 filesystem.

### What did not survive

- **Database gains are much smaller than the table implied.**
  - The "today" figures were unweighted quantiles over 5-minute windows. I re-checked the IO-weighted 7d means today: MySQL `dm-178` 0.77 ms and pg-v18-2 `dm-175` 1.83 ms. pg-v18-1 is 9.99 ms, but it is the replica, so its latency reaches no user query.
  - Of all database reads, 93.6-98.7% land in 5-minute windows above 100 r/s. The median 5-minute read rate is 0 for MySQL and about 1 r/s for Postgres.
  - On the primary, dawarich accounts for 82% of block reads. Authentik's buffer hit ratio is 99.57%.
  - Moving the databases shortens nightly jobs and frees sdd. People will not notice it in the apps.
- **HA and nfs-ssd do not get faster in any way people would notice.**
  - sdb's IO-weighted 7d mean is 0.23 ms. The same metric gives 0.45 ms on the sda spindles, which a 10k disk cannot do on random reads, so the weighted mean is probably dominated by PERC cache hits.
  - Either way, these moves are justified by the mirror and PLP, not by latency.
- **"The mdadm collector already runs, so no new code" was wrong.**
  - mdadm is not installed (`dpkg -l mdadm` shows `un`). There is no mdadm.conf, no mdmonitor and no md udev rules. `node_md_disks` has no series.
  - Installing mdadm brings udev assembly, initramfs hooks, the last-resort timer and Debian's monthly checkarray, which reads all 3.7 TB of both legs.
- **Proxmox's O_DIRECT warning applies.**
  - https://pve.proxmox.com/wiki/Software_RAID lists mdraid as unsupported. It warns that MD-RAID "is susceptible to breakage from any programs that can issue O_DIRECT write request to it."
  - Every VM disk here runs the default `cache=none`, and every proxmox-csi StorageClass sets `cache=none`. Both are O_DIRECT.
  - If a guest changes a page while the write is in flight, the two legs can diverge.
  - LVM raid1 runs the same raid1 code through dm-raid, so it probably shares the risk. That is inferred, not tested.
  - Divergence has not been measured on this stack.
- **Backups need more than a VG-list edit.**
  - `scripts/lvm-pvc-snapshot.sh:37-43` maps VG to storage id with a hardcoded case: pve to local-lvm, sas to sas-lvm, anything else returns 1. The restore path at `:332` dies with "No Proxmox storage id known for VG". I verified both lines.
  - So nvme snapshots would be created, and restoring one would fail during an incident.
  - `scripts/daily-backup.sh` resolves PVCs by volumeHandle suffix (lines 105-111) and rsyncs with `--delete` (lines 303-316). An old LV kept for rollback under the same name, or a Retained PV with the same claimRef, can overwrite the live copy in the backup.
  - No VM image is backed up any more (`docs/architecture/backup-dr.md`). Losing the mirror means rebuilding the node roots, k8s-master from backup-etcd and devvm, on top of PVC restores.
- **Boot with a drive missing is not handled.**
  - Debian's mdadm starts a degraded array only after `mdadm-last-resort@.timer` fires (`OnActiveSec=30`, upstream).
  - `pve-guests.service` has no ordering on md or LVM activation, so onboot VMs on nvme may fail to start and are not retried. This is inferred and untested.
  - If both drives are missing, `/srv/nfs-ssd` and swap on nvme would have fstab lines without `nofail`. The host would drop to emergency mode and take every sdc tenant down too.
- **The nfs-ssd move needs every consumer stopped.**
  - rsync gives new inodes, so clients still holding NFS handles get ESTALE.
  - Consumers are immich-server, Nextcloud's `/mnt/pve-nfs-ssd`, ollama, tts/stt, t3-afk-data and llama-cpp. The llama-cpp models already live on `/srv/nfs-ssd`, so the 11-12 doc's "models on HDD NFS" is out of date.
  - Unexport with `exportfs -u` before umount. Never restart NFS on the host.
- **swapoff is not free.** `scripts/pve-cgroup-io.sh` deliberately skips swapoff, because it re-read 7.8 GB from sdc on 2026-11-04. That is safe only once etcd is off sdc.
- **"Nothing queues ahead of etcd" overstates it.** etcd would share md0 with 221 GB/day of node-root writes. Contention should drop a lot, but the "after" figure is a guess until fio and an etcd benchmark run under mixed load.
- **Hardware limits are now verified.**
  - Slots 6 and 7 are root ports 00:02.0 and 00:02.2: x8 Gen3, one CPU IIO port split x8x8, `HotPlug-`, 25 W PowerLimit (`lspci -vv`). One port-level fault can take both legs.
  - Replacing a drive means powering off the host, then a full ~3.7 TB resync. The resync time of 1-2 h is inferred.
- **Cooling is not monitored for these drives.** Fans run in IPMI manual mode, driven by a Home Assistant PID loop on CPU temperature (`scripts/fan-control.sh`). Nothing reads NVMe temperature, and `playbooks/files/pve/disk-smart-status` only enumerates megaraid devices.
- **Throttles come back.** QEMU throttles are re-applied hourly by `scripts/apply-mbps-caps.sh`: devvm `iops_rd=400/800, mbps 60`, nodes 60/60, master 100/60. They would clip bursts on NVMe unless the script changes.
- **Smaller corrections.** k8s-node1 boots from `scsi1`, not `scsi0`. The host already has its own playbook, `playbooks/pve-host.yml`.

## Writethrough lvmcache over `pve/data`

### What survived

- **It is technically possible.** lvm2 2.03.31 has accepted a thin pool's `_tdata` as a cache origin since 2.03.12. Thin LVs keep `pool_lv=data`, so PVE, proxmox-csi and `lvm-pvc-snapshot` keep seeing them.
- **A per-LV cache is out.** A cache on a single thin LV would vanish from PVE (`LvmThinPlugin.pm:183-185`), and lvm 2.03.22 cannot snapshot such an LV.
- **Media cannot be left out.** `pve/nfs-data` is a thin LV inside `pve/data`, not a separate LV as the brief says, so a pool cache must include it.
- **The chunk ceiling forces big chunks.** At the 1,000,000-chunk ceiling, a 3.4 TiB cache needs ~3,680 KiB chunks and 240 GiB needs 256 KiB, while reads are 16-40 KB. Each promotion would pull 6-25x the requested bytes from the spindle. This is inferred.
- **Wear is not a constraint.**

### What did not survive

- **The benefit lands where people do not feel it.** Memory #17074 measured excess ops/s by volume during etcd stall windows:

  | Volume | Excess ops/s during stalls |
  |---|---|
  | NFS share | 413 |
  | Host swap | 142 |
  | node2 root | 82 |
  | node5 root | 66 |
  | node4 root | 57 |
  | devvm | 49 |

  A tdata cache gives the top two nothing. smq barely promotes sequential streams: 8-15 chunks from 1.2 GB in the September rig. Swap is a linear LV outside the pool.
- **Power cuts.**
  - This is from the upstream kernel source (`dm-cache-metadata.c`, `dm-cache-target.c`, `dm-cache-policy-smq.c`) and was not checked against 7.0.14 source.
  - After an unclean shutdown every mapped block loads as dirty.
  - A write to a cached block that is already dirty goes only to the cache, even in writethrough mode. Writeback runs only after 1 s of idle.
  - So after a power cut sdc stops being current for cached chunks. A forced uncache, or losing the mirror, would silently return old data.
  - The box is recorded as dying hard in outages (bead code-xgcg), so this path would run.
- **A sick drive stalls the whole pool.** A drive that hangs stalls writes to cached chunks and cache-hit reads across all of `pve/data`, etcd and OPNsense included, until NVMe timeouts and md eject the leg. The nvme_core upstream defaults are 30 s and 5 retries, not read on this host.
- **The September measurements ran on a different stack.** They ran on the devvm with kernel 6.8, lvm 2.03.16 and dm_cache 2.2.0 on loopback, not on the host's 7.0.14 / 2.03.31 / thin-provisioning-tools 1.1.0. Thin snapshots over a cached `_tdata` have never been tested.
- **A missing cache at boot takes the host down.** `pve/data` does not activate, so `/srv/nfs` fails to mount (fstab has no `nofail`) and the host drops to emergency mode. Recovery is over iDRAC with the router down.
- **The whole VG freezes.** With the cache PV missing, LVM refuses all VG pve metadata changes: no PVC create or delete, no snapshots. A cache_check failure would block pool activation even with healthy drives.

## Other caching layers

### What survived

The only part worth keeping is moving host swap off sdc. Host swap holds 6.3-6.5 GB of the 8 GB on sdc and swaps in 6.5 pages/s at a weighted 15.5 ms. Those pages are almost all QEMU guest RAM:

| Owner | Swapped |
|---|---|
| kvm 202 | 1.31 GB |
| devvm (kvm 102) | 1.18 GB |
| kvm 203 | 0.95 GB |
| kvm 205 | 0.85 GB |
| Windows (kvm 300) | 0.48 GB |

So each swap-in stalls a guest vCPU. `vm.swappiness=10`. zram or reclaim tuning would remove this IO without the NVMe. An NVMe swap LV also works.

### Each layer and why it is out

| Layer | Status |
|---|---|
| bcache | The best failure design: it falls back to passthrough when the cache dies. It needs a superblock on sdc3, and 7.65 TB has nowhere to go. |
| Open-CAS | Its own guide says it "cannot accelerate the partition where the operating system resides". That rules out sdc3. Documented, not measured. |
| dm-writecache | Caches writes only, and writes already complete through the BBU in ~0.2 ms. |
| dm-pcache | Needs a DAX device and runs writeback only. |
| EnhanceIO, flashcache | Archived. |
| ZFS L2ARC | Needs ZFS, which is the second CoW layer Viktor ruled out. |
| QEMU writethrough with host page cache | The host page cache averaged 16.4 GB over 7d, MemAvailable bottomed at 32.5 GB, and it does not use the NVMe. |

The critiques left these rejections standing.

## Whole host on NVMe

### What survived

- **The literal version does not fit.** The pve pool holds 7,831 GiB of thin data. nfs-data is 3,296 GiB used, and the stopped TrueNAS VM 9000 has 2,720 GiB virtual.
- **The Proxmox root stays.** It does 0.30 r/s and 3.85 w/s. Community reports, which are anecdotal, say adapter-mounted NVMe boots unreliably on the R730. With root, ESP and OPNsense on sdc, the host still boots and routes if the mirror fails.
- **The pool growth trend.** `lvm_snapshot_thinpool_free_pct{vg="pve"}` went 41.5% 180 days ago, then 27.9% 90 days ago, then 27.6% now.

### What did not survive

- **Widening to every PVC adds little.** It covers ~6.5 r/s of small PVCs plus 5.8 r/s of nightly backup snapshot reads. The price is ~70 copy-and-rebinds across ~40 stacks, a pattern that lost data before (memories #8362 and #15496).
- **The storage-ID swap shortcut breaks configs.** Repointing `local-lvm` would break about 9 VM configs, OPNsense 100 among them. It also requires every hotplugged PVC to be detached first.
- **2,844 GiB of the pve pool is unexplained.** It sits outside active LVs. Splitting it needs `thin_ls`, which was out of scope here.

## Hybrid: tier the hot set, cache the rest

### What survived

- **Little is left for a cache after tiering.**
  - About 34 r/s would stay on sdc. The critique notes the listed parts add to ~38.7 because tmeta, `dm-4`, is a separate device.
  - nfs-data has a 7d median of 0 r/s, a p95 of 1.08 r/s, and bursts up to 1,694 r/s.
  - Of the "interactive" PVCs, only Nextcloud's reads mostly in the daytime: 82% in 06-23 UTC, ~1.4 r/s. Mailserver reads 62% in the 02-05 backup window. Paperless reads mostly 23-02.
- **A second PV in VG pve brings two traps.** Unconstrained `lvcreate`/`lvextend` can land on flash, and a missing PV freezes VG metadata.

### What did not survive

- **"At most ~4.5 r/s that a person waits on" is lower in practice.** The parts sum to 3.4 r/s, and about 1.4 r/s is daytime.
- **"nfs-data is batch nobody waits on" has the wrong reason.** Nextcloud's 3000Gi PV and the Immich originals are there, so people do wait on some reads. Those reads are cold and read once, so a cache would not help them either.

## Measurements that changed since the earlier docs

- **The Immich integrity scan pattern has changed.** Daily nfs-data reads over the last 7 days were 7.4, 40.3, 12.5, 320.4, 24.7, 6.9 and 7.1 GB. The 03:00-04:00 hour had 0 GB, and the big hour was 10:00-11:00 UTC on 2026-11-09. The cause was not checked. September's "nightly 239 GB" no longer holds.
- **devvm memory looks better now.** devvm MemAvailable averages 18.9 GB of 33.6 GB, against 11.5 GB 60 days ago. September's "56% of reads are refaults" cannot be re-derived: `workingset_refault_file` is not scraped, and the counters since boot disagree, 1.6 TB of refaults against 512 GB read.
- **devvm IO pressure is a night effect.** Hourly averages are 23.6% at 04 UTC and 11.4% at 03 UTC, against 0.4-1.6% for most daytime hours.

## Recommended plan

1. **Accept the drives.**
   - Read SMART percentage_used, media errors, power-on hours and firmware revision on both.
   - Confirm the drive and adapter power draw fits the 25 W slot limit.
   - Burn in, then run fio 4k QD1/QD16 on a scratch LV, the same tests as 2026-11-03.
2. **Get Viktor's call on the mirror layer** (open question 1). Then declare it in `playbooks/pve-host.yml` with `--check --diff` first:
   - The mdadm package and array with `--bitmap=internal`, or LVM raid1.
   - VG `nvme`, thin pool `nvme/data` with 64K chunks and some VG space left unallocated, and storage `nvme-lvm`.
   - A drop-in ordering `pve-guests` after the array and VG activation.
   - `nofail` on any fstab line that points at nvme.
   - Schedule one power-off to test a boot with one drive pulled.
3. **Monitoring before data lands:**
   - md degraded, stuck resync and `mismatch_cnt` alerts.
   - An nvme branch in `disk-smart-status`, with its tests, covering critical_warning, spare, percentage_used, media_errors and temperature.
   - An NVMe temperature alert.
   - `NVMeThinPoolFilling`, copied from `SASThinPoolFilling`.
   - An md0 read-latency alert.
4. **Backup scripts before data lands:**
   - Add `nvme` to `LVM_SNAP_VGS` (`lvm-pvc-snapshot.sh:13`) and `PVC_VGS` (`daily-backup.sh:211`).
   - Add an `nvme) echo nvme-lvm` arm to `storage_for_vg`.
   - Run one real restore from an nvme snapshot.
   - Set a rule that the source LV is removed or skipped after each move, so two VGs never hold the same LV name.
5. **Ask Viktor whether etcd moves.** If yes, move k8s-master first with an online `qm move-disk 200 scsi0 nvme-lvm`, so the later bulk copies from sdc cannot stall it. If no, run every later move with `--bwlimit` in a quiet hour.
6. **devvm, then the node roots,** one root per night, online with `--bwlimit`. Use `scsi1` for node1. Check the first target LV stayed sparse. Change `apply-mbps-caps.sh` for disks on nvme in the same pass.
7. **Host swap.** Add an nvme swap LV or zram, and let the old swap drain. Do not swapoff while etcd is still on sdc.
8. **HA and nfs-ssd-data.**
   - Move HA's disk online with `qm move-disk`.
   - Move nfs-ssd-data with every consumer stopped and `exportfs -u` before umount.
   - Do not restart NFS.
9. **Measure for a week.** Compare devvm daytime read latency and PSI, node root latency, etcd fsync stalls, and the residual sdc p95. Then decide on the databases, whose gain is shorter nightly jobs and freeing sdd, and on Prometheus and Loki, whose gain is a guess.
10. **Update the docs:** `docs/architecture/storage.md` (new pool, etcd section), `docs/architecture/backup-dr.md`, `docs/agents/databases.md`, the service catalog, and the devvm-io-guard premise.

No cache layer is part of this plan. I would not reserve an NVMe partition for one either. The post-crash behaviour above applies at any cache size, and the reads left on sdc after tiering are mostly one-pass.

## Open questions

1. **Which mirror layer?**
   - md raid1 hides a single-drive loss from LVM and has a node-exporter collector, but needs mdadm and boot ordering.
   - LVM raid1 activates degraded at boot (`activation_mode=degraded`), but freezes VG `nvme` metadata while a PV is missing and has no alerting.
   - Both carry the Proxmox O_DIRECT warning. The other options are to accept it and alert on `mismatch_cnt`, to set `cache=writethrough` on tier disks at a host RAM cost, or a ZFS mirror on the NVMe alone. That last one breaks the backup scripts' thin-pool model, and whether it falls under the no-second-CoW rule is Viktor's call.
2. **Does etcd move,** reversing the 2026-10-19 decision (memory #16076)? I recommend it, moved first.
3. **Do the databases move at all,** given IO-weighted read latency of 0.77-1.83 ms today?
4. **Thermals.** Do two passive U.2 adapters next to the T4 need the fan loop to read NVMe temperature?
5. **What does a degraded boot actually do?** This needs one test power-off.
6. **What happens to sdd and the TrueNAS VM 9000 disks?** Keep, repurpose for Windows and the registry, or retire.
7. **What changed the Immich scan,** and what read 298 GB on 2026-11-09 between 10:00 and 11:00 UTC?
8. **Every post-move latency figure is a vendor-class estimate** until fio runs on `nvme/data`.

Earlier work this builds on: `docs/research/2026-11-12-ssd-upgrade-cost-benefit.md`, `docs/research/2026-09-12-lvmcache-for-devvm.md`, `docs/plans/2026-09-12-io-bottleneck-ssd-vs-spindles.md`, `docs/plans/2026-09-15-remaining-read-iops.md`, `docs/architecture/storage.md`, and memories #17074, #17005, #12881 and #11059.