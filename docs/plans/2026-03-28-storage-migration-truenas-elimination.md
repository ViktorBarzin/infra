# Storage Migration: TrueNAS Elimination via Proxmox CSI + Host NFS

**Date**: 2026-03-28
**Status**: Reviewed (3 rounds, all CRITICAL/IMPORTANT issues resolved)
**Goal**: Eliminate TrueNAS VM entirely, replacing it with Proxmox CSI (block storage for databases) and NFS served directly from the Proxmox host (for app data and backups). Recover 16 vCPU + 16 GB RAM, eliminate double-CoW ZFS corruption, simplify storage stack from 2 CSI drivers to 1 CSI driver + host NFS.

## Problem

The current storage architecture has a fundamental design flaw: TrueNAS runs as a VM with 7 thin-provisioned LVs forming a ZFS STRIPE (RAID0) on the same LVM-thin pool. This creates:

1. **Double Copy-on-Write**: ZFS CoW on top of LVM-thin CoW causes metadata contention under I/O pressure
2. **56 permanent ZFS checksum errors**: Corruption detected but unrecoverable (no ZFS redundancy)
3. **Single point of failure**: TrueNAS VM crash takes down all ~100 NFS shares + ~19 iSCSI targets
4. **Resource waste**: 16 vCPU + 16 GB RAM dedicated to a storage VM when the Proxmox host could serve storage directly
5. **Operational complexity**: Two CSI drivers (nfs-csi + democratic-csi), SSH keys, TrueNAS API, ZFS management

## Constraints

- Zero data loss tolerance — every migration step must have a rollback path
- Preserve the existing 3-layer backup strategy (local snapshots, app-level CronJob dumps, offsite sync to Synology)
- Preserve all Prometheus alerts and Grafana backup dashboard
- Stop-and-verify after each phase — no big-bang migration
- SCSI device limit: max 30 per VM (Proxmox VirtIO-SCSI controller). Must keep block PVs under this limit per node
- Minimize downtime per service (target: <5 min per service migration)
- All changes must be Terraform-managed

## Current State

### Hardware

All disks are **hardware RAID** arrays presented by the Dell PERC H730 Mini controller as single logical disks. No software RAID (mdadm) is involved. `pvcreate` operates directly on `/dev/sdX`.

| Disk | Size | RAID | Current Use | Current VG | Proposed Use |
|------|------|------|-------------|------------|--------------|
| sda (SAS 10K) | 1.1 TiB | HW RAID1 | **UNUSED** — no partitions, no VG | None | Host NFS (thick LV, ext4) |
| sdb (Samsung SSD) | 931 GiB | Single | 256G TrueNAS VM disk, 675G free | VG "ssd" (already exists) | Proxmox CSI SSD tier (thin pool in existing VG) |
| sdc (HDD 7200rpm) | 10.7 TiB | HW RAID1 | VG "pve" — all VMs + TrueNAS data | VG "pve" (already exists) | VM boots + Proxmox CSI HDD tier (existing thin pool "data") |

### ZFS Corruption Status

Before migrating data, verify which files are affected by the 56 ZFS checksum errors:
```bash
ssh root@10.0.10.15 'zpool status -v main | tail -20'
```
If critical user data (Immich photos, documents) is corrupted, restore those files from Synology backup BEFORE migration. Do not migrate known-corrupted data.

### Storage Usage

| Category | Current Backend | Size | PV Count |
|----------|----------------|------|----------|
| App data (NFS) | TrueNAS ZFS → NFS | ~1.39 TiB | ~45 |
| Database block (iSCSI) | TrueNAS ZFS → iSCSI | ~120 GiB | ~5 |
| Database block (StatefulSet) | TrueNAS ZFS → iSCSI (Helm VCT) | ~100 GiB | ~8 |
| Backup CronJob targets | TrueNAS ZFS → NFS | ~50 GiB | ~8 |
| No storage (stateless) | N/A | 0 | 0 |

### Services Requiring RWX (Shared Across Multiple Deployments)

Only 8 NFS paths are genuinely shared:

| NFS Path | Shared Between | Resolution |
|----------|---------------|------------|
| servarr/downloads | qbittorrent, lidarr, prowlarr, listenarr | Pin all to same node + subPath on single block PV, OR keep on host NFS |
| servarr/lidarr | lidarr + soulseek | Same — node affinity |
| servarr/qbittorrent | qbittorrent + readarr | Same — node affinity |
| audiobookshelf/audiobooks | audiobookshelf + qbittorrent | Same — node affinity |
| whisper (disabled) | whisper + piper | Disabled — migrate when re-enabled |
| audiblez (disabled) | audiblez + audiblez-web | Disabled — migrate when re-enabled |
| osm-routing (disabled) | osrm-foot + osrm-bicycle | Disabled — migrate when re-enabled |
| poison-fountain | 2 replicas of same Deployment | Scale to 1 or use StatefulSet |

**Decision**: All shared volumes stay on host NFS. No need to solve RWX with block storage — the SCSI budget is better spent on databases.

## Target Architecture

### Storage Tiers

```
Tier 1: proxmox-ssd (Proxmox CSI, block, RWO)
  Backend: LVM-thin pool on sdb (SSD)
  For: Databases requiring low-latency I/O
  Capacity: ~800 GiB
  Expected PVs: ~15 (across 5 nodes, ~3 per node)

Tier 2: proxmox-hdd (Proxmox CSI, block, RWO)
  Backend: Existing LVM-thin pool "data" on sdc (HDD)
  For: Large sequential I/O (Prometheus TSDB, Ollama models)
  Capacity: ~6 TiB free in existing pool
  Expected PVs: ~5 (across 5 nodes, ~1 per node)

Tier 3: nfs-host (NFS from Proxmox host, RWX/RWO)
  Backend: Thick LV on sda (SAS), ext4, exported via nfs-kernel-server
  For: App data, media, configs, backup targets, shared volumes
  Capacity: 1 TiB
  Expected PVs: ~35 (no SCSI limit — just directories)
```

### SCSI Budget

| Node | Boot Disk | CSI SSD PVs | CSI HDD PVs | Total | Limit |
|------|-----------|-------------|-------------|-------|-------|
| k8s-master | 1 | 1 (Vault) | 0 | 2 | 30 |
| k8s-node1 | 1 | 2 (CNPG replica, Redis replica) | 1 (Ollama) | 4 | 30 |
| k8s-node2 | 1 | 3 (CNPG primary, MySQL primary, Vaultwarden) | 1 (Prometheus) | 5 | 30 |
| k8s-node3 | 1 | 3 (MySQL replica, Redis master, Vault) | 0 | 4 | 30 |
| k8s-node4 | 1 | 3 (CNPG replica, MySQL replica, Vault) | 0 | 4 | 30 |

**Headroom**: 25+ free SCSI slots per node. Future growth is not a concern.

Note: Exact node assignments will be determined by K8s scheduler anti-affinity rules. The above is illustrative to demonstrate SCSI budget feasibility.

### Backup Architecture (3 Layers Preserved)

#### Layer 1: Local Snapshots

**Block PVs (Proxmox CSI)**: LVM-thin snapshots via cron on PVE host.

```bash
# /etc/cron.d/lvm-snapshots on Proxmox host
# Snapshot all CSI-provisioned thin LVs every 12h, retain 3 days
0 */12 * * * root /usr/local/bin/lvm-thin-snapshot.sh
```

Script logic:
1. Enumerate thin LVs matching `csi-*` naming pattern
2. `lvcreate -s -n <lv>-snap-$(date +%Y%m%d%H%M) <vg>/<lv>`
3. Prune snapshots older than 3 days: `lvremove -f <old-snaps>`
4. Push success/failure metric to Pushgateway

**NFS data (host ext4)**: The thick LV on sda cannot use LVM-thin snapshots. This is a **known RPO degradation**: current ZFS snapshots provide <1s RPO for NFS data, while the new architecture has 6h RPO (next offsite sync interval) for file-level recovery.

Mitigations:
- Databases have their own Layer 2 CronJob backups (daily/6h dumps) — no regression there
- App data (photos, documents, configs) relies on offsite sync every 6h + the Synology copy
- For critical files (Immich photos), the 6h RPO window is acceptable because Immich writes are append-only (new photos) — accidental deletion is the main risk, and that's caught within 6h
- If tighter RPO is needed later, convert sda from thick to thin provisioning to enable LVM-thin snapshots

#### Layer 2: Application-Level CronJob Backups (UNCHANGED)

All existing backup CronJobs continue as-is. The only change is the NFS server IP in `config.tfvars`:

```hcl
# Before
nfs_server = "10.0.10.15"  # TrueNAS VM

# After
nfs_server = "10.0.10.1"   # Proxmox host (existing mgmt VLAN IP)
```

Backup CronJobs write to `/srv/nfs/<service>-backup/` on the host, same as they wrote to `/mnt/main/<service>-backup/` on TrueNAS.

| Backup | Schedule | Retention | Change |
|--------|----------|-----------|--------|
| PostgreSQL (pg_dumpall) | Daily 00:00 | 14 days | NFS path only |
| MySQL (mysqldump) | Daily 00:30 | 14 days | NFS path only |
| etcd (etcdctl snapshot) | Weekly Sun 01:00 | 30 days | NFS path only |
| Vault (raft snapshot) | Weekly Sun 02:00 | 30 days | NFS path only |
| Redis (BGSAVE) | Weekly Sun 03:00 | 30 days | NFS path only |
| Vaultwarden (sqlite3 .backup) | Every 6h | 30 days | NFS path only |
| Prometheus (TSDB snapshot) | Monthly 1st Sun | 2 copies | NFS path only |
| Immich PG | Daily 00:00 | 14 days | NFS path only |

#### Layer 3: Offsite Sync (rclone to Synology NAS — SIMPLIFIED)

Replace TrueNAS Cloud Sync with a cron job on the Proxmox host:

```bash
# /etc/cron.d/offsite-sync on Proxmox host
# Incremental sync every 6h
0 */6 * * * root /usr/local/bin/offsite-sync.sh
# Full sync weekly Sunday 09:00
0 9 * * 0 root /usr/local/bin/offsite-sync.sh --full
```

Incremental sync uses `rsync` (or `rclone copy`) with `--files-from` based on `find -newer /srv/nfs/.last-sync`. Full sync uses `rclone sync`. Same Synology destination: `sftp://192.168.1.13/Backup/Viki/truenas`.

Same excludes as current: servarr/downloads, prometheus, loki, frigate recordings.

#### Monitoring (ALL PRESERVED)

| Alert | Current | New | Change |
|-------|---------|-----|--------|
| PostgreSQLBackupStale (36h) | Pushgateway | Pushgateway | None |
| MySQLBackupStale (36h) | Pushgateway | Pushgateway | None |
| EtcdBackupStale (8d) | Pushgateway | Pushgateway | None |
| VaultBackupStale (8d) | Pushgateway | Pushgateway | None |
| VaultwardenBackupStale (8d) | Pushgateway | Pushgateway | None |
| RedisBackupStale (8d) | Pushgateway | Pushgateway | None |
| PrometheusBackupStale (32d) | Pushgateway | Pushgateway | None |
| VaultwardenIntegrity | Pushgateway | Pushgateway | None |
| CloudSyncStale (8d) | TrueNAS metric | **OffsiteSyncStale** | Rename, source changes to PVE cron |
| CloudSyncFailing | TrueNAS metric | **OffsiteSyncFailing** | Rename, source changes to PVE cron |
| N/A | N/A | **LVMSnapshotStale** | NEW — alert if CSI LV snapshot cron fails |

Grafana backup dashboard: Update data source for offsite sync panels. All other panels unchanged.

## Migration Phases

### Phase 0: Preparation (No Downtime)

**Duration**: 2-4 hours

#### 0.0: Pre-flight Checks

1. **Verify sda is usable** (hardware RAID, no partitions):
   ```bash
   lsblk /dev/sda          # Should show no partitions
   cat /proc/mdstat         # Should show no mdadm arrays using sda
   smartctl -a /dev/sda     # Verify disk health
   ```

2. **Verify sdb VG exists and has free space**:
   ```bash
   vgs ssd                  # Should show VG "ssd" with ~675G free
   lvs ssd                  # Should show only vm-9000-disk-0 (256G)
   ```

3. **Verify Proxmox host IP on management VLAN**:
   ```bash
   ip addr show vmbr0       # Should show 10.0.10.1/24 or similar
   ```

4. **Verify NFS ports reachable from K8s VLAN** (pfSense routing):
   ```bash
   # From any k8s node:
   nc -zv 10.0.10.1 2049    # NFS
   nc -zv 10.0.10.1 111     # rpcbind
   ```
   If blocked, add pfSense rule: VLAN 20 (10.0.20.0/24) → VLAN 10, dst ports 111,2049, allow TCP/UDP.

5. **Resolve Pushgateway endpoint** for PVE host scripts (lvm-snapshot, offsite-sync):
   ```bash
   # Option A: Use Traefik ingress if Pushgateway has one
   curl -s http://pushgateway.viktorbarzin.me/metrics | head -1
   # Option B: Use NodePort
   kubectl get svc -n monitoring pushgateway -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}'
   # Option C: Use any K8s node IP + NodePort
   kubectl get svc -n monitoring pushgateway -o jsonpath='{.spec.ports[0].nodePort}'
   ```
   Update `PUSHGATEWAY=` in both scripts with the resolved endpoint. Verify with:
   ```bash
   echo "test_metric 1" | curl --data-binary @- http://<resolved>:9091/metrics/job/test
   ```

6. **Check ZFS corruption scope** (identify affected files before migration):
   ```bash
   ssh root@10.0.10.15 'zpool status -v main | tail -30'
   ```
   If critical data is in the error list, restore from Synology BEFORE proceeding.

#### 0.1: Create VG and LV on sda (Host NFS)

```bash
pvcreate /dev/sda
vgcreate sas /dev/sda
# Use nearly full capacity — sda is 1.1 TiB, reserve ~50G for VG metadata/overhead
lvcreate -L 1050G -n nfs-data sas
mkfs.ext4 -L nfs-data /dev/sas/nfs-data
mkdir -p /srv/nfs
echo '/dev/sas/nfs-data /srv/nfs ext4 defaults 0 2' >> /etc/fstab
mount /srv/nfs
```

**Capacity pre-validation** (MUST run before Phase 1):
```bash
# Check uncompressed data sizes on TrueNAS for largest consumers
ssh root@10.0.10.15 'zfs list -o name,used,refer,compressratio -r main | sort -k2 -h | tail -20'
```
If total uncompressed NFS data exceeds 1 TiB, keep Immich (~800 GiB, largest consumer) on a separate thin LV in the `pve` VG:
```bash
# Only if needed: create Immich-specific thin LV on HDD (auto-grows in thin pool)
lvcreate -V 1T --thinpool data -n immich-data pve
mkfs.ext4 /dev/pve/immich-data
mkdir /srv/nfs-immich
echo '/dev/pve/immich-data /srv/nfs-immich ext4 defaults 0 2' >> /etc/fstab
mount /srv/nfs-immich
# Add to /etc/exports: /srv/nfs-immich 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)
```

#### 0.2: Create LVM-thin Pool on sdb (SSD Tier)

VG "ssd" already exists on sdb. Create a thin pool in the free space:

```bash
# Verify free space in VG
vgdisplay ssd | grep Free

# Create thin pool with explicit metadata sizing (1% of data = 6G, allows thousands of snapshots)
lvcreate -L 600G --poolmetadatasize 6G --thinpool ssd-data ssd
```

Note: After TrueNAS shutdown frees the 256G disk in Phase 4, expand with `lvextend -L +200G /dev/ssd/ssd-data`.

#### 0.3: Register Proxmox Storage IDs

The Proxmox CSI plugin requires **Proxmox storage IDs** (configured in Datacenter → Storage), not raw LVM names. Register the SSD thin pool as a new storage:

```bash
# Register SSD thin pool in Proxmox storage config
pvesm add lvmthin ssd-csi --vgname ssd --thinpool ssd-data

# Verify it was added
pvesm status | grep ssd-csi

# Verify existing HDD storage ID (should already exist as "local-lvm")
pvesm status | grep local-lvm
```

The HDD tier uses the existing `local-lvm` Proxmox storage ID (already configured for VM boot disks).

#### 0.4: Install NFS Server on Proxmox Host

```bash
apt-get install -y nfs-kernel-server
```

Configure `/etc/exports`:
```
# Export entire /srv/nfs to K8s VLAN (10.0.20.0/24)
# root_squash is default — pods needing root writes must use initContainers to fix ownership
/srv/nfs 10.0.20.0/24(rw,sync,no_subtree_check,no_root_squash)
```

Note: `no_root_squash` is used because many services (LinuxServer.io containers, backup CronJobs) write as root. This matches the current TrueNAS NFS export behavior. Security impact is limited — only K8s nodes on VLAN 20 can access this export, and they're trusted.

```bash
exportfs -ra
systemctl enable --now nfs-kernel-server
# Verify from a k8s node:
# showmount -e 10.0.10.1
```

#### 0.5: Install Proxmox CSI Plugin

1. Create Proxmox API token with required roles:
   ```bash
   # On Proxmox host
   pveum user add csi@pve
   pveum aclmod / -user csi@pve -role PVEDatastoreUser,PVEVMAdmin,PVEAuditor
   pveum user token add csi@pve csi-token --privsep=0
   ```
   Store the token in Vault: `vault kv put secret/viktor/proxmox_csi_token token_id=csi@pve!csi-token token_secret=<secret>`

2. Deploy `proxmox-csi-plugin` Helm chart via new Terraform stack `stacks/proxmox-csi/`
   - Provisioner name: `csi.proxmox.sinextra.dev`
   - Configure cluster connection (Proxmox API URL, token)

3. Create StorageClasses (see Appendix B for full YAML):
   - `proxmox-ssd`: storage ID `ssd-csi`, `ssd: "true"`, `cache: none`
   - `proxmox-hdd`: storage ID `local-lvm`, `ssd: "false"`, `cache: writethrough`

4. Create VolumeSnapshotClass for LVM-thin snapshots

5. **Test on EVERY node** — create a test PVC, write data, read back, delete:
   ```bash
   for i in 1 2 3 4; do
     # Create PVC with nodeAffinity to k8s-node$i, verify SCSI hotplug works
     kubectl apply -f test-pvc-node$i.yaml
     # Verify: kubectl get pvc, kubectl describe pv
     # Clean up
     kubectl delete -f test-pvc-node$i.yaml
   done
   ```
   Also test on k8s-master. If SCSI hotplug fails on any node, investigate before proceeding.

6. **Test VolumeSnapshot**: Create a snapshot of the test PVC, restore to new PVC, verify data integrity. This validates the backup path BEFORE any production migration.

#### 0.6: Configure NFS for K8s

The existing NFS CSI driver (`nfs.csi.k8s.io`) supports multiple StorageClasses. Create a new StorageClass `nfs-host` pointing at the Proxmox host:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-host
provisioner: nfs.csi.k8s.io
parameters:
  server: 10.0.10.1        # Proxmox host on mgmt VLAN
  share: /srv/nfs
mountOptions:
  - soft
  - timeo=30
  - retrans=3
  - actimeo=5
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

Keep the old `nfs-truenas` StorageClass active during migration. Services are migrated one at a time by updating their PV/PVC to use the new server.

Note: For services using the `nfs_volume` Terraform module (static PV/PVC), the migration involves changing the `nfs_server` parameter in the module call, not switching StorageClasses. The new StorageClass is for any future dynamically provisioned NFS PVCs.

#### 0.7: Set Up LVM Snapshot Cron

Install `/usr/local/bin/lvm-thin-snapshot.sh` on Proxmox host:

```bash
#!/bin/bash
# Snapshot all CSI-provisioned thin LVs
set -euo pipefail
PUSHGATEWAY="http://PUSHGATEWAY_NODEPORT_IP:PORT"  # MUST resolve before Phase 0.7. Scripts run on PVE host (not in K8s), so use NodePort or Traefik ingress. Find with: kubectl get svc -n monitoring pushgateway -o wide
RETENTION_DAYS=3
STATUS=0

for vg in ssd pve; do
  # Get list of CSI LVs (names starting with "csi-", excluding existing snapshots)
  for lv in $(lvs --noheadings -o lv_name "$vg" 2>/dev/null | awk '/csi-/ && !/snap-/ {print $1}'); do
    snap_name="${lv}-snap-$(date +%Y%m%d%H%M)"
    # LVM-thin snapshots don't need -L (no pre-allocated CoW area — they share the thin pool)
    if lvcreate -s -n "$snap_name" "$vg/$lv" 2>&1; then
      echo "Created snapshot: $vg/$snap_name"
    else
      echo "FAILED to snapshot: $vg/$lv" >&2
      STATUS=1
    fi
  done
done

# Prune old snapshots (parse timestamp from snapshot name, not lv_time which is unreliable)
find_and_remove_old_snaps() {
  local vg="$1"
  local cutoff_epoch
  cutoff_epoch=$(date -d "-${RETENTION_DAYS} days" +%s)

  lvs --noheadings -o lv_name "$vg" 2>/dev/null | awk '/snap-/ {print $1}' | while read -r snap; do
    # Extract timestamp from name: ...-snap-YYYYMMDDHHMM
    timestamp=$(echo "$snap" | grep -oP 'snap-\K\d{12}' || echo "")
    if [[ -n "$timestamp" ]]; then
      snap_epoch=$(date -d "${timestamp:0:8} ${timestamp:8:2}:${timestamp:10:2}" +%s 2>/dev/null || echo "0")
      if [[ "$snap_epoch" -lt "$cutoff_epoch" && "$snap_epoch" -gt 0 ]]; then
        echo "Removing old snapshot: $vg/$snap"
        lvremove -f "$vg/$snap" || STATUS=1
      fi
    fi
  done
}
find_and_remove_old_snaps ssd
find_and_remove_old_snaps pve

# Push metrics
cat <<EOF | curl -s --data-binary @- "$PUSHGATEWAY/metrics/job/lvm-snapshots"
lvm_snapshot_last_success_timestamp $(date +%s)
lvm_snapshot_last_status $STATUS
EOF
```

Configure cron: `/etc/cron.d/lvm-snapshots`
```
0 */12 * * * root /usr/local/bin/lvm-thin-snapshot.sh >> /var/log/lvm-snapshots.log 2>&1
```

#### 0.8: Set Up Offsite Sync Cron

Install rclone and configure Synology remote:

```bash
apt-get install -y rclone
rclone config create synology sftp \
  host=192.168.1.13 \
  user=root \
  key_file=/root/.ssh/synology_key
```

Install `/usr/local/bin/offsite-sync.sh`:

```bash
#!/bin/bash
# Offsite sync to Synology NAS using rclone (consistent tooling for both modes)
set -euo pipefail
PUSHGATEWAY="http://10.0.20.X:9091"
SRC="/srv/nfs"
DST="synology:/Backup/Viki/truenas"
EXCLUDES="--exclude servarr/downloads/** --exclude prometheus/** --exclude loki/** --exclude frigate/recordings/**"
STATUS=0
BYTES=0

if [[ "${1:-}" == "--full" ]]; then
  # Full weekly sync — mirrors source to destination, removes orphans on dest
  rclone sync "$SRC" "$DST" $EXCLUDES --stats-one-line -v 2>&1 | tee /var/log/offsite-sync.log
  STATUS=$?
else
  # Incremental: copy changed files only (rclone checks mod time + size, no deletions)
  rclone copy "$SRC" "$DST" $EXCLUDES --stats-one-line -v 2>&1 | tee /var/log/offsite-sync.log
  STATUS=$?
fi

BYTES=$(du -sb "$SRC" 2>/dev/null | cut -f1)

cat <<EOF | curl -s --data-binary @- "$PUSHGATEWAY/metrics/job/offsite-sync"
offsite_sync_last_success_timestamp $(date +%s)
offsite_sync_last_status $STATUS
offsite_sync_source_bytes $BYTES
EOF
```

Configure cron: `/etc/cron.d/offsite-sync`
```
0 */6 * * * root /usr/local/bin/offsite-sync.sh >> /var/log/offsite-sync.log 2>&1
0 9 * * 0 root /usr/local/bin/offsite-sync.sh --full >> /var/log/offsite-sync.log 2>&1
```

Test with empty `/srv/nfs/` → Synology to verify connectivity.

#### 0.9: Add Prometheus Alerts

Add to monitoring stack:
- `LVMSnapshotStale`: no successful LVM snapshot push in **24h** (snapshots run every 12h — alerts after 2 missed cycles)
- `OffsiteSyncStale`: no successful offsite sync in 8d
- `OffsiteSyncFailing`: last sync exit code != 0

Update Grafana backup dashboard:
- Add "LVM Snapshot Age" panel (stat, source: `lvm_snapshot_last_success_timestamp`)
- Add "Offsite Sync Status" panel (stat, source: `offsite_sync_last_status`)
- Rename "Cloud Sync" panels to "Offsite Sync"

### Phase 1: Migrate NFS App Data (Low-Risk, Bulk)

**Duration**: 1-2 weekends
**Downtime per service**: <5 minutes
**Rollback**: Switch PV back to old NFS path

Migrate the ~35 single-pod NFS volumes from TrueNAS to host NFS. These are the lowest-risk migrations — single replica Deployments with non-critical data.

**For each service**:

1. Scale deployment to 0: `kubectl scale deploy/<name> -n <ns> --replicas=0`
2. Verify all pods terminated: `kubectl get pods -n <ns> -l app=<name>` (must show no Running pods — prevents race condition during rsync)
3. rsync data with checksum verification: `rsync -av --checksum --delete root@10.0.10.15:/mnt/main/<service>/ /srv/nfs/<service>/`
4. Verify: compare file counts and total size:
   ```bash
   ssh root@10.0.10.15 "find /mnt/main/<service> -type f | wc -l"
   find /srv/nfs/<service> -type f | wc -l
   ssh root@10.0.10.15 "du -sh /mnt/main/<service>"
   du -sh /srv/nfs/<service>
   ```
5. Update Terraform: Change `nfs_server` in `nfs_volume` module call to `10.0.10.1` and `nfs_path` from `/mnt/main/<service>` to `/srv/nfs/<service>`
6. `terragrunt apply` — updates PV to point at host NFS
7. Scale deployment to 1
8. Verify service is healthy (check logs, Uptime Kuma, service-specific smoke test)
9. Mark old TrueNAS directory as migrated (don't delete yet)

**Stacks requiring re-apply**: All stacks with `module.nfs_volume` calls. Identify with:
```bash
grep -rl 'module.*nfs_volume\|nfs_server' infra/stacks/*/main.tf | sort
```
Apply order: non-critical services first (waves 1-5), platform services last (wave 6).

**Capacity checkpoint after each wave**:
```bash
df -h /srv/nfs
# If >80% full, STOP and either:
# a. Extend the LV: lvextend -L +50G /dev/sas/nfs-data && resize2fs /dev/sas/nfs-data
# b. Move Immich to separate thin LV on HDD (see Phase 0.1 overflow plan)
```

**Migration order** (low-risk first):

| Wave | Services | Rationale |
|------|----------|-----------|
| 1 | privatebin, stirling-pdf, excalidraw, send, resume, jsoncrack | Stateless-ish, low data |
| 2 | ntfy, diun, owntracks, health, f1-stream | Small data, single pod |
| 3 | actualbudget (x3), isponsorblocktv, affine | Small data, low traffic |
| 4 | hackmd, paperless-ngx, matrix | Medium data, more important |
| 5 | meshcentral (3 vols), roundcubemail (2 vols) | Multi-volume services |
| 6 | ytdlp (2 vols), uptime-kuma, technitium (x2) | Platform services — extra care |
| 7 | servarr suite (all components) | Complex shared volumes, keep on NFS |
| 8 | Backup CronJob targets (postgresql-backup, mysql-backup, vault-backup, etc.) | Must verify backup CronJobs still work after |
| 9 | Immich (~800 GiB) | Largest dataset — use two-pass rsync to minimize downtime (see below) |

**Immich migration (Wave 9)** — two-pass rsync to minimize downtime:
1. **Pass 1** (Immich still running): `rsync -av --checksum root@10.0.10.15:/mnt/main/immich/ /srv/nfs/immich/` — bulk copy ~800 GiB while service is live (30-60 min, no downtime)
2. Scale Immich to 0
3. **Pass 2** (delta only): `rsync -av --checksum --delete root@10.0.10.15:/mnt/main/immich/ /srv/nfs/immich/` — syncs only changes since Pass 1 (1-5 min)
4. Update Terraform, apply, scale to 1
5. Verify: upload a test photo, check ML classification, browse thumbnails

**Disabled services** (whisper, audiblez, grampsweb, tandoor, etc.): Update Terraform to point at new NFS but don't rsync data (no data to migrate while disabled). rsync when re-enabled.

### Phase 2: Migrate Databases to Proxmox CSI SSD

**Duration**: 1 weekend
**Downtime per service**: 5-15 minutes
**Rollback**: CNPG switchover back to old primary; MySQL/Redis restore from dump

This is the highest-value migration — databases get local SSD instead of NFS-over-ZFS-over-LVM-thin.

**Migration Order** (dependency-aware):

| Day | Databases | Rationale |
|-----|-----------|-----------|
| Day 1 | 2a: CNPG PostgreSQL, 2b: MySQL, 2e: Vaultwarden | Independent of each other — can run in parallel |
| Day 2 | 2d: Redis | Authentik depends on both PG + Redis. Migrate Redis only AFTER verifying CNPG migration is stable |
| Day 3 | 2c: Vault | All services (ESO, Authentik, backup CronJobs) depend on Vault. Migrate LAST after all other DBs are verified stable |

**Terraform state handling**: Changing `storageClass` on PVCs requires recreation (immutable field). For each database migration:
1. The old PVCs will become orphaned (reclaimPolicy: Retain keeps the PV)
2. After verifying the new database is stable (24h), manually clean up:
   ```bash
   # Delete orphaned PVCs
   kubectl delete pvc <old-pvc-name> -n <namespace>
   # Delete orphaned PVs (verify they're in "Released" state first)
   kubectl get pv | grep Released
   kubectl delete pv <old-pv-name>
   ```
3. Old TrueNAS iSCSI zvols will be cleaned up in Phase 4

#### 2a: CNPG PostgreSQL

Use dump/restore approach (safer than cross-storage streaming replication, which can fail when the underlying filesystem changes):

1. Take fresh `pg_dumpall` from existing cluster (Layer 2 backup, plus an extra manual dump)
2. Verify the CNPG operand image includes all required extensions (pgvector, pgvecto-rs, etc.) — the current cluster uses `viktorbarzin/postgres:16-master` custom image. Build a compatible CNPG image or verify extensions are available.
3. Create new CNPG Cluster resource with `storageClass: proxmox-ssd` (fresh init)
4. Restore dump to new cluster: `cat dump.sql | kubectl exec -i <new-primary> -- psql -U postgres`
5. Update `postgresql_host` in `config.tfvars` to new cluster service (e.g., `pg-cluster-rw.dbaas.svc.cluster.local` — keep same name if possible to minimize changes)
6. `terragrunt apply` across all consuming stacks (12+ stacks — use `grep -rl postgresql_host stacks/` to enumerate)
7. Verify all services connect successfully:
   - Authentik: login via web UI
   - Woodpecker: trigger a test pipeline
   - Immich: upload a test photo
   - Grafana: load a dashboard
   - All others: check pod logs for DB connection errors
8. Decommission old CNPG cluster after 24h of verified operation

#### 2b: MySQL InnoDB Cluster

1. Take a fresh mysqldump of all databases (Layer 2 backup)
2. Create new MySQL InnoDB Cluster Helm release with `storageClass: proxmox-ssd`
3. Restore dump to new cluster
4. Update `mysql_host` in `config.tfvars`
5. `terragrunt apply` across consuming stacks
6. Verify all MySQL-backed services (speedtest, wrongmove, grafana, etc.)
7. Decommission old MySQL cluster

#### 2c: Vault Raft

**Pre-migration coordination** (before scaling Vault to 0):
1. Verify no Woodpecker pipelines are queued/running
2. Scale Woodpecker to 0 to prevent deploys during window
3. Verify no backup CronJobs are currently running: `kubectl get jobs -A | grep -v Completed`
4. Do NOT run `terragrunt apply` on any stack during the 10-15 min window

**WARNING**: Do NOT seal Vault during migration. Sealing breaks ESO (43+ ExternalSecrets), Authentik, and all backup CronJobs that read Vault. Instead, use a graceful shutdown + data copy approach.

1. Take Vault raft snapshot (Layer 2 backup + manual snapshot for safety)
2. Scale Vault StatefulSet to 0 (graceful shutdown — pods terminate cleanly, no seal needed)
3. Note: During this window (~10-15 min), ESO cannot refresh secrets. Existing K8s Secrets remain valid but won't be rotated. No pod restarts should be triggered. **Do NOT run `terragrunt apply` on any stack during this window.**
4. Create new Vault Helm release with `storageClass: proxmox-ssd`
5. Copy raft data from old PVCs to new PVCs (use a temporary pod or `kubectl cp` from the backup)
6. Start new Vault StatefulSet
7. Unseal all replicas, verify cluster health: `vault status`, `vault operator raft list-peers`
8. Verify all secrets accessible: `vault kv get secret/viktor`
9. Verify ESO connectivity: `kubectl get clustersecretstore vault-kv -o jsonpath='{.status.conditions}'`
10. Decommission old Vault StatefulSet PVCs after 24h verification

#### 2d: Redis

1. Trigger BGSAVE on current Redis
2. Scale Redis to 0
3. Create new Redis Helm release with `storageClass: proxmox-ssd`
4. Copy RDB dump to new PV
5. Start new Redis, verify data
6. Update `redis_host` in `config.tfvars` if changed
7. Decommission old Redis PVCs

#### 2e: Vaultwarden

1. Run sqlite3 `.backup` (Layer 2 backup)
2. Scale Vaultwarden to 0
3. Create new PVC with `storageClass: proxmox-ssd`
4. Copy SQLite database to new PV
5. Update Vaultwarden deployment to use new PVC
6. Scale to 1, verify via web UI + Bitwarden client sync
7. Verify backup CronJob still works with new PVC mount

### Phase 3: Migrate Large Stateful Workloads to Proxmox CSI HDD

**Duration**: 1 evening
**Downtime per service**: 10-30 minutes (Prometheus has large TSDB)

#### 3a: Prometheus

1. Create new PVC with `storageClass: proxmox-hdd`, size 200Gi
2. Scale Prometheus to 0
3. rsync TSDB data from old iSCSI PV to new block PV (may take 20-30 min for ~27GB)
4. Update Prometheus Helm values to use new StorageClass
5. Start Prometheus, verify metrics continuity
6. Decommission old iSCSI PVC

#### 3b: Ollama

1. Create new PVC with `storageClass: proxmox-hdd`
2. Scale Ollama to 0
3. rsync models from old NFS to new block PV
4. Update deployment
5. Verify model loading
6. Decommission old NFS volume

### Phase 4: TrueNAS Shutdown and Cleanup

**Duration**: 1 evening
**Prerequisites**: All services migrated and verified for at least 1 week with no issues

1. **Final verification**:
   - All services healthy (Uptime Kuma green)
   - All backup CronJobs running (Grafana dashboard green)
   - Offsite sync to Synology running (check Pushgateway metrics)
   - No pods mounting TrueNAS NFS or iSCSI

2. **Shutdown TrueNAS VM**:
   ```bash
   qm shutdown 9000
   ```

3. **Monitor for 1 week** (matches success criteria): Watch for any services that silently depended on TrueNAS. Check Uptime Kuma, Grafana backup dashboard, and Prometheus alerts daily.

4. **Reclaim resources** (only after 1-week verification — once LVs are removed, TrueNAS rollback is impossible):
   - Remove TrueNAS VM definition from Terraform
   - Remove the 7 thin LVs (scsi1-scsi7) that were TrueNAS ZFS vdevs — frees ~1.7 TiB in thin pool:
     ```bash
     # List TrueNAS LVs
     lvs pve | grep 'vm-9000'
     # Remove each one
     lvremove -f /dev/pve/vm-9000-disk-1
     # ... repeat for disk-2 through disk-7
     ```
   - Remove TrueNAS SSD disk (vm-9000-disk-0 on sdb) — frees 256 GiB on SSD VG:
     ```bash
     lvremove -f /dev/ssd/vm-9000-disk-0
     ```
   - Expand SSD thin pool with reclaimed space (safe to do online with active thin volumes). Extend both data and metadata proportionally:
     ```bash
     lvextend -L +200G /dev/ssd/ssd-data
     lvextend --poolmetadatasize +2G /dev/ssd/ssd-data  # Keep metadata at ~1% of data
     lvs ssd/ssd-data  # Verify new size
     ```

5. **Remove old CSI drivers**:
   - Remove `democratic-csi` (iSCSI) Helm release and Terraform stack
   - Remove old `nfs-truenas` StorageClass (keep `nfs-host`)
   - Remove TrueNAS SSH key from Vault
   - Remove TrueNAS API credentials from Vault

6. **Update documentation**:
   - Update `infra/docs/architecture/storage.md`
   - Update `infra/docs/architecture/backup-dr.md`
   - Update `infra/.claude/CLAUDE.md` storage sections
   - Update `AGENTS.md` if storage references exist

7. **Synology backup path**: Keep the existing path `truenas` on Synology — renaming would cause rclone to re-upload everything. The path name is cosmetic; the content is what matters. Add a note file at the root: `echo "Source: PVE host /srv/nfs (migrated from TrueNAS $(date))" > /srv/nfs/.source-info`

### Phase 5: Post-Migration Hardening

1. **LVM snapshot monitoring**: Verify Prometheus scrapes LVM snapshot metrics, Grafana panels show snapshot age and count
2. **Offsite sync monitoring**: Verify Prometheus alerts for OffsiteSyncStale/Failing
3. **Disaster recovery test**: Restore a database from backup to verify the full backup→restore path works end-to-end
4. **Capacity alerting**: Add alerts for:
   - SSD thin pool >80% full
   - HDD thin pool >80% full
   - NFS thick LV >85% full
5. **Update memory/CLAUDE.md**: Store the new architecture mapping
6. **Proxmox CSI VolumeSnapshot test**: Create a VolumeSnapshot of a database PV, restore it to a new PVC, verify data integrity

## Rollback Plan

Each phase is independently rollbackable:

| Phase | Rollback Procedure | Data Loss Risk |
|-------|-------------------|----------------|
| Phase 0 | Remove Proxmox CSI, NFS server, crons. No service impact | None |
| Phase 1 | Switch PV back to TrueNAS NFS path. rsync delta back | None (TrueNAS still has original data) |
| Phase 2 | CNPG switchover back; MySQL restore from dump; Vault restore from raft snapshot | Minimal (since last dump) |
| Phase 3 | Re-create iSCSI PVC, rsync back | None |
| Phase 4 | Boot TrueNAS VM, re-attach LVs (only possible before LV reclaim in step 4 — 1-week window) | N/A (only done after full verification) |

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Proxmox CSI plugin bug / incompatibility | Medium | High | Test extensively in Phase 0; keep TrueNAS alive until Phase 4 |
| SCSI hotplug fails on specific VM | Low | Medium | Test on each node in Phase 0; fallback to NFS for that node |
| NFS kernel server performance worse than TrueNAS | Low | Low | TrueNAS was double-CoW; host NFS on SAS 10K disk should be faster |
| Proxmox API token permissions insufficient | Low | Low | Test all CSI operations in Phase 0 before any migration |
| rclone offsite sync misses files without zfs diff | Low | Medium | Use rsync (checksums all files); accept slightly longer runtime |
| LVM thin pool fills during migration | Low | High | Monitor pool usage during Phase 1-3; current usage is 37% |
| Service depends on TrueNAS in unexpected way | Low | Medium | 48-hour monitoring period in Phase 4 before decommission |
| Proxmox host reboot disrupts NFS + block PVs simultaneously | Medium | High | This is same as current (TrueNAS VM is on same host). No regression. Schedule reboots during maintenance windows |
| CNPG custom image missing extensions after migration | Low | High | Verify extensions (pgvector, pgvecto-rs) in CNPG image before migration; build custom image if needed |
| NFS ports blocked by pfSense between VLANs | Medium | High | Test NFS connectivity from K8s nodes to PVE host in Phase 0.0 pre-flight |
| Corrupted ZFS data migrated to new storage | Low | High | Check `zpool status -v` before migration; restore corrupted files from Synology backup first |

## Success Criteria

- [ ] All services healthy on new storage for 1+ week
- [ ] All backup CronJobs green on Grafana dashboard
- [ ] Offsite sync to Synology running with metrics
- [ ] LVM snapshot cron running with metrics
- [ ] TrueNAS VM shut down and resources reclaimed
- [ ] No double-CoW — single LVM-thin CoW layer only
- [ ] 16 vCPU + 16 GB RAM freed for K8s workloads
- [ ] SCSI budget: ≤5 devices per node average, no single node exceeding 10
- [ ] DR test: successfully restore at least 1 database from backup on new infrastructure

## Appendix A: Proxmox Host NFS vs TrueNAS NFS

| Property | TrueNAS NFS | Host NFS |
|----------|-------------|----------|
| CoW layers | 2 (ZFS + LVM-thin) | 0 (thick LV, ext4) |
| Checksumming | ZFS (but can't repair — RAID0) | None (ext4) |
| Compression | lz4 (1.26×) | None |
| Network hop | VM NIC → bridge → physical | Direct on host |
| RAM overhead | 16 GB (ZFS ARC) | ~0 (kernel NFS is lightweight) |
| Management UI | TrueNAS WebUI | /etc/exports (text file) |
| Snapshot quality | ZFS (excellent but corrupted) | LVM thick — no snapshots (use backups) |
| Effective capacity | ~1.26× via lz4 compression (~800G for 1 TiB logical) | 1:1 (no compression). Allocate 1 TiB for ~1 TiB of data. Monitor usage; current NFS data is 1.39 TiB but largest consumers (Immich) may compress well on ZFS but not on ext4 |

**Note on capacity**: Losing ZFS lz4 compression (1.26×) means effective capacity drops. Current NFS data is 1.39 TiB compressed. Uncompressed, this could be ~1.75 TiB. The 1 TiB thick LV on sda may not be sufficient for all data. **Mitigation**: Monitor during Phase 1 migration. If approaching 85%, either (a) extend the LV (sda has 1.1 TiB total, 100G is reserved for VG metadata), or (b) keep large datasets (Immich ~800G) on a separate LV on sdc's thin pool.

## Appendix A.1: Superseded Plans

This plan **supersedes** the pending "iSCSI PV pin & rename migration" plan (`~/.claude/plans/ticklish-singing-donut.md`). That plan proposed renaming iSCSI PVs on TrueNAS — since TrueNAS is being eliminated entirely, the rename migration is no longer needed. All iSCSI PVs will be replaced with Proxmox CSI block PVs in Phase 2-3.

## Appendix B: Proxmox CSI StorageClass Definitions

**Important**: The `storage` parameter must reference a **Proxmox storage ID** (as configured in Datacenter → Storage in the Proxmox UI), NOT the raw LVM thin pool name. The SSD storage must be registered in Phase 0.3 before these StorageClasses will work.

```yaml
# proxmox-ssd StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: proxmox-ssd
provisioner: csi.proxmox.sinextra.dev
parameters:
  storage: ssd-csi    # Proxmox storage ID (registered in Phase 0.3, points to ssd/ssd-data thin pool)
  ssd: "true"
  cache: none          # Required for databases — ensures fsync reaches disk
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true

---
# proxmox-hdd StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: proxmox-hdd
provisioner: csi.proxmox.sinextra.dev
parameters:
  storage: local-lvm   # Proxmox storage ID (already exists, points to pve/data thin pool)
  ssd: "false"
  cache: writethrough   # Balance performance and safety for TSDB/model workloads
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Note: `volumeBindingMode: WaitForFirstConsumer` ensures PVs are created on the same node as the pod, preventing cross-node scheduling issues. Combined with anti-affinity rules on database StatefulSets, this spreads block PVs across nodes and avoids SCSI budget concentration.

## Appendix C: SCSI Device Distribution

Proxmox CSI hotplugs SCSI devices into VMs. Each VM supports up to 30 SCSI devices (scsi0-scsi29). With boot disk using scsi0, 29 slots remain per node.

Current plan uses ~14 block PVs total across 5 nodes:
- Databases (CNPG ×3, MySQL ×3, Redis ×2, Vault ×3, Vaultwarden ×1) = 12
- Large workloads (Prometheus ×1, Ollama ×1) = 2
- Total: 14 PVs across 5 nodes = ~3 per node average

Remaining capacity: 14 PVs using ~3 SCSI slots per node leaves ~26 free slots per node. Even if scheduler imbalance puts 8-10 on one node, that's still well under the 29-slot limit. Anti-affinity rules on database StatefulSets ensure spread.

## Appendix D: Data Sizes for Migration Planning

| Service | Current Size (approx) | Migration Method | Expected Duration |
|---------|-----------------------|------------------|-------------------|
| Immich | ~800 GiB (photos/video) | rsync NFS→NFS | 30-60 min |
| servarr/downloads | ~200 GiB | rsync NFS→NFS | 15-30 min |
| ytdlp | ~50 GiB | rsync NFS→NFS | 5-10 min |
| Prometheus TSDB | ~27 GiB | rsync iSCSI→block | 5-10 min |
| CNPG PostgreSQL | ~10 GiB | pg_dumpall / restore | 10-15 min |
| MySQL InnoDB | ~5 GiB | mysqldump/restore | 5 min |
| All other NFS services | <5 GiB each | rsync NFS→NFS | <2 min each |
