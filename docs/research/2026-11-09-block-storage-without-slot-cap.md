# Block storage without the per-VM slot cap

Research note, 2026-11-09. Read-only investigation: nothing was installed,
applied, labelled or restarted on the cluster or the Proxmox host. It builds on
`docs/plans/2026-06-05-block-storage-harden-nfs-design.md`, which kept
proxmox-csi and rejected TopoLVM and Longhorn, and does not repeat that work.

Every claim carries one of three labels:

- **[measured]** read on the live system today: `ssh root@192.168.1.127` with
  read-only commands, `qm guest exec` running `modinfo`/`uname`, `kubectl get`.
- **[source]** read in upstream code or vendor documentation, with a file and
  line or a URL.
- **[inferred]** reasoning from the above, not observed or tested.

## Summary

**Recommendation: keep proxmox-csi's provisioning and LUKS, and replace only its
attach step.** A fork attaches each existing LV to the node VM over NVMe-TCP or
iSCSI, served by the kernel targets already built into the PVE kernel, instead of
hot-plugging it into QEMU. It is the only candidate that meets all five
constraints and adopts all 83 PVCs in place with zero bytes copied. Its costs are
custom code to own, a host address on VLAN 20, and fencing that must be designed.
LINSTOR with its NVMe layer is the maintained alternative, but it needs a copy of
about 445 GiB and changes the LUKS keys the nightly backup depends on.

## Constraints

What "regress" means is set by today's wear tracking. `DiskHDDWorkloadAboveRating`
and `DiskWorkloadJump` both score a RAID1 drive as **writes + reads/2** of its
virtual disk (`stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`,
group "R730 Drives"), so extra reads count too, at half weight. `HDDDailyWriteVolume`
fires above 600 GB/day on sdc (group "R730 Host"). Per-PVC attribution in
`docs/runbooks/disk-wear.md` step 3a joins `node_disk_written_bytes_total` on
device-mapper names matching `vm-9999-pvc-.*`, so a design that renames LVs also
breaks attribution, even at zero extra bytes.

| # | Constraint | Test applied to each candidate |
|---|---|---|
| 1 | No extra physical bytes per application byte | Metadata, journals, activity logs, bitmaps, replication, counters |
| 2 | No added CoW or write-amplification layer | LVM-thin `pve/data` stays the only one, unless replaced |
| 3 | Cross-node mobility | Pod reschedules to another node VM and gets its volume |
| 4 | No new hardware, no spend, free OSS | |
| 5 | Keeps LUKS2 on 55 PVCs, 49 on sdc and 6 on sas; Retain; 3-day thin snapshots, nightly file backup, expansion, SCs on VGs `ssd` and `sas` | Includes the LV naming the host scripts match |

Viktor's framing adds a sixth test: the box is short of **RAM** and **disk
IOPS**, so a design limited by a virtual slot count is wrong, and a design that
spends much CPU or RAM to remove that limit is also suspect.

Host budget today [measured]: 267 GiB RAM, 224 GiB used, 11 GiB free, 42 GiB
available counting page cache, 35 GB shared by KSM. Load average 28.6 on 44
threads. IO pressure `some avg300=3.01`.

## Comparison

| Candidate | 1 Extra writes | 2 CoW layers | 3 Mobility | 4 Cost | 5 LUKS, snapshots, backup, expansion | CPU / RAM | Per-node limit | Migration of 83 PVCs | Maturity | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **B1. proxmox-csi fork, network attach (nvmet or LIO on host)** | 0 | 1, LVM-thin | Yes, any node connects | Free, in-tree kernel targets | All kept unchanged: same LVs, same in-guest LUKS, same volumeHandle | Kernel target, small agent; TCP cost per IO unmeasured | No fixed cap found [inferred] | In place, 0 bytes copied, 1 detach/attach each | Kernel targets mature; the fork is new code | **Recommended** |
| A2. LINSTOR, NVMe layer, no DRBD | 0 | 1, LVM-thin | Yes | Free | LUKS moves to host with LINSTOR keys; LV names change to `pvc-*_00000`; scripts and attribution need changes | JVM controller plus a JVM satellite on host and each node, unmeasured | No fixed cap found [inferred] | Copy about 445 GiB, PV/PVC recreate each | LINSTOR mature; NVMe layer less used than DRBD [inferred] | Viable second |
| A1. LINSTOR, DRBD diskless clients, 1 replica | AL: 0.1% to 100% of write bytes by pattern; 0 with `al-updates no` | 1, plus DRBD metadata area | Yes | Free | As A2, plus DRBD metadata at LV end | As A2, plus DRBD9 module on host and nodes | No fixed cap found [inferred] | As A2 | Mature | Out unless `al-updates no`; A2 is simpler |
| D. proxmox-csi fork adding virtio-blk slots | 0 | 1 | Yes | Free | All kept | Same as today | 45 per VM, up from 29 | In place | Fork | Out: still a slot cap, adds PCI devices |
| B2. Off-the-shelf iSCSI/NVMe-oF CSI | 0 | 1 | Yes | Free | No LUKS; storage node must be a k8s node | Small | n/a | n/a | None fits | Out: no driver provisions on a non-k8s LVM host |
| C. OpenEBS Mayastor, 1 replica | Blobstore metadata | 2: LVM-thin then SPDK lvol | No, data pinned to the io-engine VM | Free | Own encryption; host scripts cannot see volumes | 2 cores, 2 GiB hugepages, 1 GiB per io-engine | n/a | Copy | Mature; LVM backend experimental | Out on 2 and 3 |
| E1. Longhorn v1 or v2, 1 replica | Sparse-file chain; v2 blobstore | 2 | No, replica pinned to one node VM | Free | Host scripts cannot see volumes | v2: 1 core at 100% plus 2 GiB hugepages per node | n/a | Copy | Mature | Out on 2 and 3, June decision stands |
| E2. Ceph single node, size 1 | Writes under 64 KiB go to WAL first: 2x | 2 | Yes | Free | Host scripts cannot see volumes | 4 GiB per OSD target plus mon/mgr | n/a | Copy | Mature | Out on 1, 2, RAM |
| E3. TopoLVM / OpenEBS LVM LocalPV | 0 | 1 | No | Free | | Small | n/a | | Mature | Out on 3, as in June |
| E4. More worker VMs, consolidation | 0 | 1 | Yes | RAM | All kept | 32 GiB RAM per worker | 28 per VM | | | Out on RAM; consolidation is already the June strategy |

## Measured current state

- PVE 9.2.21, kernel 7.0.14-25-pve, qemu-server 9.2.11, pve-qemu-kvm 11.0.3-4
  [measured].
- Host kernel modules present, not loaded: `nvmet-tcp.ko`, `target_core_mod.ko`,
  `dm-crypt.ko`. In-tree `drbd.ko` is **8.4.11**, which LINSTOR cannot use; it
  needs DRBD 9 [measured]. `open-iscsi` is installed on the host; `targetcli`,
  `nvme-cli` and any LINBIT package are not [measured].
- Node kernels are mixed: k8s-master, node2, node3 run Ubuntu 26.04 with
  7.0.0-42/43; node1, node4, node5 run Ubuntu 24.04 with 6.8.0-117/147/149
  [measured]. On node3 (7.0) `nvme-tcp`, `iscsi_tcp`, `drbd` 8.4.11 and
  `dm-crypt` modules exist. On node5 (6.8) `nvme_tcp` and `drbd` are **missing**
  because `linux-modules-extra` is not installed; `iscsi_tcp` and `dm-crypt`
  exist. `open-iscsi` is installed on both; `nvme-cli` on neither. No
  hugepages [measured, node3 and node5 only].
- Network: node VMs sit on `vmbr1` VLAN 20 (10.0.20.100-105). The host has an
  address only on `vmbr0` (192.168.1.127). `ip route get 192.168.1.127` from
  node5 goes `via 10.0.20.1`, the pfSense VM [measured]. NFS traffic for the 72
  NFS PVCs already crosses pfSense today [inferred from the route].
- proxmox-csi VolumeAttachments per node: node1 5, node2 3, node3 9, node4 26,
  node5 16 [measured]. PV objects by class: 28 proxmox-lvm, 59 -encrypted,
  6 -encrypted-sas, 3 -ssd; the counts include Released PVs [measured].
- PVC LVs on the host, excluding snapshots: VG `pve` 91 LVs, 1017 GiB
  provisioned, **373 GiB used**, 59 active; VG `sas` 6 LVs, 155 GiB, **72 GiB
  used**; VG `ssd` 3 thick LVs, 40 GiB. 232 thin snapshots in `pve`; 35 non-PVC
  thin LVs share `pve/data` with them, the VM disks among them [measured].
- StorageClasses set only `cache=none`, `fstype=ext4`, `storage`, `ssd` and the
  LUKS secrets. No QEMU iops or bandwidth limits are in use, so a non-QEMU data
  path loses no throttling [measured].
- Host backup scripts match the repo byte for byte: `md5sum` of
  `/usr/local/bin/lvm-pvc-snapshot` = `scripts/lvm-pvc-snapshot.sh` =
  `f7dbc2ed…`, `daily-backup` = `scripts/daily-backup.sh` = `fd840f9c…`
  [measured].

### What the host scripts assume

- `lvm-pvc-snapshot` walks `VGS="${LVM_SNAP_VGS:-pve sas}"` (line 13), picks
  origins with `grep -E '^vm-[0-9]+-pvc-'` (line 79), names snapshots
  `${lv}_snap_${ts}` (line 185) and maps VG to Proxmox storage id
  `local-lvm`/`sas-lvm` (lines 36-43) [source: `scripts/lvm-pvc-snapshot.sh`].
- `daily-backup` walks `PVC_VGS="${PVC_VGS:-pve sas}"` (line 211), matches
  `vm-9999-pvc-` (line 216), resolves the PVC by a PV whose
  `spec.csi.volumeHandle` ends with the LV name (lines 105-112), and opens LUKS
  snapshots on the host with the single key `/root/.luks-backup-key` (lines
  263-267) [source: `scripts/daily-backup.sh`].

So any design must keep: LVs in `pve`/`sas` thin pools, names
`vm-<n>-pvc-*`, a volumeHandle ending in the LV name, and LUKS headers that
`/root/.luks-backup-key` opens.

### Corrections to existing docs and memories

- `docs/architecture/storage.md` "Per-VM SCSI-LUN cap" cites
  `pkg/csi/utils.go:394` for the LUN loop. At v0.22.0 it is
  `pkg/csi/utils.go:662`, and the error is at line 702 [source].
- Memory #16895 says `lvm-pvc-snapshot` hardcodes `VG="pve"`. Since commit
  c316da157 both scripts loop over `pve sas`; `VG="pve"` at line 14 is only the
  default for the per-VG functions [source]. Memory #16901 already records the
  newer state.
- The proxmox-csi comment that the hard limit of 30 is "the QEMU limit of 30
  iscsi volumes" (`pkg/csi/node.go:64-66`) describes Proxmox's config schema,
  not QEMU: `$MAX_SCSI_DISKS = 31` in `PVE/QemuServer/Drive.pm:156`, and with
  `virtio-scsi-pci` all 31 sit on one controller that QEMU allows 256 devices on
  (`PVE/QemuServer/DriveDevice.pm:30-49`) [source, host files].

## Is the hotplug flakiness tied to disk count?

Partly, and not in the way the cap suggests [inferred, moderate confidence].

- Proxmox verifies every hotplug and unplug by polling `vm_devices_list`, which
  issues QMP `query-pci`, `query-block` and `query-mice`
  (`PVE/QemuServer.pm:3823-3860`), up to 5 times one second apart for add and
  `$timeout //= 5` for delete (`PVE/QemuServer.pm:4102-4128`) [source, host].
- With `virtio-scsi-pci`, SCSI disks are not PCI devices, so the `query-pci`
  reply does not grow with the number of PVC disks. `query-block` does.
- The 2026-11-02 root cause (memory #16805, `docs/architecture/storage.md`
  "Poisoned LUN slots") was `query-pci` timing out while sdc was saturated: 8
  failed unlinks in one night against 0 in 226 the week before. Load on the
  host's disk, not the slot count, flipped the outcome.
- Busy VMs carry more disks and see more attach/detach events, so count and
  failure correlate. Fewer disks per VM shrinks the blast radius of one wedged
  QEMU. It does not remove the race.

What would settle it: join the PVE task log's failed `qmconfig` tasks
(`pvesh get /nodes/pve/tasks`) with the VM's disk count and host
`node_pressure_io_*` at that minute, over the 7 months of history.

The consequence for the comparison: **every design that stops calling QEMU
hotplug for PVCs removes this failure class**, along with `csi-ghost-reconcile`,
`csi-leak-reconcile` and checks #47 and #50 as daily needs. Candidate D does not.

## Candidates

### B1. proxmox-csi fork with network attach (recommended)

**Design.** Keep proxmox-csi's `CreateVolume`, `DeleteVolume`, snapshots and
LUKS code. Replace the two functions that touch the VM:

- `attachVolume` (`pkg/csi/utils.go:615-703`) does `qm set <vmid> --scsiN` and
  returns `PublishContext{"DevicePath": "/dev/disk/by-id/wwn-0x…"}`
  (line 695) [source, v0.22.0].
- `detachVolume` (`pkg/csi/utils.go:705`) removes the disk.

In the fork, `attachVolume` asks a small agent on the PVE host to export
`/dev/pve/vm-9999-pvc-<id>` through the kernel NVMe-oF target or through LIO
iSCSI. For nvmet that is a few configfs writes: one subsystem per attachment,
one namespace, one allowed host NQN, a link to a TCP port. It returns the target
address and NQN or IQN.
`NodeStageVolume` (`pkg/csi/node.go:92`) runs `nvme connect` or `iscsiadm
--login` first, then continues with the existing LUKS open and mount code
unchanged (`pkg/csi/node.go:161-196`). Unpublish deletes the subsystem.

The driver name `csi.proxmox.sinextra.dev`, the volumeHandle format and the
StorageClasses stay as they are, so no PV or PVC object changes.

**Pros**

- **Constraint 1: 0 extra bytes.** nvmet's block-device backend and LIO's iblock
  backstore pass bios straight to the LV; neither keeps a journal, bitmap or
  per-write counter [inferred from the kernel target design; no metadata path
  exists in either for data I/O]. Today QEMU opens the LV with `cache=none`,
  so neither path uses the host page cache.
- **Constraint 2:** LVM-thin stays the only CoW layer.
- **Constraint 3:** any node, including the master, can connect. RWO fencing
  can be as hard as today if each attachment gets its own subsystem and unpublish
  deletes it, which drops the old controller's connection [inferred; needs a
  test, see open questions].
- **Constraint 5, all kept:** same LVs, names, VGs, Retain, snapshots, nightly
  file copy, `/root/.luks-backup-key`, `proxmox-lvm-ssd` and the SAS classes.
  Expansion keeps the Proxmox storage API resize; the target then re-reads the
  size (nvmet namespace `revalidate_size`, or an iSCSI session rescan on the
  node) [inferred; the mechanism needs a test].
- **Per-disk attribution unchanged:** the dm device is still
  `vm-9999-pvc-*`, so disk-wear step 3a keeps working.
- **Per-node limit:** no slot table. The limit becomes NVMe controllers or iSCSI
  sessions per guest; I found no fixed cap below hundreds [inferred].
- **Failure blast radius is smaller than today.** The data path is the host
  kernel. If the agent dies, existing volumes keep working and only new
  attach/detach waits. QEMU monitor stalls no longer affect volumes.
- **Migration: in place, 0 bytes copied.** Each PVC needs one detach and one
  attach, the same event it gets on every reschedule today.
- **Kernel ops:** host side is in-tree (`nvmet-tcp.ko`, `target_core_mod.ko`
  present). iSCSI needs nothing new on nodes; NVMe-TCP needs
  `linux-modules-extra` on the three 24.04 nodes [measured].

**Cons**

- **Custom code to own.** No maintained driver does this (B2). The fork
  touches attach, detach, stage, unstage and expand, plus a host agent. My
  estimate is 1,000 to 2,000 lines including tests [inferred]. Upstream ships
  often: v0.20.0 on 2026-08-05, v0.21.0 on 2026-10-17, v0.22.0 on 2026-11-05
  [source: GitHub releases], so rebasing is recurring work unless upstream takes
  the feature. Upstream closed virtio-blk support #182 as stale on 2025-10-05
  [source], so acceptance is uncertain.
- **Network path.** Without a host address on VLAN 20, every block I/O goes
  node → pfSense → host [measured route]. That makes the firewall VM, and the
  pending OPNsense cutover (ADR-0038), a dependency of every database. The fix
  is a host interface on `vmbr1` VLAN 20, a production network change outside
  Terraform that Viktor approves first.
- **Security.** A target on VLAN 20 is reachable by every VM on it. NQN and IQN
  are self-declared, so ACLs need DH-HMAC-CHAP or CHAP plus a host firewall rule
  limited to 10.0.20.100-105 [inferred]. Encrypted classes stay ciphertext on
  the wire because dm-crypt stays in the guest. The 28 plain `proxmox-lvm` PVs
  cross the in-host bridge in clear.
- **CPU per IO** goes up: guest TCP, virtio-net, host TCP, target, instead of
  virtio-scsi into QEMU. At sdc's 207 reads/s and 351 writes/s weekly average
  (`docs/architecture/storage.md`) I expect it to be small, but I did not
  measure it.
- **New failure modes:** TCP reconnect timeouts. `nvme-tcp` drops the device
  after `ctrl_loss_tmo`, 600 s by default; iSCSI after `replacement_timeout`,
  120 s by default [inferred from upstream defaults; confirm on the nodes]. A host
  reboot already takes every VM down, so it adds nothing there.
- **Exports must survive a host reboot.** configfs is empty after boot, so the
  agent restores exports from its state file before kubelet re-stages.
- **Discard changes.** QEMU passes no discards today because `discard` is unset;
  nvmet passes Deallocate to the LV, so Ubuntu's weekly `fstrim.timer` would start
  returning space to the thin pool, with small `tmeta` writes [inferred]. Decide
  whether that is wanted.

### A2. LINSTOR with the NVMe layer, no DRBD

**Design.** Piraeus operator in k8s, LINSTOR controller in k8s, a
`linstor-satellite` from LINBIT's public `proxmox-9` repo on the PVE host with
an `LVM_THIN` pool on `pve/data`, StorageClass `layerlist: nvme luks storage`,
`NVMe/TRType tcp`. linstor-csi creates `--nvme-initiator` resources on the
pod's node for remote access.

Evidence [source]:

- Layer table: NVME may sit on LUKS on STORAGE
  (`UG9/en/linstor-administration.adoc:1880-1893`). The NVMe layer "is not using
  DRBD ... the data is stored on one node" (lines 1898-1966). `nvme-cli` is
  needed on every satellite (line 1911).
- linstor-csi enables remote access for an `nvme` layer list and uses
  `FlagNvmeInitiator` for diskless placement
  (`pkg/volume/parameter.go:319-324, 410-420`, piraeusdatastore/linstor-csi at
  fa7e6c3).
- Piraeus can use a controller outside k8s, and satellites can run with host
  networking (`docs/how-to/external-controller.md`). It deletes only satellites
  it created (`docs/explanation/deletion-policies.md`), so a hand-registered
  host satellite survives.
- With the controller down, existing volumes keep serving; only management stops
  (`UG9/en/linstor-introduction.adoc:108-113`).
- The LINBIT `proxmox-9` repo, dated 2026-10-28, ships `linstor-satellite`
  1.35.3 and `drbd-dkms` 9.3.4 [measured: downloaded `Packages.gz`].

**Pros**

- Constraint 1: 0 extra bytes, no DRBD metadata. Constraint 2: one CoW layer.
- Constraint 3: any node with a satellite connects.
- Maintained project with snapshots on `LVM_THIN` (Piraeus
  `docs/tutorial/snapshots.md`) and online resize.
- Host side needs no DKMS module with this layer list; `nvmet_tcp` is in-tree.

**Cons**

- **No in-place adoption.** I found no import of existing LVs in the LINSTOR
  guide or server source. LINSTOR names LVs `<resource>_00000`
  (`linstor-administration.adoc:1857`). Migration means a new PV per volume and
  a data copy: about **445 GiB** written and read on sdc and sdd [measured LV
  usage], about 478 GB, close to one day at sdc's 600 GB/day alert line.
- **LUKS keys change.** LINSTOR's LUKS layer runs dm-crypt on the satellite,
  here the PVE host, with keys guarded by a master passphrase that must be
  re-entered after every controller restart unless automated
  (`linstor-administration.adoc:2489-2557`; Piraeus `linstorPassphraseSecret`).
  `daily-backup` opens snapshots with one key file. No supported way was found
  to add that key to LINSTOR-made headers, so the nightly file copy of the 55
  encrypted PVCs breaks until solved.
- **Shares a VG it expects to own.** The guide says "you should not modify or
  create any logical volume in a volume group that is used as the back end for a
  LINSTOR storage pool" (`linstor-administration.adoc:679`). `pve/data` also
  holds 35 Proxmox LVs and the snapshot script's 232 snapshots. VG `pve` has
  about 16 GiB unallocated, so a separate pool is not possible.
- Host scripts and disk-wear attribution need rewriting for `pvc-*_00000`.
- RAM: a JVM controller plus a JVM satellite on the host and on each k8s node.
  I did not measure it; plan to measure before deciding.
- Plaintext crosses the in-host bridge for encrypted PVs, because LUKS sits
  below the NVMe target.
- `nvme_tcp` missing on the 24.04 nodes [measured]; the Piraeus module loader
  lists only `nvmet_rdma` and `nvme_rdma` for the NVMe layer
  (`docs/how-to/drbd-loader.md`).

### A1. LINSTOR with DRBD, diskless clients, 1 replica

Same as A2 with `layerlist: drbd luks storage`; the host holds the only diskful
replica.

**Extra writes, from the source.** A diskless Primary sends writes to the
diskful Secondary, which runs them through its own activity log:
`submit_peer_request_activity_log` calls `drbd_al_begin_io_fastpath` for peer
writes (`drbd/drbd_receiver.c:4422-4440`, LINBIT/drbd at fff993b). DRBD turns
local AL updates off on its own only when the one other diskful node is Primary
(`drbd/drbd_nl.c:2340-2385`). That is not this layout, so the host writes AL
transactions.

Arithmetic [source: `drbd_int.h:860-861, 2388`; drbd-headers
`uapi/linux/drbd_limits.h:139, 218`]:

- One AL extent is 2^22 B = 4 MiB. Default `al-extents` 1237 gives a hot set
  of 1237 × 4 MiB = 4,948 MiB, about 4.8 GiB per volume.
- One AL transaction is a 4 KiB write and carries up to 64 extent changes.
- A write into an extent already hot costs 0 extra. A write into a cold extent
  costs one 4 KiB transaction, shared by up to 64 concurrent misses.
- Sequential writes such as a WAL: 4 KiB per 4 MiB = **0.1%**.
- 4 KiB random writes at queue depth 1 over a 50 GiB volume with a uniform
  spread: about 1 - 4.8/50 = 90% of writes miss, so up to **+90% bytes**,
  and +100% in the limit.
- Real databases sit between; the counters in `drbdsetup events2 --statistics`
  on a test volume would settle it.
- `al-updates no` makes it 0. With a single diskful replica there is no peer to
  resync from, so the safety AL buys is not used [inferred]. The 9.3.5-rc.1
  `ChangeLog` lists fixes to that mode, so test it on the version deployed.

**Other costs:** DRBD 9 is out-of-tree. The host needs `drbd-dkms` 9.3.4 built
for kernel 7.0.14-pve; whether it builds is unverified. Nodes need the Piraeus
module loader to compile DRBD for two kernel families. DRBD internal metadata
sits at the end of each LV, which rules out adopting existing full LVs
(`UG9/en/drbd-internals.adoc`, "Internal metadata", CAUTION block). A2 gets the
same mobility without this.

### D. Stay on proxmox-csi, raise the cap

- Proxmox hotplugs only SCSI and virtio-blk disks; `ide` and `sata` are refused
  (`PVE/QemuServer.pm:4733`). Config keys allow `scsi0..30` and `virtio0..15`
  (`Drive.pm:155-159`), so the most a fork can reach is 31 + 16 = 47 disks, about
  45 PVCs per VM after the boot disk [source, host].
- Each virtio-blk disk is its own PCI device on fixed addresses, `virtio6..15` on
  bridge 2 (`PVE/QemuServer/PCI.pm:223-232`), so the `query-pci` reply grows with
  every PVC, the poll that already times out [source, inferred].
- More SCSI controllers add nothing: `virtio-scsi-pci` already takes 256 devices
  per controller; the 31 comes from config keys (`DriveDevice.pm:30-49`).
  Raising `$MAX_SCSI_DISKS` means patching qemu-server, which every PVE update
  overwrites.
- No newer proxmox-csi release lifts the cap: v0.22.0 of 2026-11-05 is the latest
  and still loops `lun < 30` [source]. Recent upstream fixes went to attach
  correctness: #672 "decide volume attachment from the current vm config", #664,
  #621 [source: GitHub].

Verdict: a virtual cap of 45 in place of 29, with more of the failure it already
has. Out.

### B2. Off-the-shelf iSCSI or NVMe-oF CSI drivers

- `kubernetes-csi/csi-driver-iscsi` "requires existing and already configured
  iscsi server", alpha, one release v0.1.0 of 2022-01-20; no controller
  capabilities (`pkg/iscsi/driver.go:59`) [source].
- `kubernetes-csi/csi-driver-nvmf`: "create a NVMf remote disk on the target
  side" yourself; no controller capabilities (`pkg/nvmf/driver.go:60`) [source].
- democratic-csi provisions iSCSI and NVMe-oF only from ZFS, TrueNAS or
  Synology; `node-manual` takes static targets; no LVM driver and no LUKS
  (`src/driver/factory.js:27-73` at 69c7ebc) [source]. Its `zfs-generic` target
  code is a usable reference.
- **pillar-csi** (isac322, Apache-2.0, created 2026-03-23, v0.5.4, 3
  contributors) exports LVM thin LVs over nvmet or LIO with CHAP, and has LV
  adoption on master but not tagged. Its storage agent is a DaemonSet on a
  labelled k8s node (`site/.../reference/prerequisites.md:14` at 9958709), so the
  PVE host would have to join the cluster; snapshots are "not supported yet"; the
  README does not mention LUKS [source]. Out today. Its configfs code is a reference
  for B1.

### C. OpenEBS Mayastor, 1 replica

- The io-engine binds 2 cores and needs 2 GiB of 2 MiB hugepages plus 1 GiB RAM
  per storage node by default (`chart/values.yaml:698-725`,
  openebs/mayastor-extensions at 710ae25). Interrupt mode exists but is
  "Experimental. Validated only with NVMe-oF TCP targets"
  (`doc/design/interrupt-mode.md`) [source].
- The io-engine must run on a k8s node, so the pool would be a large virtual disk
  of one node VM on `pve/data`: LVM-thin under the SPDK blobstore, two thin
  layers (constraint 2), and every volume dies with that VM (constraint 3).
- The LVM backend is "Experimental!" with thin provisioning and snapshots not
  integrated (`doc/design/lvm.md`; `io-engine/src/lvm/error.rs:30` returns
  "Thin provisioned logical volumes not supported") [source].
- The host scripts cannot see per-PVC volumes. Out.

### E. Others

- **Longhorn v1, 1 replica.** Replicas are sparse files with a chain of
  differencing disks per snapshot (`content/docs/1.12.2/concepts.md:213-219`),
  on a filesystem on a VM disk on LVM-thin: a second layer. A per-write revision
  counter file exists but is off by default for v1
  (`references/settings.md:350-354`). One replica pins the data to one node VM,
  so the June objection becomes a mobility failure instead of a 2x write. Out.
- **Longhorn v2.** +1 core at 100% and +2 GiB hugepages per node, SPDK blobstore
  (`best-practices.md:64-75`). Out on CPU, RAM and constraint 2.
- **Ceph, one host, size 1.** BlueStore sends writes under
  `bluestore_prefer_deferred_size_hdd` = 64 KiB to the WAL first, then to data:
  2x bytes for small writes; `osd_memory_target` defaults to 4 GiB
  (`src/common/options/global.yaml.in`, ceph/ceph master on 2026-11-09). Out on
  constraints 1, 2 and RAM.
- **TopoLVM, OpenEBS LVM LocalPV.** Pin volumes to a node. Out on constraint 3,
  as decided in June.
- **virtiofs.** A file share per PCI device, no block device, no LUKS. Out.
- **More worker VMs.** Each brings 28 slots and needs about 32 GiB RAM; 11 GiB is
  free [measured]. Out.
- **Consolidation, NFS migration.** Already the June strategy; it buys time, not
  a design without a cap.

## Migration sketch for B1

Custom code needs Viktor's confirmation first, per the reuse rule.

1. **Prototype on the throwaway class.** `verify-proxmox-lvm` already exists
   with `reclaimPolicy: Delete` [measured]. Measure with `fio` on one LV: 4 KiB
   random write at queue depth 1 and 32, NVMe-TCP against virtio-scsi; record
   host and guest CPU, latency, and `node_disk_written_bytes_total` for the dm
   device. Pass condition: equal bytes on sdc.
2. **Host side, through `playbooks/pve-host.yml`:** load `nvmet` and
   `nvmet_tcp` at boot; the export agent as a systemd unit with a state file
   and a textfile metric, the same pattern as `csi-leak-reconcile`; a firewall
   rule for TCP 4420 from 10.0.20.100-105 only. The VLAN 20 host address goes in
   the same playbook after Viktor approves it.
3. **Nodes:** `linux-modules-extra` and `nvme-cli` on the 24.04 nodes through the
   node provisioning path, or choose iSCSI and change nothing on nodes.
4. **Fork,** published as an image from GitHub Actions per ADR-0002:
   `attachVolume`/`detachVolume` call the agent; one subsystem per attachment
   for fencing; `NodeStageVolume` connects before the unchanged LUKS code;
   `NodeGetInfo` advertises a higher limit such as 64. The transport is chosen by
   a node label, so both paths run side by side.
5. **Roll per node.** Label one node, cordon the rest of the change away, and
   move its PVCs by scale to 0 then 1: each detaches through `qm set` and
   re-attaches over the network. Non-database volumes first, CNPG and Vault last.
   Zero bytes copied.
6. **After the last node:** `qm config` should show no `vm-9999-pvc` disks;
   then retire `csi-ghost-reconcile`, `csi-leak-reconcile` and checks #47/#50,
   and update `docs/architecture/storage.md`, `docs/runbooks/proxmox-csi-wedged-attach.md`
   and `docs/runbooks/disk-wear.md`.

Rollback at any step: remove the node label and re-attach through hotplug; the
LV never moved.

## Open questions

1. **Fencing.** Does deleting an nvmet subsystem, or unlinking an allowed host,
   drop an established controller connection at once? Test with a hung guest.
2. **CPU per IO** of NVMe-TCP or iSCSI against virtio-scsi on this host. Settled
   by the step 1 benchmark.
3. **Count against host load** as the cause of hotplug failures. Settled by the
   task-log join described above.
4. **VLAN 20 host address.** Is a host interface on `vmbr1` VLAN 20 acceptable,
   and does it fit the OPNsense cutover plan?
5. **Expansion on the network path.** Does nvmet `revalidate_size`, or an iSCSI
   rescan, surface an `lvextend` to a mounted LUKS volume without a detach?
6. **Discard.** Keep it off to match today, or let `fstrim` return space?
7. **Upstream.** Would sergelogvinov accept a remote-attach mode, which removes
   the rebase cost?
8. **LINSTOR, if chosen instead:** satellite and controller RSS on this box;
   whether `drbd-dkms` 9.3.4 builds on 7.0.14-pve for A1; any supported way to
   give `daily-backup` access to LINSTOR LUKS volumes; how LINSTOR behaves next
   to Proxmox and the snapshot script in a shared thin pool.
9. **pillar-csi**, if its agent can run outside k8s, would cover much of B1 as
   maintained code. Not checked beyond its docs.

## Sources

Proxmox VE, read on the host (qemu-server 9.2.11):

- `/usr/share/perl5/PVE/QemuServer/Drive.pm`, lines 155-159
- `/usr/share/perl5/PVE/QemuServer/DriveDevice.pm`, lines 30-49
- `/usr/share/perl5/PVE/QemuServer.pm`, lines 3823-3860, 3970-4010, 4102-4128, 4733
- `/usr/share/perl5/PVE/QemuServer/PCI.pm`, lines 223-232

proxmox-csi-plugin, tag v0.22.0, commit 4ccf1db:

- [`pkg/csi/utils.go`](https://github.com/sergelogvinov/proxmox-csi-plugin/blob/v0.22.0/pkg/csi/utils.go), lines 615-703 (`attachVolume`, LUN loop at 662, error at 702), 705
- [`pkg/csi/node.go`](https://github.com/sergelogvinov/proxmox-csi-plugin/blob/v0.22.0/pkg/csi/node.go), lines 64-66, 92, 161-196
- [`pkg/csi/driver.go`](https://github.com/sergelogvinov/proxmox-csi-plugin/blob/v0.22.0/pkg/csi/driver.go), lines 28-29
- [Issue #182](https://github.com/sergelogvinov/proxmox-csi-plugin/issues/182), closed not_planned 2025-10-05; issues #621, #664, #672

DRBD and LINSTOR:

- [LINBIT/drbd](https://github.com/LINBIT/drbd) at fff993b: `drbd/drbd_receiver.c` 4422-4440, `drbd/drbd_actlog.c` 523-547, `drbd/drbd_nl.c` 2340-2385, `drbd/drbd_int.h` 860-861 and 2388, `ChangeLog`
- [LINBIT/drbd-headers](https://github.com/LINBIT/drbd-headers) at a8daf04: `uapi/linux/drbd_limits.h` 139, 218
- [LINBIT/linbit-documentation](https://github.com/LINBIT/linbit-documentation) at 79bbd3d: `UG9/en/drbd-internals.adoc` (internal metadata, 435-495 activity log), `UG9/en/linstor-administration.adoc` 625-640, 672-679, 1820-1966, 2489-2557, `UG9/en/linstor-introduction.adoc` 108-113
- [piraeusdatastore/linstor-csi](https://github.com/piraeusdatastore/linstor-csi) at fa7e6c3, release v1.13.2: `pkg/volume/parameter.go` 319-324, 410-420
- [piraeusdatastore/piraeus-operator](https://github.com/piraeusdatastore/piraeus-operator) at 9952477, release v2.12.1: `docs/how-to/external-controller.md`, `docs/how-to/drbd-loader.md`, `docs/explanation/deletion-policies.md`, `docs/tutorial/snapshots.md`, `docs/reference/linstorcluster.md`
- LINBIT public repo index: `https://packages.linbit.com/public/dists/proxmox-9/drbd-9/binary-amd64/Packages.gz`

Other drivers:

- [kubernetes-csi/csi-driver-iscsi](https://github.com/kubernetes-csi/csi-driver-iscsi) at ce838d0: `README.md`, `pkg/iscsi/driver.go:59`
- [kubernetes-csi/csi-driver-nvmf](https://github.com/kubernetes-csi/csi-driver-nvmf) at a42c4f9: `README.md`, `pkg/nvmf/driver.go:60`
- [democratic-csi](https://github.com/democratic-csi/democratic-csi) at 69c7ebc: `src/driver/factory.js` 27-73, `examples/node-manual-iscsi-pv.yaml`
- [isac322/pillar-csi](https://github.com/isac322/pillar-csi) at 9958709: `README.md`, `site/src/content/docs/docs/reference/prerequisites.md`, `.../support-matrix.md`
- [openebs/mayastor](https://github.com/openebs/mayastor) at 30c707f: `doc/design/lvm.md`, `doc/design/interrupt-mode.md`, `io-engine/src/lvm/error.rs:30`; [openebs/mayastor-extensions](https://github.com/openebs/mayastor-extensions) at 710ae25: `chart/values.yaml` 698-725
- [longhorn/website](https://github.com/longhorn/website) at a11fb8d, docs 1.12.2: `concepts.md` 213-219, `references/settings.md` 350-354, `best-practices.md` 64-75, `data-engine-comparison.md` 8
- [ceph/ceph](https://github.com/ceph/ceph) master on 2026-11-09: `src/common/options/global.yaml.in` (`osd_memory_target`, `bluestore_prefer_deferred_size_hdd`)

This repo:

- `docs/architecture/storage.md`, `docs/plans/2026-06-05-block-storage-harden-nfs-design.md`, `docs/runbooks/disk-wear.md`, `docs/architecture/networking.md`
- `scripts/lvm-pvc-snapshot.sh`, `scripts/daily-backup.sh`
- `stacks/proxmox-csi/modules/proxmox-csi/main.tf`, `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`
- Memories #8700, #16805, #16807, #16895, #16901, #9344, #7255, #10512

Live measurements were taken read-only on 2026-11-09: on the PVE host `pveversion`, `uname`, `modinfo`, `dpkg -l`, `lvs`, `md5sum`, `free`, `ip`, `cat /proc/pressure/*`, reading the files above; on k8s-node3 and k8s-node5 through `qm guest exec`: `uname`, `modinfo`, `lsmod`, `dpkg -l`, `ip route get`; and `kubectl get nodes|volumeattachment|pv|sc`, `kubectl top nodes`.
