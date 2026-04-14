# Post-Mortem: NFS fsid=0 Cascade — DNS + Vault + Multi-Service Outage

| Field | Value |
|-------|-------|
| **Date** | 2026-04-14 |
| **Duration** | ~5h (NFS broken for k8s: 05:37–10:40 EEST). Stale mounts persisted after fix until pod restarts. |
| **Severity** | SEV1 |
| **Affected Services** | 25+ pods across 15+ namespaces. DNS (primary), Vault (2/3 pods), Alertmanager, Grafana, ebooks, phpipam, poison-fountain, email monitoring, status page, backup CronJobs |
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
| Fix `lockd configuration failure` on PVE NFS server | TODO | Check `nfs-common` package, `/etc/nfs.conf` lockd settings |
| Force-unmount hung TrueNAS NFS mounts on PVE (`umount -f -l /mnt/truenas-src /mnt/truenas-ssd`) | TODO | TrueNAS is sunset; remove mounts entirely |
| Manage `/etc/exports` in git (add to `infra/scripts/` and deploy via PVE provisioning) | TODO | Prevents untracked config drift |
| Add NFS CSI mount options `nfsvers=3,nolock` to `nfs-proxmox` StorageClass | TODO | Prevents NFSv4 pseudo-root issues + lockd dependency |

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
| Add PrometheusRule: Pods in ContainerCreating > 10 minutes | TODO | Catches CSI mount failures |
| Add Uptime Kuma monitor: TrueNAS ping (10.0.10.15) | TODO | Catches TrueNAS outage early |
| Add Uptime Kuma monitor: PVE NFS port 2049 TCP check | TODO | Catches NFS service failures |
| Verify Grafana Uptime Kuma alert actually fires | TODO | Was down 37h unnoticed |

### P3 — Improve NFS resilience

| Action | Owner | Status |
|--------|-------|--------|
| Remove hung TrueNAS `hard` mounts from PVE fstab (TrueNAS is sunset) | TODO | Eliminates D-state kernel process risk |
| Add NFS export health check to daily-backup script | TODO | Backup script should verify NFS before starting |
| Document NFS CSI mount option requirements in CLAUDE.md | TODO | Prevents future misconfigurations |

## Lessons Learned

1. **NFSv4 `fsid=0` is dangerous for CSI subdirectory mounts**: It changes path resolution semantics in non-obvious ways. Never use it on exports that serve dynamic subdirectory mounts.

2. **Critical monitoring infrastructure must not depend on the thing it monitors**: Alertmanager on NFS cannot alert about NFS failures. This is the same anti-pattern as "DNS depends on DNS" or "monitoring depends on the monitored database".

3. **Stale NFS mounts have delayed-action failure modes**: The 3-day gap between the config change (Apr 11) and the outage (Apr 14) made root cause analysis much harder. Cached file handles mask configuration errors.

4. **`/etc/exports` is a single-point-of-configuration**: Unmanaged, unversioned, no review process. A single flag caused a cluster-wide outage.

5. **This is the SECOND DNS outage related to NFS migration** (first was Apr 6 — unbound PVC). Storage migrations for DNS infrastructure need extra scrutiny and pre-migration testing.
