# Post-Mortem: Immich anca-elements Bulk Ingest IO Storm → k8s-node1 Reboot

| Field | Value |
|-------|-------|
| **Date** | 2026-05-25 |
| **Duration** | ~9h from job start (2026-05-24 23:55Z) to node1 reboot (2026-05-25 09:33Z); service restoration ongoing (~1h elapsed at time of writing). |
| **Severity** | SEV2 — k8s-node1 went down, ~33 deployments lost their only replica, DNS partially degraded (Technitium primary on node1), Loki down, GPU stack down, backup pipeline timed out for the day. No data loss. |
| **Affected Services** | 33 deployments, 3 StatefulSets, 9 DaemonSets across ~30 namespaces. Most concentrated on k8s-node1 (the only GPU node and home of several pinned services). |
| **Issue** | TBD (no GitHub issue filed yet) |
| **Status** | Draft — recovery in progress |
| **Recurrence count** | **3rd IO-pressure-induced incident in 17 days** at time of writing; **recurred 2026-05-26** (Alloy log-read storm, mem id=2726) and **2026-06-01** (Immich Duplicate Detection ML/thumbnail backfill — see [Update 2026-06-01](#update-2026-06-01--recurrence-immich-duplicate-detection)) |

## Summary

The `anca-elements-import` Kubernetes Job — a one-shot bulk import of ~34k photos (770 GB) from `/srv/nfs/anca-elements` into Immich — ran with `immich-go --concurrent-tasks 20` and no CPU/IO limits. The 20 parallel NFS readers combined with the Immich ML pipeline saturated sdc (the 10.7 TB HDD thin pool holding all VM disks) for hours. Sustained disk contention starved the k8s-node1 VM's IO until the VM rebooted at 09:33 UTC. ~60 pods on node1 went zombie; the proxmox CSI driver lost its registration; the NVIDIA driver DaemonSet entered CrashLoopBackOff; the daily-backup pipeline was killed by its 4h systemd timeout while waiting on post-reboot ext4 orphan-inode cleanup.

This is the third time in 17 days that an IO event has taken meaningful slice of the cluster offline. We cannot keep treating each one as a one-off.

## Impact

- **User-facing**: DNS resolution degraded (1 of 3 Technitium replicas down on node1). 20 self-hosted apps (changedetection, freshrss, frigate, navidrome, wealthfolio, etc.) returned 502 or hung. GPU-dependent services (Frigate ML, Immich ML, nvidia-exporter) had no GPU available.
- **Blast radius**: ~60 zombie pods on k8s-node1; 33 deployment replicas missing cluster-wide; 1 StatefulSet (Loki) unavailable. Multi-Attach errors on ~8 proxmox-lvm PVCs prevented reschedule onto healthy nodes for ~30 min.
- **Duration**: Initial IO degradation ~01:30Z (job ran ~85 min then ended). VM stayed alive but degraded for ~8 hours after the job ended (likely due to filesystem journal recovery / page cache pressure tail). Hard reboot at 09:33Z. Service restoration began at 10:00Z.
- **Data loss**: None. All PVCs intact; no failed writes detected.
- **Monitoring gap**: We had **no alert** for "VM is about to crash from sustained IO pressure." `NodeHighIOWait` fired but didn't escalate, and PVE-host-level IO PSI metrics aren't scraped into Prometheus.

## Pattern — this is the third time

| Incident | Date | Root IO source | Outcome |
|----------|------|----------------|---------|
| 1 | 2026-05-09 | Stale NFS kthread to decommissioned TrueNAS (`/usr/local/bin/weekly-backup` artifact) wedged in `rpc_wait_bit_killable` | PVE loadavg ~15 sustained, IO PSI stall on node3, no user-visible outage |
| 2 | 2026-05-16/17 | kured stuck + GPU driver Ubuntu 26.04 mismatch + NFS-CSI Keel upgrade race | Multi-issue cluster degradation; required manual recovery |
| 3 | 2026-05-25 (**this incident**) | Immich `anca-elements-import` Job with 20 parallel uncapped readers | k8s-node1 VM reboot, ~33 deployments down, backup pipeline broken |
| 4 | 2026-05-26 | Grafana Alloy DaemonSet read 12.18 TB of logs in ~24h (silently lost its `controller.resources` limit) | sdc 97% util, all VMs + NFS starved (mem id=2726) |
| 5 | 2026-06-01 | Immich library-wide **Duplicate Detection** → ML/thumbnail backfill read originals at server-side `thumbnailGeneration` concurrency **8** | sdc ~100% util, 64 `nfsd` threads D-state, **etcd starved → kube-apiserver down ~30 min** |

**Common pattern**: a single uncontrolled IO-heavy workload (or a stale connection) saturates the shared sdc thin pool, which hosts **all VM disks** for the entire cluster. There is currently no IO budget enforcement between workloads, no PVE-level IO QoS between VMs, and no alerting that fires *before* a node crashes.

We have a single point of contention (sdc). Every storm finds it.

## Timeline (UTC)

| Time | Event |
|------|-------|
| **2026-05-24 23:55** | `anca-elements-import` Job starts. immich-go v0.31.0, `--concurrent-tasks 20`, no resource limits. Anca's 770 GB photo archive begins streaming from NFS to immich-server. |
| **2026-05-25 01:21** | Job marks `Complete` (85 min runtime). 34k photos uploaded. Immich-server ML pipeline (face detection / thumbnail generation) keeps the IO load going for hours after. |
| **05:02** | `daily-backup.service` (systemd timer) starts. It runs LVM thin-snapshot → LUKS-decrypt → mount → rsync per PVC. The competing IO from the still-saturated thin pool stretches every per-PVC step. |
| **08:24** | `daily-backup` `matrix-data-proxmox` rsync hits its per-PVC 30-min timeout — first warning. |
| **08:31–09:02** | 30 LUKS-encrypted PVC mounts log `Failed to mount snapshot` because ext4 orphan-inode cleanup exceeds the 30s `timeout 30 mount` guard (one volume took 109s). |
| **09:02:28** | systemd kills `daily-backup` with `TimeoutStartSec=14400` (4h). Script was nowhere near complete — alphabetically still on letter 'm'. Snapshots from today's run are left, but that's the *designed* 7-day retention pattern. |
| **09:07** | `nfs-mirror.service` also times out. |
| **09:33:24** | k8s-node1 VM **rebooted** (cause: best-guess IO starvation triggered Proxmox watchdog or qemu IO timeout; not directly observable). All pods on node1 enter `Unknown`. |
| **09:33:36** | node1 kubelet posts Ready. Pods on node1 begin churn: calico-node, csi-node-driver, kured, alloy, loki-canary, nvidia stack all restart. proxmox-csi-plugin-node fails to re-register the `csi.proxmox.sinextra.dev` driver in CSINode. |
| **09:40** | User session impacted: `~/.zsh_history` left with 154-byte NUL padding from interrupted write. |
| **09:41** | Incident detected by user; `/cluster-health` invoked. Healthcheck reports 33 PASS / 3 WARN / 64 FAIL. |
| **09:50** | Force-deleted 47 Failed pods + 22 stuck Terminating + 6 zombie DS pods on node1. |
| **09:55** | 4 recovery sub-agents dispatched in parallel: csi-recovery, gpu-recovery, dns-monitoring-recovery, backup-recovery. |
| **~10:15** | proxmox CSI re-registered on node1 (csi-recovery). Multi-Attach errors clearing. Loki StatefulSet recovers to 1/1. Calico fully back to 5/5. |
| **~10:30** | daily-backup re-started manually (currently still running, ETA ~2h). |
| **(ongoing)** | nvidia stack recovery ongoing; 20 deployments still recovering. |

## Root Cause

### Direct (the trigger)
`anca-elements-import` Job in `stacks/immich/main.tf` runs `immich-go upload` with `--concurrent-tasks 20`, no CPU limit, and no IO throttling. Twenty parallel NFS readers against `/srv/nfs/anca-elements` (mounted from PVE host) plus immich-server's ML pipeline (CUDA-accelerated face detection + thumbnail generation) saturated the read queue on sdc. The job itself only ran for 85 min, but the after-effects (ML processing, filesystem cache eviction, dirty-page writeback) persisted for hours.

### Recovery-side cascade (why the cluster stayed broken after node1 booted)
Once node1 rebooted, the kubelet posted Ready within 12s — but `csi.proxmox.sinextra.dev` failed to re-register, blocking ~30 pods. The actual cascade (discovered by the csi-recovery agent during today's investigation):

1. **Calico CNI on node1 entered a crash loop.** The `calico-node` pod's BIRD BGP daemon takes a few seconds to create `/var/run/bird/bird.ctl` on startup. The container's liveness probe was killing the process before the socket appeared, restarting it before it could stabilize.
2. **Without functional Calico, no new pod on node1 could reach the kube-apiserver service IP** (`10.96.0.1:443`).
3. **The proxmox-csi-plugin-node pod therefore crash-looped** with "no route to host" trying to talk to the apiserver, and **never created its CSI socket** for kubelet to discover.
4. **node-driver-registrar (sidecar) therefore never registered the driver with kubelet**, so CSINode for k8s-node1 lacked `csi.proxmox.sinextra.dev`.
5. **Every PVC mount on node1 failed** with the `driver not found` error we observed; meanwhile, **VolumeAttachments for those PVCs still pointed at node1** from before the reboot, so reschedule onto healthy nodes hit `Multi-Attach error`.

Fix order matters: **Calico first, then CSI, then stale VolumeAttachments**. Doing them out of order leaves the cascade broken. This is now a P3 runbook (below).

### Second cascade (3.5h into recovery) — Proxmox CSI 30-LUN-per-VM hard cap

During the recovery, a second cascade was discovered that compounded the outage:

1. **k8s-driver-manager init container cordons + drains node1** as part of GPU driver re-install. This evicted GPU-tagged pods (and incidentally triggered descheduler rebalancing) onto other nodes.
2. **Simultaneously the dns-monitoring-recovery agent killed an orphaned containerd holding a boltdb lock on k8s-node4**, evicting all node4 pods.
3. **The combined eviction wave scheduled ~60 PVC-using pods through the scheduler in a short window.** Many landed on node1 (largest node, least cordoned-ish), pushing its SCSI LUN slot count from ~17 (pre-Immich-import baseline) to **29 of 30 in use**.
4. **proxmox-csi-plugin's hard-coded `MaxVolumesPerNode = 30`** (per the upstream `csi-driver-proxmox` source: it scans scsi0…scsi30 and errors `no free lun found` when none are free) blocked further attaches.
5. **vault-0, mysql-standalone-0, claude-memory, grafana, nextcloud** etc. all could not start because their PVCs couldn't attach to node1 (their scheduled target). Multi-Attach errors compounded when their previous-node attachments hadn't been released cleanly.
6. **Daily-backup was running concurrently** — adding ~120 MB/s read load on sdc, slowing every CSI attach/detach operation by 3-5×, prolonging the queue.

**Resolution (manual, 2026-05-25):** `systemctl stop daily-backup`, `kubectl cordon k8s-node1`, force-delete stuck Pending pods. They rescheduled to nodes with LUN headroom (node2/3/4 had ~12-15 free slots each).

### Structural (why it took down a node)
1. **Single shared IO domain**: sdc is one LVM thin pool serving all 9 VMs. No Proxmox-level `bwlimit` or `iothrottle` between VMs. Any VM can starve the others.
2. **No IO budget at workload level**: the K8s job had `resources: {}`. There is no cluster-wide cgroup-IO budget enforced.
3. **NFS reads bypass per-VM accounting**: anca-elements is read via the PVE host's NFS export. The reads happen *on the PVE host*, charged to the host's IO scheduler, not to the k8s-node1 VM. So even if we capped node1's VM IO, the storm would still happen.
4. **node1 is also the only GPU node** — Immich-ML pods are pinned there. The reader (immich-server) and consumer (immich-ml) are both fighting for the same node's resources during ingestion.
5. **ext4 orphan-inode cleanup is unaware of `noload`**: `daily-backup.sh` uses `mount -o ro,noload` to skip journal replay, but `noload` doesn't skip orphan-inode cleanup. When a node reboots with dirty filesystem state on the source PVC, snapshot mounts can take 100+s — exceeding the script's 30s timeout. Confirmed by `dmesg`: 20+ volumes logged `INFO: recovery required on readonly filesystem` during today's backup window.
6. **Calico BIRD liveness probe is racy on cold start.** The probe doesn't tolerate the 3-5s BIRD initialization window, so any cold-start of Calico tends to crash-loop briefly. Usually it self-recovers on the 2nd or 3rd restart — today it didn't, because the apiserver was unreachable from the brand-new pod (chicken-and-egg).

## Contributing Factors

1. **The job's IO profile was never measured before running**. `immich-go --concurrent-tasks 20` is the upstream default; nobody validated it against our hardware.
2. **No staging window**. anca-elements-import is the second of two intentional one-shot ingestion runs (1st was Viktor's library months ago). The first run also caused load — but didn't crash a node, so it was treated as "loud but fine."
3. **Daily-backup overlap**. The 05:00 backup timer fired while the IO tail of the Immich job was still in flight. The two competing workloads triggered the LUKS mount timeouts.
4. **No PVE-level IO QoS** between VMs (Proxmox supports `iops_rd/wr` throttle groups on disk specs; we've never set them).
5. **No alert for "node1 about to crash"**. `NodeHighIOWait` fires at a fixed threshold but doesn't trigger any automated mitigation or paging.

## Detection Gaps

| Gap | Impact | Fix |
|-----|--------|-----|
| No PVE host IO PSI scraped into Prometheus | We can see node1 IO PSI but not the PVE-host-level pressure that's the actual leading indicator | Add node_exporter PSI scrape on PVE (already running) to Prometheus targets, expose `pressure_io_*` |
| No alert on sustained sdc utilization > 80% | The IO storm built up for hours without any signal escalating | Add `PVEThinPoolIOSaturated` rule: `irate(node_disk_io_time_seconds_total{device="sdc",instance="pve"}[5m]) > 0.85 for 30m` |
| No alert on Proxmox-host loadavg > 20 | Sustained loadavg 13–15 was visible only through cluster healthcheck #44 | Add `PVEHostLoadHigh` rule (1m loadavg > 25 for 10m) |
| No alert on K8s Job IO throughput | An uncapped K8s job can do unlimited IO without alerting | Add `JobHighIOThroughput`: alert if container_fs_reads_bytes_total rate over 5m > 100 MB/s for >10m |
| Backup timeout fires silently | systemd kill of daily-backup at 4h didn't alert anyone — we'd have noticed after 48h via the `backup_per_db=FAIL mysql=33h pg=33h` healthcheck | Add Alertmanager rule on daily-backup unit failure (probe systemd unit state via node-exporter textfile collector) |
| LUKS mount step inflation post-reboot is silent | 30 mount failures logged as WARN, no aggregate alert | Add count-of-WARN alert from the daily-backup log |

## Prevention Plan

### P0 — Prevent this exact failure

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P0 | Cap concurrency on future `*-elements-import` jobs | Config | In `stacks/immich/main.tf` (`kubernetes_job_v1.anca_elements_import` and future siblings): set `--concurrent-tasks 4` (down from 20). Also set `resources.limits.cpu = "2000m"` and `activeDeadlineSeconds = 21600` (6h cap). Add a `nodeSelector` to keep the job *off* node1 (move read-side onto a non-GPU node so the GPU node only does ML). | TODO |
| P0 | Bump LUKS mount timeout in `daily-backup` | Config | `infra/scripts/daily-backup.sh` line 243: change `timeout 30 mount …` → `timeout 180 mount …` (covers observed 109s worst case). Add a comment explaining the ext4 orphan-cleanup exception. | TODO |
| P0 | Schedule big-data ingests outside backup window | Config | Forbid Job/CronJob scheduling between 04:30–08:30 EEST (when daily-backup runs). Either via a Kyverno policy on `*-import` named jobs, or a documented convention enforced at PR review. | TODO |
| P0 | **Raise Proxmox CSI LUN limit on each k8s-node VM** | Architecture | The default `virtio-scsi-pci` controller exposes 30 LUN slots; proxmox-csi hard-caps at this. **Resolution path**: add a 2nd `virtio-scsi-pci` controller (`scsihw1`) to each k8s-node VM via Proxmox, OR migrate VMs to `virtio-scsi-single` which allows 256+ LUNs per disk. Either requires a brief per-node reboot. Without this, every future cluster-churn event can re-hit "no free lun found" on whichever node ends up overloaded. **Permanent fix — must land before next ingest run.** | TODO |
| P0 | Document the `MaxVolumesPerNode=30` limit in storage architecture | Runbook | Add to `docs/architecture/storage.md` — currently the 30-LUN cap is invisible to operators until they hit it. Include `kubectl get pods -A --field-selector spec.nodeName=NODE` and the 30-cap as a sizing check before any cluster-wide rebalance / drain operation. | TODO |
| P0 | Add startupProbe to mysql-standalone | Config | `stacks/dbaas/modules/dbaas/main.tf` (the `kubernetes_stateful_set_v1` for `mysql-standalone`): add `startupProbe` with `failureThreshold=120, periodSeconds=15, timeoutSeconds=10` (≈30 min budget for InnoDB recovery). Also bump liveness `initialDelaySeconds=120, failureThreshold=10`. Today MySQL spun in a CrashLoopBackOff for ~30 min — each restart's InnoDB recovery aborted when the existing 30s liveness probe fired, never finishing. Resolved manually via `kubectl patch sts mysql-standalone` — must Terraform-codify. | Done (kubectl, needs TF) |
| P0 | Add startupProbe to goauthentik-server | Config | Similar issue: Authentik Django migrations + clip/face index rebuilds take 5-10 min after PG restart, but the startup probe budget is too short → restart loop. Add `startupProbe: failureThreshold=180, periodSeconds=10` (30 min) on `goauthentik-server`. Source: `stacks/authentik/modules/authentik/main.tf` (or equivalent Helm values). | TODO |
| P0 | Disable daily-backup.timer when manually stopping daily-backup.service | Runbook | During this incident, `systemctl stop daily-backup.service` alone wasn't enough — the timer kept it queued for re-fire. The recovery sequence is: `systemctl stop daily-backup.timer; systemctl stop daily-backup.service`. Document in `docs/runbooks/cluster-recovery.md` (to-create) as the canonical sequence. | TODO |

### P1 — Reduce blast radius

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P1 | Proxmox per-VM IO throttle for the Immich workload host | Architecture | Set `iops_rd=2000,iops_wr=1000,mbps_rd=200,mbps_wr=100` on the k8s-node1 VM disk via Proxmox API. Pick numbers based on baseline `iostat` measurement. Same for non-prod VMs (devvm, registry). | TODO |
| P1 | Move NFS reads off the PVE host hot path | Architecture | Currently the PVE host *itself* reads `/srv/nfs/anca-elements` when an NFS client mounts that path — but the *reads* happen on PVE because it's the NFS server. Consider mounting anca-elements via a dedicated NFS export with a `wsize/rsize` cap, OR put bulk-ingest source data on a separate physical disk (sdb SSD has headroom). | Investigation |
| P1 | Add cgroup IOLimit to Kyverno mutating webhook for namespaces | Config | Auto-attach a `cgroupv2 io.max` annotation to pods in known-high-IO namespaces (immich, frigate, ollama). Requires kernel ≥5.13 + cgroupv2 (we have both). | TODO |
| P1 | Separate Immich `library` + `upload` NFS exports onto different LVs | Architecture | Currently `/srv/nfs/immich/{library,upload}` share the `pve/nfs-data` LV. Splitting upload onto its own thinly-provisioned LV would let us throttle upload-side independently. Cost: ~30 min PV churn. | Architecture |

### P2 — Detect faster

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P2 | Alert on sustained PVE sdc utilization | Alert | New PrometheusRule `PVEThinPoolIOSaturated`: `irate(node_disk_io_time_seconds_total{device="sdc",instance=~"pve.*"}[5m]) > 0.85` for 30m, severity=warning. | TODO |
| P2 | Alert on PVE loadavg high | Alert | New PrometheusRule `PVEHostLoadHigh`: `node_load1{instance=~"pve.*"} > 25` for 10m. severity=warning. | TODO |
| P2 | Alert on Kubernetes Job high IO rate | Alert | `JobHighIOThroughput`: `sum by (namespace, pod) (irate(container_fs_reads_bytes_total{container!=""}[5m])) > 100*1024*1024` for 10m → warning. | TODO |
| P2 | Alert on daily-backup systemd unit failure | Alert | Add node-exporter textfile collector entry that runs `systemctl is-failed daily-backup.service` every 1m and writes 0/1 to `/var/lib/node_exporter/textfile/backup_unit_state.prom`. PrometheusRule fires on value=1 for 5m. | TODO |
| P2 | Alert on Multi-Attach VolumeAttachment hung > 5m | Alert | These are the smoking gun whenever a node reboots. New rule on `kube_volumeattachment_status_attached == 0 and time() - kube_volumeattachment_metadata_created > 300`. | TODO |

### P3 — Improve resilience

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P3 | Move k8s-node1 OS disk off sdc | Architecture | If node1 OS disk lived on the SSD (sdb VG `ssd`, 475 GB free), an sdc IO storm wouldn't starve the VM's own root filesystem and we'd avoid the reboot trigger. Cost: VM migration, ~1h downtime for node1. | Architecture |
| P3 | Spread GPU + pinned services off node1 | Architecture | Today node1 carries the GPU + Loki + Technitium primary + claude-agent + many app deployments. When it goes down, the blast radius is huge. Re-evaluate pin constraints — only Immich-ML and Frigate genuinely need node1. | Investigation |
| P3 | Document recovery runbook for "node1 hard reboot" | Runbook | New `docs/runbooks/node1-reboot-recovery.md` capturing the **strict order** discovered today: (1) force-cleanup Failed/Unknown/stuck-Terminating zombies, (2) force-delete the calico-node pod on the rebooted node so BIRD restarts cleanly, (3) wait for calico-node Ready, (4) force-delete the proxmox-csi-plugin-node pod, (5) verify `csi.proxmox.sinextra.dev` appears in `kubectl get csinode <node> -o yaml`, (6) delete stale VolumeAttachments referencing the rebooted node where consumers have already rescheduled, (7) verify nvidia driver recovery (separate cascade). | TODO |
| P3 | Make Calico BIRD liveness probe cold-start tolerant | Config | Bump `initialDelaySeconds` on `calico-node`'s liveness probe by 15s, or switch to an `exec` probe that checks BIRD socket existence rather than HTTP. Prevents the cold-start crash loop after node reboots. | Investigation |
| P3 | Pre-flight script for bulk ingest jobs | Runbook + Config | Wrapper around `immich-go` that (a) checks PVE loadavg < 10, (b) checks sdc IO util < 50%, (c) checks daily-backup not running, before allowing the job to start. Refuses otherwise. | TODO |

## Lessons Learned

1. **One shared physical disk is one shared failure domain**. sdc serves all VMs; any uncapped workload can take down the cluster. We've now hit this three times in 17 days. Continuing to treat each as a one-off is no longer credible — we need IO budget enforcement (P1), not just better alerting (P2).
2. **NFS reads bypass per-VM accounting**. We assumed throttling the workload's VM would protect us. It doesn't — the reads physically happen on the PVE host's IO scheduler.
3. **The "complete" state of a Job doesn't mean its IO is gone**. anca-elements-import finished in 85 min, but the IO tail (ML pipeline + filesystem cache eviction) ran for hours. Future ingest jobs need to either run during off-hours OR be sized so that even their tail is benign.
4. **Backup pipeline depends on a clean cluster state**. When node1 was unhealthy, daily-backup couldn't complete LUKS mounts in time. Backups should be more resilient to upstream IO degradation OR we should treat backup failure as a SEV signal in real time.
5. **The 30s `timeout` in `daily-backup.sh` was set without considering post-reboot recovery time**. Defaults like this need to be reviewed in light of actual observed worst case.
6. **Recovery requires a known runbook**. Today's recovery worked because we knew which order to do things: force-delete zombies → re-register CSI → clear VAs → wait for daemonsets → restart deployments. Codifying that as a runbook means the next incident is 5x faster.

## Update 2026-06-01 — recurrence (Immich Duplicate Detection)

**5th IO-pressure incident.** A user-triggered library-wide **Duplicate Detection** run on the 163,989-asset Immich library cascaded into ML/thumbnail backfill for the ~5,150 assets missing CLIP embeddings (largely a fresh `anca-elements` import that had completed ~90 min earlier). The Immich **server-side** job `thumbnailGeneration` was set to concurrency **8** (plus `metadataExtraction=4`, `library=4`), so the backfill read originals off sdc 8-wide → ~92 MB/s, queue depth ~99, sdc ~100% util. 64 `nfsd` threads went D-state on `folio_wait_bit_common`; **etcd on k8s-master was starved → kube-apiserver down ~30 min** (different blast radius from 2026-05-25's node1 reboot — same root cause: the shared sdc spindle).

**New finding:** the 2026-05-25 P0 capped only the *import-side* concurrency (`immich-go --concurrent-tasks`). The Immich **server-side** job concurrency (`job.*.concurrency` in DB system-config) was never capped and had been tuned for speed (8/4/4). So **any** library-wide operation (dedup, smart-search backfill, thumbnail regen) re-triggers the storm independent of the import job.

**Mitigation applied (2026-06-01):** capped the HDD-original-reading server jobs to `thumbnailGeneration=2, metadataExtraction=2, library=2` in `system_metadata` `system-config` JSONB + `immich-server` recreate. Verified: dedup resumed with sdc at 2–3% util, queue depth ~0.05, apiserver healthy. Documented in `infra/.claude/CLAUDE.md` Immich row.

**Still the real fix (from this PM, still TODO):** the P0 import-side cap, and especially the **IO-isolation** items — move k8s-master **etcd** + node OS disks off sdc onto SSD (generalize P3), and/or give the Immich library its own spindle (P1). Concurrency caps are a band-aid; sdc remains a single shared failure domain that every storm finds. Tracked in beads (see Follow-up Implementation).

## Related

- 2026-05-09 IO post-mortem: `docs/post-mortems/2026-05-09-io-pressure-stale-nfs.md`
- 2026-05-16 kured/anubis post-mortem: `docs/post-mortems/2026-05-16-kured-stalled-and-anubis-ha.md`
- 2026-05-17 GPU driver post-mortem: `docs/post-mortems/2026-05-17-gpu-driver-ubuntu2604-mismatch.md`
- Storage architecture: `docs/architecture/storage.md`
- Backup pipeline: `docs/architecture/backup-dr.md`
- Storage hardware mapping: memory `id=464` (sdc thin pool, sda backup, sdb SSD)
- 3-2-1 backup strategy: memory `id=609`
- Immich storage layout: memory `id=674`
- Memory entries for this incident: 2682-2686 (Immich storm), 2687-2692 (LUKS mount timing)

## Follow-up Implementation

_This section is auto-populated by the postmortem-todo-resolver agent._

| Date | Action | Priority | Type | Commit | Implemented By |
|------|--------|----------|------|--------|----------------|
