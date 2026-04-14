# Post-Mortem: NFS fsid=0 Cascade — DNS + Vault + Multi-Service Outage

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Duration** | ~5h initial (05:37–10:40 EEST), then ~2h secondary (NFS restart broke NFSv3 + DNS zone sync gap) |
| **Severity** | SEV1 |
| **Affected Services** | 48+ pods across 20+ namespaces. DNS (all instances), Vault, MySQL, Grafana, Uptime Kuma, ebooks, phpipam, immich, servarr, and more |
| **Status** | Complete |

## Summary

An `fsid=0` flag in the PVE host's `/etc/exports` caused all NFSv4 subdirectory mount paths from k8s to fail. Combined with a `lockd` configuration failure that broke NFSv3 fallback, this made ALL new NFS mounts impossible and ALL existing NFS mounts stale after the NFS server had been restarted on Apr 11. The failure cascaded into DNS (primary unreachable), Vault (lost Raft quorum), Alertmanager (monitoring blind), and 20+ other services.

## Impact

- **User-facing**: DNS intermittent failures for 192.168.1.x network users (primary down, secondary/tertiary covered ~66% of queries). Vault-dependent services unable to rotate secrets.
- **Blast radius**: 57,405 NFS error messages across 4 k8s nodes + PVE host. 53 NFS-backed PVs at risk.
- **Duration**: ~5h of active NFS failure. Some services (ebooks) were in CreateContainerError for 2d22h before detection.
- **Data loss**: None. NFS data remained intact on disk; only the NFS service was broken.
- **Monitoring gap**: Alertmanager itself was on NFS storage, so it couldn't alert about the NFS failure.

## Timeline (EEST)

| Time | Event |
|------|-------|
| **Apr 11 00:44:52** | NFS server restarts on PVE. Logs `exportfs: can't open /etc/exports for reading` and `nfsdctl: lockd configuration failure`. Server starts with broken export configuration. |
| **Apr 11 (later)** | `/etc/exports` recreated with `fsid=0` on `/srv/nfs` and `fsid=1` on `/srv/nfs-ssd`. Exports reloaded. Existing k8s NFS mounts continue working (cached file handles). |
| **Apr 13 23:52** | TrueNAS (10.0.10.15) goes completely unreachable. PVE host's hard NFS mounts to TrueNAS start blocking with D-state kernel process. |
| **Apr 14 05:04** | `daily-backup.service` starts on PVE. 25/88 LUKS PVC snapshots fail to mount. |
| **Apr 14 05:37** | **CASCADE BEGINS**: k8s-node1, node3, node4 simultaneously start reporting `nfs: server 192.168.1.127 not responding, timed out`. Existing cached file handles expire; new mount operations hit the fsid=0 + lockd issues. |
| **Apr 14 ~07:30** | DNS outage reported by users on 192.168.1.x network. Investigation begins. |
| **Apr 14 10:40** | **FIX**: `fsid=0` removed from `/etc/exports`, NFS server restarted. New mounts work. |
| **Apr 14 10:41** | Vault pods restarted — all 3 come up 2/2 Running. Raft quorum restored. |
| **Apr 14 10:42** | Technitium primary pod restarted with fresh NFS mount. DNS fully restored. |
| **Apr 14 10:44–11:04** | Technitium primary migrated from NFS to `proxmox-lvm-encrypted` PVC. Data restored (104.9M including all 11 zones). Terraform state reconciled. |

## Root Cause Chain

```
[1] fsid=0 in /etc/exports (introduced Apr 11)
 └─> NFSv4 treats /srv/nfs as pseudo-root
     └─> Subdirectory paths (/srv/nfs/technitium) resolve incorrectly → ENOENT
         ├─> [2] lockd configuration failure (since Apr 11)
         │    └─> NFSv3 fallback fails (statd not running, no 'nolock' in CSI mount options)
         │         └─> ALL new NFS mounts fail with "No such file or directory"
         └─> [3] Existing mounts go stale (cached file handles expire ~Apr 14 05:37)
              ├─> Technitium primary: I/O errors on /etc/dns → degraded DNS
              ├─> Vault 0+1: CreateContainerError → lost Raft quorum → Vault down
              ├─> Alertmanager: I/O errors → monitoring blind spot
              ├─> Grafana: CrashLoopBackOff (MySQL password rotation failed during Vault outage)
              ├─> ebooks: CreateContainerError (2d22h undetected)
              └─> 20+ CronJobs and services: Error/FailedMount
```

### Why fsid=0 was there

During the TrueNAS → Proxmox NFS migration on Apr 11, the NFS server was restarted. At startup, `/etc/exports` was missing/unreadable. When the exports file was recreated, `fsid=0` was included — likely copied from an NFSv4 example. This flag is only appropriate for dedicated NFSv4-only exports, not for NFS CSI dynamic provisioning which mounts subdirectories.

### Why the failure was delayed 3 days

Existing NFS mounts from before the Apr 11 restart continued working because:
- NFSv3 mounts cache file handles and don't re-negotiate protocol on every I/O
- The `soft,timeo=30` mount options return errors after timeout, but cached operations succeed
- Only when cached handles expired or new mounts were needed did the failure manifest

The trigger was likely the `daily-backup.service` at 05:04 on Apr 14, which accesses NFS exports and may have caused the NFS server to recycle state, invalidating cached handles cluster-wide.

## Contributing Factors

1. **TrueNAS unreachable since Apr 13 23:52**: PVE host has `hard` NFS mounts to TrueNAS that will retry forever. D-state kernel process stuck since Apr 13. This may have contributed to NFS thread contention on the PVE host.

2. **Alertmanager on NFS storage**: The very system meant to alert about storage failures was stored on the failing storage. Circular dependency.

3. **`/etc/exports` not managed by Terraform or git**: Changes to this critical configuration file are untracked, making it impossible to audit when `fsid=0` was introduced.

4. **No NFS-specific health alerts**: While CLAUDE.md mentions "NFS responsiveness" alerts, no alert fired during this 5+ hour outage. The Prometheus rule may not cover mount failures from the k8s node perspective.

5. **CSI mount options lack `nfsvers=3` and `nolock`**: The NFS CSI driver uses default mount options that rely on version auto-negotiation. When NFSv4 fails (fsid=0) and NFSv3 fails (lockd), there's no fallback path.

## Detection Gaps

| Gap | Impact | Fix |
|-----|--------|-----|
| No alert on NFS mount failures from k8s nodes | 5h to detection | Add PrometheusRule: `node_nfs_requests_total` error rate |
| Alertmanager on NFS storage | Alerting blind during NFS outage | Move Alertmanager to `proxmox-lvm-encrypted` |
| `/etc/exports` not in git/Terraform | Can't audit config changes | Manage via Ansible or TF `remote-exec` |
| No TrueNAS reachability alert | 11h unnoticed before cascade | Add ping/ICMP monitor in Uptime Kuma |
| No CSI mount failure alert | Pods stuck for days unnoticed | Alert on `kube_pod_container_status_waiting_reason{reason="ContainerCreating"}` > 10m |
| ebooks pods broken for 2d22h | Zero notification | Above alert covers this |
| Grafana down 37h | Dashboard monitoring blind | Uptime Kuma HTTP check already exists; verify it alerts |

## Prevention Plan

### P0 — Prevent this exact failure from recurring

| Action | Owner | Status |
|--------|-------|--------|
| Remove `fsid=0` from `/etc/exports` on PVE host | Done | Completed Apr 14 |
| Fix `lockd configuration failure` on PVE NFS server | Done | Disabled NFSv3 entirely (`vers3=n`). lockd is an nfsdctl bug on kernel 6.14 — not fixable without Proxmox patch. |
| Force-unmount hung TrueNAS NFS mounts on PVE | Done | `umount -l /mnt/truenas-src /mnt/truenas-ssd`. Not in fstab — won't recur. |
| Manage `/etc/exports` in git (add to `infra/scripts/` and deploy via PVE provisioning) | TODO | Prevents untracked config drift |
| Migrate all NFS PVs to NFSv4 | Done | Patched 52 PVs to `nfsvers=4`. Updated TF module + StorageClass. Applied all 20 stacks. |
| Add DNS zone sync CronJob | Done | `technitium-zone-sync` runs every 30min, replicates all primary zones to secondary/tertiary via AXFR |

### P1 — Eliminate the NFS single point of failure for critical services

| Action | Owner | Status |
|--------|-------|--------|
| Migrate Technitium primary to `proxmox-lvm-encrypted` | Done | Completed Apr 14 |
| Migrate Alertmanager PV from NFS to `proxmox-lvm-encrypted` | TODO | Prevents circular alerting dependency |
| Migrate Vault PVCs from `nfs-proxmox` to `proxmox-lvm-encrypted` | TODO | Vault is too critical for NFS dependency |
| Review all 53 NFS PVs — identify which are critical-path and migrate | TODO | Reduce NFS blast radius |

### P2 — Detect NFS failures before users notice

| Action | Owner | Status |
|--------|-------|--------|
| Add PrometheusRule: NFS mount errors from node kernel logs | TODO | `node_nfs_rpc_retransmissions_total` rate > threshold |
| Add PrometheusRule: Pods in ContainerCreating > 10 minutes | Done | `NFSMountFailures` + `NFSCSINodeDown` alerts added to Prometheus |
| Add Uptime Kuma monitor: TrueNAS ping (10.0.10.15) | TODO | Catches TrueNAS outage early |
| Add Uptime Kuma monitor: PVE NFS port 2049 TCP check | TODO | Catches NFS service failures |
| Verify Grafana Uptime Kuma alert actually fires | TODO | Was down 37h unnoticed |

### P3 — Improve NFS resilience

| Action | Owner | Status |
|--------|-------|--------|
| Remove hung TrueNAS `hard` mounts from PVE fstab (TrueNAS is sunset) | TODO | Eliminates D-state kernel process risk |
| Add NFS export health check to daily-backup script | TODO | Backup script should verify NFS before starting |
| Document NFS CSI mount option requirements in CLAUDE.md | TODO | Prevents future misconfigurations |

## Phase 2: NFS Restart Broke NFSv3 + DNS Zone Sync Gap

### What happened after the 10:40 fix

The NFS server restart at 10:40 (which fixed the fsid=0 issue) introduced two new problems:

#### Problem 1: NFSv3 completely broken after restart

After the restart, **ALL NFSv3 mount(2) system calls returned EIO** from k8s worker nodes, even though:
- NFS port 2049 was reachable from all nodes
- `showmount -e` listed correct exports
- NFSv4 mounts worked perfectly from all nodes
- NFSv3 mounts worked from k8s-master (which had no prior NFS mounts — clean kernel state)

**Root cause**: `nfsdctl: lockd configuration failure` on PVE kernel 6.14.11-4-pve — a bug where nfsdctl's `autostart` command tries to call a non-existent `lockd` subcommand. This warning was present since Apr 11 but NFSv3 only broke after the restart. Worker nodes retained corrupted NFS client kernel state from the stale mount period that could not be cleared without a reboot.

**Resolution**: Patched all 52 NFS PVs to add `nfsvers=4` mount option via `kubectl patch pv`. Updated Terraform `nfs_volume` module and `nfs-csi` StorageClass. Disabled NFSv3 on PVE (`vers3=n` in `/etc/nfs.conf`). Applied to all 20+ Terraform stacks.

#### Problem 2: DNS zone sync gap — .lan resolution failures

**Finding**: Technitium secondary and tertiary instances had **only 5 default zones** (localhost, arpa). Custom zones (`viktorbarzin.lan`, `viktorbarzin.me`, reverse lookup zones, etc.) only existed on the primary. This was a **pre-existing gap** — the zone setup was a one-time Kubernetes Job that ran at initial deployment and never synced new zones created afterward.

**Impact**: The MetalLB VIP (10.0.20.201) load-balances across all 3 instances. 2/3 of queries hit secondary/tertiary → NXDOMAIN for `.lan` → cached for 300s by CoreDNS → ExternalName services (e.g., `ha-sofia.viktorbarzin.lan`) returned 502 Bad Gateway.

**Why it surfaced now**: The NFS outage restarted the primary Technitium pod, flushing client DNS caches. This increased the visible failure rate for `.lan` queries.

**Resolution**: 
1. Created `viktorbarzin.lan` and `viktorbarzin.me` as Secondary zones on both secondary and tertiary via Technitium API
2. **Converted one-time setup Job to a CronJob** (`technitium-zone-sync`) running every 30 minutes that:
   - Gets all zones from primary
   - Enables zone transfer (AXFR) on primary
   - Creates missing zones as Secondary type on replicas
   - Resyncs existing zones
3. 20 zones were synced to tertiary that were previously missing

### Phase 2 Timeline

| Time | Event |
|------|-------|
| **10:40** | NFS server restarted (fsid=0 fix). NFSv3 breaks. 48+ stale mounts across all workers. |
| **10:41–10:50** | Vault, DNS primary come back. But NFSv3 mounts stay stale. |
| **11:00–11:40** | Investigation: NFSv3 mount(2) returns EIO on workers, NFSv4 works. Patched 52 PVs to nfsvers=4. |
| **11:40–12:00** | Restarted all NFS-dependent pods. Fixed MySQL (Vault rotation mismatch), Redis HAProxy, Woodpecker DB. |
| **12:00–12:15** | Users report .lan resolution failures. Discovered secondary/tertiary missing all custom zones. |
| **12:15** | Created secondary zones on secondary/tertiary via API. .lan resolution restored. |
| **12:15–12:20** | Converted one-time setup Job to zone-sync CronJob. Applied via Terraform. |

### Additional collateral damage fixed during Phase 2

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Grafana, realestate-crawler, shlink MySQL access denied | Vault rotated passwords during NFS outage, credentials mismatched | Force-rotated Vault DB roles, manually synced Grafana password |
| Uptime Kuma `mysql_native_password` plugin not loaded | MySQL 8.4 disabled plugin by default | Enabled via `mysql-native-password=ON` in mycnf, changed user auth plugin |
| Redis HAProxy all backends DOWN | Health check timeout during cluster turbulence | Restarted HAProxy pods |
| Woodpecker missing PostgreSQL database | DB init Job ran at deploy, DB dropped during cluster recreation | Manually created database |
| Nextcloud PVC deleted | `nextcloud-data-proxmox` was Terminating and got garbage collected | Rebound Released PV to new PVC |
| MySQL InnoDB cluster OFFLINE | rollout restart invalidated operator state, kopf finalizer blocked deletion | Removed finalizer, recreated cluster via `dba.createCluster()` |

## Lessons Learned

1. **NFSv4 `fsid=0` is dangerous for CSI subdirectory mounts**: It changes path resolution semantics in non-obvious ways. Never use it on exports that serve dynamic subdirectory mounts.

2. **Critical monitoring infrastructure must not depend on the thing it monitors**: Alertmanager on NFS cannot alert about NFS failures. This is the same anti-pattern as "DNS depends on DNS" or "monitoring depends on the monitored database".

3. **Stale NFS mounts have delayed-action failure modes**: The 3-day gap between the config change (Apr 11) and the outage (Apr 14) made root cause analysis much harder. Cached file handles mask configuration errors.

4. **`/etc/exports` is a single-point-of-configuration**: Unmanaged, unversioned, no review process. A single flag caused a cluster-wide outage.

5. **This is the SECOND DNS outage related to NFS migration** (first was Apr 6 — unbound PVC). Storage migrations for DNS infrastructure need extra scrutiny and pre-migration testing.

6. **DNS HA requires zone replication, not just pod replication**: Having 3 Technitium pods with a PDB is useless if only the primary has the zone data. A one-time setup Job is insufficient — zones created after initial deployment are never synced. This is now fixed with a recurring CronJob.

7. **NFSv3 client kernel state survives mount cleanup**: Force-unmounting all NFS mounts from a node does NOT clear the kernel's per-server NFS client state. The only reliable fix was switching to NFSv4 (different protocol path). NFSv3 is now disabled on the PVE server.

8. **`kubectl rollout restart statefulset` is dangerous for operator-managed StatefulSets**: The MySQL InnoDB operator lost track of its cluster state after the rollout restart changed the pod template. Recovery required manually removing kopf finalizers, recreating the InnoDB cluster, and re-bootstrapping the router.
