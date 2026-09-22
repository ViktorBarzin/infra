# Storage and backup

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/storage.md`, `docs/architecture/backup-dr.md`.

## Storage
- **NFS** (`nfs-proxmox` StorageClass): For app data. Use the `nfs_volume` module, never inline `nfs {}` blocks.
- **proxmox-lvm-encrypted** (`proxmox-lvm-encrypted` StorageClass): **Default for all sensitive data** — databases, auth, email, passwords, git repos, health data. LUKS2 encryption via Proxmox CSI. Passphrase in Vault, backup key on PVE host.
- **proxmox-lvm** (`proxmox-lvm` StorageClass): For non-sensitive stateful apps (configs, caches, tools). Proxmox CSI driver.
- **NFS server**: Proxmox host at 192.168.1.127 (sole NFS). HDD NFS at `/srv/nfs` (2TB ext4 LV `pve/nfs-data`), SSD NFS at `/srv/nfs-ssd` (100GB ext4 LV `ssd/nfs-ssd-data`). Exports use `async` mode (safe with UPS + databases on block storage). TrueNAS (VM 9000, 10.0.10.15) decommissioned 2026-04-13. Legacy `nfs-truenas` StorageClass name retained (48 PVs bind it; SC names are immutable on PVs) but now points to the Proxmox host, identical to `nfs-proxmox`.
- **SQLite on NFS is unreliable** (fsync issues) — always use proxmox-lvm or local disk for databases.
- **NFS mount options**: Always `soft,timeo=30,retrans=3` to prevent uninterruptible sleep (D state).
- **NFS export directory must exist** on the Proxmox host before Terraform can create the PV.
- **Backup (3-2-1)**: Copy 1 = live PVCs on sdc. Copy 2 = sda `/mnt/backup` (PVC file backups, auto SQLite backups, pfSense, PVE config, **VM images via `vzdump-vms`**). Copy 3 = Synology offsite (two-tier: sda→`pve-backup/`, NFS→`nfs/`+`nfs-ssd/` via inotify change tracking).
- **vzdump-vms** (**Weekly Sun 01:00**): live `vzdump --mode snapshot` of hand-managed VMs (NOT in TF) → `/mnt/backup/vzdump/`, keep 3/VMID. `VZDUMP_VMIDS` default `102` (devvm) — the only VM imaged today; before this (2026-06-09) no VM was ever imaged. Nightly until 2026-08-16, when the full-disk re-read proved too expensive for sdc; it is now the bare-metal restore floor and `devvm-home-backup` does the daily work. NOT in the incremental offsite manifest; monthly full pass mirrors it. See `docs/architecture/backup-dr.md`.
- **devvm-home-backup** (Daily 03:30): `rsync --link-dest` incremental of devvm `/home` → `/mnt/backup/devvm-home/`, keep 14 hardlinked generations (~29 GB each). PULL from the PVE host over an `rrsync -ro /home`-pinned key, so devvm cannot reach its own backups. Covers what nothing else does: unpushed commits, uncommitted work, `~/.claude` and `~/.t3`. Measured across all three users 2026-09-13: of 51 repos under wizard's `~/code` exactly **one** has no remote (`cloud`, 332 KB of docs), with 4 unpushed commits across three repos and 24 dirty files across six, plus emo's `infra` clone at 76 dirty files. **The monorepo root DOES have a remote** (`github.com/ViktorBarzin/monorepo`), clean and pushed, so the older "two repos with no remote" figure is retired. Deployed by `.woodpecker/pve-scripts-sync.yml`.
- **daily-backup** (Daily 05:00): Auto-discovered BACKUP_DIRS (glob), auto SQLite backup (magic number + `?mode=ro`), pfSense, PVE config. No NFS mirror step (NFS syncs directly to Synology via inotify).
- **offsite-sync-backup** (Daily 06:00): Step 1: sda→Synology `pve-backup/`. Step 2: NFS→Synology `nfs/`+`nfs-ssd/` via `rsync --files-from` (inotify change log). Monthly full `--delete`.
- **nfs-change-tracker.service**: inotifywait on `/srv/nfs` + `/srv/nfs-ssd`, logs to `/mnt/backup/.nfs-changes.log`. Incremental syncs complete in seconds.
- **Synology layout** (`/volume1/Backup/Viki/`): `pve-backup/` (from sda), `nfs/` (from `/srv/nfs`), `nfs-ssd/` (from `/srv/nfs-ssd`).

## Storage & Backup Architecture

### Storage Class Decision Rule (for new services)

Choose storage class based on workload type:

| Use **proxmox-lvm-encrypted** when | Use **proxmox-lvm** when | Use **NFS** (`nfs_volume` module) when |
|------------------------------------|--------------------------|----------------------------------------|
| **Any service storing sensitive data** | Non-sensitive app state (configs, caches) | Shared data across multiple pods (RWX) |
| Databases (user data, credentials) | Media indexes, search caches | Media libraries (music, ebooks, photos) |
| Auth/identity services | Monitoring data (Prometheus) | Backup destinations (cloud sync picks up from NFS) |
| Password managers, email, git repos | Tools with no user secrets | Large datasets (>10Gi) where snapshots matter |
| Health/financial data | | Data you want to browse/inspect from outside k8s |

**Default for sensitive data is proxmox-lvm-encrypted.** Use plain `proxmox-lvm` only for non-sensitive workloads. Use NFS when you need RWX, backup pipeline integration, or it's a large shared media library.

**NFS server:**
- **Proxmox host** (192.168.1.127): Sole NFS for all workloads. HDD at `/srv/nfs` (ext4 thin LV `pve/nfs-data`, 3 TB). SSD at `/srv/nfs-ssd` (ext4 LV `ssd/nfs-ssd-data`, 100GB). Exports use `async,insecure` options (`async` — safe with UPS + Vault Raft replication + databases on block storage; `insecure` — pfSense NATs source ports >1024 between VLANs).
- **Nextcloud as NFS browser**: Nextcloud (`nextcloud.viktorbarzin.me`) mounts the PVE NFS roots (`/srv/nfs`, `/srv/nfs-ssd`) inside the NC pod at `/mnt/pve-nfs` + `/mnt/pve-nfs-ssd`. Surfaced to users via two ACL patterns: (1) admin-only root browsers `PVE NFS Pool` + `PVE NFS-SSD Pool` (scoped to NC group `admin`); (2) per-archive mounts (e.g. `/anca-elements`) with `applicable_users` set to the owners. ACL is at the mount level via `occ files_external:applicable` — Files Access Control is NOT used (NC 30/31's workflow engine lacks FilePath / UserId checks). Manifest lives in `kubernetes_config_map_v1.nextcloud_external_storage_manifest` (`stacks/nextcloud/external_storage.tf`); a one-shot K8s Job applies it idempotently.
- **`nfs-truenas` StorageClass**: Historical name retained only because SC names are immutable on PVs (48 bound PVs reference it — renaming would require mass PV churn, not worth it). Now points to the Proxmox host (`nfs.csi.k8s.io` dynamic provisioning on `192.168.1.127:/srv/nfs`). TrueNAS (VM 9000, 10.0.10.15) operationally decommissioned 2026-04-13; VM still exists in stopped state on PVE pending user decision on deletion.

**Migration note**: CSI PV `volumeAttributes` are immutable — cannot update NFS server in place. New PV/PVC pairs required (convention: append `-host` to PV name).

**NFS CSI mount option requirements** (learned from [PM-2026-04-14]):
- **ALWAYS set `nfsvers=4`** in CSI mount options. NFSv3 is disabled on the PVE host (`vers3=n` in `/etc/nfs.conf`). Without this, mounts fail silently if kernel NFS client state is corrupt.
- **NEVER use `fsid=0`** in `/etc/exports` on `/srv/nfs`. `fsid=0` designates the NFSv4 pseudo-root, which breaks subdirectory path resolution for all CSI mounts. Only `fsid=1` (unique ID) is safe on `/srv/nfs-ssd`.
- **`/etc/exports` is git-managed** at `infra/scripts/pve-nfs-exports`. Deploy: `scp scripts/pve-nfs-exports root@192.168.1.127:/etc/exports && ssh root@192.168.1.127 exportfs -ra`
- **Critical services MUST NOT use NFS storage** — circular dependency risk. Alertmanager, Prometheus, and any monitoring that should alert about NFS must use `proxmox-lvm-encrypted`. Technitium DNS primary uses `proxmox-lvm-encrypted` (migrated 2026-04-14).
- **NFS PV template** (in `modules/kubernetes/nfs_volume/`): always include `mountOptions: ["nfsvers=4", "soft", "actimeo=5", "retrans=3", "timeo=30"]`

**proxmox-lvm PVC template** (Terraform):
```hcl
resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "<service>-data-proxmox"
    namespace = kubernetes_namespace.<ns>.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer expands this PVC up to storage_limit; ignore drift on
    # requests.storage so the next TF apply doesn't try to shrink it back
    # (K8s rejects shrinks → apply fails). To bump the floor manually:
    # temporarily remove this block, apply the new size, re-add the block,
    # apply again.
    ignore_changes = [spec[0].resources[0].requests]
  }
}
```
- `wait_until_bound = false` is **required** (WaitForFirstConsumer binding)
- Deployment strategy **must be Recreate** (RWO volumes)
- Autoresizer annotations are **required** on all proxmox-lvm PVCs
- `lifecycle.ignore_changes` on `requests` is **required** to coexist with the autoresizer
- Every proxmox-lvm app **MUST** add a backup CronJob writing to NFS `/mnt/main/<app>-backup/`

**proxmox-lvm-encrypted PVC template** (Terraform) — use for all sensitive data:
```hcl
resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "<service>-data-encrypted"
    namespace = kubernetes_namespace.<ns>.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  lifecycle {
    # See data_proxmox above — required for autoresizer coexistence.
    ignore_changes = [spec[0].resources[0].requests]
  }
}
```
- Same rules as `proxmox-lvm` (wait_until_bound, Recreate strategy, autoresizer, backup CronJob, `lifecycle.ignore_changes`)
- Uses LUKS2 encryption with Argon2id key derivation via Proxmox CSI plugin
- Encryption passphrase stored in Vault KV (`secret/viktor/proxmox_csi_encryption_passphrase`), synced to K8s Secret `proxmox-csi-encryption` in `kube-system` via ExternalSecret
- Backup key at `/root/.luks-backup-key` on PVE host (chmod 600)
- CSI node plugin needs 1280Mi memory limit for LUKS operations (`node.plugin.resources` in Helm values)
- Convention: PVC names end in `-encrypted` (not `-proxmox`)

### 3-2-1 Backup Strategy
**Copy 1**: Live data on sdc thin pool (65 PVCs + VMs)
**Copy 2**: sda backup disk (`/mnt/backup`, 1.1TB ext4, VG `backup`)
**Copy 3**: Synology NAS offsite (two-tier: sda + NFS)

**PVE host scripts** (source: `infra/scripts/`; deployed manually via `scp` to `/usr/local/bin/<name>` — strip the `.sh`):
- `/usr/local/bin/nfs-mirror` — Daily 02:00. `rsync --delete /srv/nfs/<svc>/ → /mnt/backup/<svc>/` (sda leg 1), appends transferred paths to `/mnt/backup/.changed-files` for offsite Step 1. **EXCLUDES**: immich (too big — direct leg), frigate/temp (no backup), anca-elements (in Immich), and **(2026-06-01) ollama, prometheus-backup, audiblez, ebook2audiobook** — regenerable, live-only on sdc, kept off the space-constrained offsite. Does NOT mirror `/srv/nfs-ssd`.
- `/usr/local/bin/daily-backup` — Daily 05:00. Mounts LVM thin snapshots ro → rsyncs FILES to `/mnt/backup/pvc-data/<YYYY-WW>/<ns>/<pvc>/` with `--link-dest` versioning (4 weeks). Auto SQLite backup (magic number check, `?mode=ro`). Also backs up pfSense (config.xml + tar), PVE config. Prunes snapshots >7d. **Skip-list (2026-06-01)**: `nextcloud/nextcloud-data-proxmox` (orphaned pre-encryption PV).
- `/usr/local/bin/offsite-sync-backup` — Daily 06:00 (After=daily-backup). Step 1: sda → Synology `pve-backup/` (incremental via manifest; monthly full `rsync --delete` days 1–7). Step 2: NFS direct → Synology — **immich-only on BOTH `nfs/` and `nfs-ssd/` (2026-06-01)**; ollama/llamacpp on the SSD no longer ship offsite.
- `/usr/local/bin/lvm-pvc-snapshot` — Daily 03:00. Thin snapshots of all PVCs except dbaas+monitoring. 3-day retention (cut from 7 on 2026-06-29, code-oflt: fewer thin snapshots = less thin-pool tmeta CoW write-IOPS on sdc + ~1TB freed; `daily-backup` keeps 4wk file-level history). Instant restore: `lvm-pvc-snapshot restore <lv> <snap>`.
- `/usr/local/bin/vzdump-vms` — **WEEKLY, Sunday 01:00** (was daily until 2026-08-16). Live `vzdump --mode snapshot` of hand-managed VMs (the ones NOT in Terraform) → `/mnt/backup/vzdump/`, keep 3 per VMID (so 3 WEEKS of history now, not 3 days). **Went weekly because `.vma` has no incremental mode**: every run re-read devvm's entire 228 GiB disk in ~75 min = ~245 GB, about 40% of ALL reads on sdc, plus a 69.6 GB archive (~72% of sda's daily writes) — and during that window sdc had no headroom, which is where its ~90 ms p99 read latency came from. Day-to-day protection is now `devvm-home-backup` (below); this image is the **bare-metal restore floor** — it restores the whole VM in one shot, which rsync cannot. Recovering a destroyed devvm: `qmrestore` the newest image, then rsync the newest `devvm-home` generation over the top for the last day's work. `VZDUMP_VMIDS` default `102` (devvm) — **the only VM imaged today** (its per-user home dirs and any uncommitted or unpushed work are otherwise irreplaceable. **The monorepo root DOES have a remote** and was clean and pushed when measured 2026-09-13; the older "no-remote monorepo root" claim is retired. Of 51 repos under wizard's `~/code`, one has no remote and it is `cloud`, 332 KB of docs). devvm has the guest agent (`agent: 1`) so dumps are fs-consistent. Deliberately NOT in the incremental offsite manifest (would balloon Synology); the monthly offsite full pass (days 1-7) mirrors `/mnt/backup/vzdump/`. Pushgateway job `vzdump-backup`. Added 2026-06-09 (closed the silent "VMs never imaged" DR gap). Restore: `qmrestore /mnt/backup/vzdump/vzdump-qemu-<vmid>-<ts>.vma.zst <vmid>`.
- `/usr/local/bin/devvm-home-backup` — Daily 03:30. File-level **incremental** backup of devvm's `/home` → `/mnt/backup/devvm-home/<YYYY-MM-DD>/`, `rsync --link-dest` hardlink generations, keep 14. Covers the same data `vzdump-vms` protects, but reads only deltas: the tracked set is ~29 GB (vs ~116 GiB raw `/home`) after excluding regenerable content (caches, `node_modules`, venvs, `.rustup`, `.vscode-server`, build dirs, language and cloud SDKs). **The exclude list was 8 GB leakier than it looked until 2026-09-03**: `**/.venv/`/`**/venv/` missed `~/.virtualenvs` and `~/bg-bakeoff-venv`, and `~/.terraform.d`, `~/android-sdk`, `~/.dotnet`, `~/google-cloud-sdk` and the non-`pkg/mod` half of `~/go` had no pattern at all — measured 37.8 GB before, 29.7 GB after. Deliberately KEPT: `.ssh`, `.config`, `.claude`, `.gnupg`, `~/code` (git repos with uncommitted work; measured 2026-09-13, one of 51 repos has no remote and it is `cloud`, 332 KB of docs, while the monorepo root has one and is clean). **PULL, not push** — the PVE host holds the credential and reaches into devvm, so a compromised devvm cannot delete its own backups; the devvm-side key is pinned `command="/usr/bin/rrsync -ro /home",restrict` (read-only, `/home`-scoped, no shell). Key: `/root/.ssh/id_devvm_backup` on the PVE host. **devvm is 10.0.10.10, NOT 10.0.20.102** (the VMID is not in the address). Carried offsite by the monthly offsite-sync full pass, which uses `-H` so the hardlink farm doesn't explode into N full copies. Pushgateway job `devvm-home-backup`. Added 2026-08-16 — see the vzdump entry above for why.
- `nfs-change-tracker.service` — Continuous inotifywait on `/srv/nfs` + `/srv/nfs-ssd`. Logs changed file paths to `/mnt/backup/.nfs-changes.log`. Consumed by offsite-sync-backup for incremental rsync (completes in seconds instead of 30+ minutes).

**Synology layout** (`192.168.1.13:/volume1/Backup/Viki/`):
- `pve-backup/` — PVC file backups (`pvc-data/`), SQLite backups (`sqlite-backup/`), pfSense, PVE config (synced from sda)
- `nfs/` — mirrors `/srv/nfs` on Proxmox (inotify change-tracked rsync)
- `nfs-ssd/` — mirrors `/srv/nfs-ssd` on Proxmox (inotify change-tracked rsync)

**App-level CronJobs** (write to Proxmox host NFS, synced to Synology via inotify):
- MySQL (daily full + per-db), PostgreSQL (daily full + per-db), Vault (weekly), Vaultwarden (6h + integrity), Redis (weekly), etcd (weekly)
- **Per-database backups**: `postgresql-backup-per-db` (00:15, `pg_dump -Fc` → `/backup/per-db/<db>/`) and `mysql-backup-per-db` (00:45, `mysqldump` → `/backup/per-db/<db>/`). Enables single-database restore without affecting others.
- **Convention**: New proxmox-lvm apps MUST add a backup CronJob writing to `/mnt/main/<app>-backup/`

**Restore paths**:
- Single database: `pg_restore -d <db> --clean --if-exists` (PG) or `mysql <db> < dump.sql.gz` (MySQL) from per-db backup
- Accidental delete: `lvm-pvc-snapshot restore` (instant, 7 daily snapshots)
- Older data: Browse `/mnt/backup/pvc-data/<week>/<ns>/<pvc>/`, rsync back
- Database (full cluster): Restore from dump at `/srv/nfs/<db>-backup/` or Synology `nfs/<db>-backup/`
- pfsense: Upload config.xml via web UI, or extract tar for custom scripts
- Full disaster: Restore from Synology
