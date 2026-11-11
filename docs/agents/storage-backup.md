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
- **`fs_group` on a block-volume PVC: also set `fs_group_change_policy = "OnRootMismatch"`.** Without it the kubelet re-chowns every file on the volume at each mount. Forgejo (~23,000 files) took about an hour to start on 2026-11-02 after an upgrade drain because of this; with the policy the walk only runs when the volume root's ownership is wrong. Stacks that still set `fs_group` without it: `grep -rl 'fs_group *=' stacks | xargs grep -L fs_group_change_policy`.
- **Backup (3-2-1)**: Copy 1 = live PVCs on sdc. Copy 2 = sda `/mnt/backup` (PVC file backups, auto SQLite backups, pfSense, PVE config, **VM images via `vzdump-vms`**). Copy 3 = Synology offsite (two-tier: sda→`pve-backup/`, NFS→`nfs/`+`nfs-ssd/` via inotify change tracking).
- **vzdump-vms** (**Weekly Sun 01:00**): live `vzdump --mode snapshot` of hand-managed VMs (NOT in TF) → `/mnt/backup/vzdump/`, keep 3/VMID. `VZDUMP_VMIDS` default `102` (devvm) — the only VM imaged today; before this (2026-06-09) no VM was ever imaged. Nightly until 2026-08-16, when the full-disk re-read proved too expensive for sdc; it is now the bare-metal restore floor and `devvm-home-backup` does the daily work. NOT in the incremental offsite manifest; monthly full pass mirrors it. See `docs/architecture/backup-dr.md`.
- **nightly-chain** (00:00 UTC, since 2026-11-10): the only nightly backup timer. Takes kured's node lock (`scripts/kured-lock.sh`), runs every CronJob annotated `backup.viktorbarzin.me/nightly-chain=daily|sunday` (suspended; 3 at a time, `kubectl create job --from=cronjob/...`), then nfs-mirror, lvm-pvc-snapshot, daily-backup, devvm-home-backup, t3-state-pull and offsite-sync-backup in that order, each when the previous ends. The step timers are disabled. A new nightly backup CronJob joins by carrying the annotation and `suspend = true`. Details: `docs/architecture/backup-dr.md`.
- **devvm-home-backup** (nightly chain step 6): `rsync --link-dest` incremental of devvm `/home` → `/mnt/backup/devvm-home/`, keep 14 hardlinked generations (~29 GB each). PULL from the PVE host over an `rrsync -ro /home`-pinned key, so devvm cannot reach its own backups. Covers what nothing else does: unpushed commits, uncommitted work, `~/.claude` and `~/.t3`. Measured across all three users 2026-09-13: of 51 repos under wizard's `~/code` exactly **one** had no remote (`cloud`, 332 KB of docs), with 4 unpushed commits across three repos and 24 dirty files across six, plus emo's `infra` clone at 76 dirty files. Since 2026-11-11 every repo under wizard's `~/code` has a remote: `cloud` is the private Forgejo repo `viktor/cloud`, and the monorepo root was dissolved on 2026-11-03, so `~/code` itself is no longer a git repo. The same day wizard's unpushed branches, stashes and dirty worktrees were reviewed and the real work pushed as branches; the record is in `docs/plans/2026-11-11-disposable-devvm.md`, "Unpushed work today". Deployed by `.woodpecker/pve-scripts-sync.yml`.
- **daily-backup** (nightly chain step 5, idle IO): Auto-discovered BACKUP_DIRS (glob), auto SQLite backup (magic number + `?mode=ro`), pfSense, PVE config. No NFS mirror step (NFS syncs directly to Synology via inotify).
- **t3-state-pull** (nightly chain step 7, since 2026-11-11, idle IO): the devvm's daily T3 snapshots (`/var/backups/t3-state/<user>/`, written by `t3-backup-state`) → `/mnt/backup/t3-state/<user>/`, newest 3 per user as `.sqlite.gz`, root-only. PULL over an `rrsync -ro /var/backups/t3-state`-pinned key (`/root/.ssh/id_devvm_t3_state`, authorised by `playbooks/devvm.yml` tag `t3-snapshot`). New files go into the offsite manifest. `t3-restore-state` on the devvm puts the newest back (`--if-missing` from `t3-provision-users`). A Terraform-built devvm copies them back in its first boot (`devvm-bootstrap` step 4c, key Vault `secret/devvm-t3-seed`, pinned on the host to `rrsync -ro /mnt/backup/t3-state` by `pve-host.yml` tag `t3-snapshot`); until then a hold file keeps provisioning from starting an empty T3. Alerts `T3SnapshotOffVmStale`, `T3SnapshotPullNeverReported`. Details: `docs/architecture/backup-dr.md`, T3 snapshots.
- **offsite-sync-backup** (nightly chain step 8, last, idle IO): Step 1: sda→Synology `pve-backup/`. Step 2: NFS→Synology `nfs/`+`nfs-ssd/` via `rsync --files-from` (inotify change log). Monthly full `--delete`.
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

**Ask first whether the app needs a block volume at all (2026-11-09).** Every attached block PVC uses one of 20 hotplug slots on its node VM (`docs/architecture/storage.md`, "Capacity model"), and preemption cannot free one. In order: put the app's data in the shared Postgres or MySQL (`docs/agents/new-app.md`; prefer MySQL when the app supports both, it has the connection headroom and rotates without a restart); plain files that need no encryption go to NFS; anything regenerated at start goes to `emptyDir`; a block volume only for software that locks files (SQLite, LMDB, RocksDB, bbolt, H2) or must survive an NFS outage. Read the app's code before calling a volume disposable: Roundcube's app folder looked regenerable but its plugin install breaks on a fresh tree (`docs/research/2026-11-09-block-volume-db-consolidation.md`, Progress).

**Default for sensitive data is proxmox-lvm-encrypted.** Use plain `proxmox-lvm` only for non-sensitive workloads. Use NFS when you need RWX, backup pipeline integration, or it's a large shared media library.

**NFS server:**
- **Proxmox host** (192.168.1.127): Sole NFS for all workloads. HDD at `/srv/nfs` (ext4 thin LV `pve/nfs-data`, 3 TB). SSD at `/srv/nfs-ssd` (ext4 LV `ssd/nfs-ssd-data`, 100GB). Exports use `async,insecure` options (`async` — safe with UPS + Vault Raft replication + databases on block storage; `insecure` — pfSense NATs source ports >1024 between VLANs).
- **Nextcloud as NFS browser**: Nextcloud (`nextcloud.viktorbarzin.me`) mounts the PVE NFS roots (`/srv/nfs`, `/srv/nfs-ssd`) inside the NC pod at `/mnt/pve-nfs` + `/mnt/pve-nfs-ssd`. Surfaced to users via two ACL patterns: (1) admin-only root browsers `PVE NFS Pool` + `PVE NFS-SSD Pool` (scoped to NC group `admin`); (2) per-archive mounts (e.g. `/anca-elements`) with `applicable_users` set to the owners. ACL is at the mount level via `occ files_external:applicable` — Files Access Control is NOT used (NC 30/31's workflow engine lacks FilePath / UserId checks). Manifest lives in `kubernetes_config_map_v1.nextcloud_external_storage_manifest` (`stacks/nextcloud/external_storage.tf`); a one-shot K8s Job applies it idempotently.
- **`nfs-truenas` StorageClass**: Historical name retained only because SC names are immutable on PVs (48 bound PVs reference it — renaming would require mass PV churn, not worth it). Now points to the Proxmox host (`nfs.csi.k8s.io` dynamic provisioning on `192.168.1.127:/srv/nfs`). TrueNAS (VM 9000, 10.0.10.15) operationally decommissioned 2026-04-13; VM still exists in stopped state on PVE pending user decision on deletion.

**Migration note**: CSI PV `volumeAttributes` are immutable — cannot update NFS server in place. New PV/PVC pairs required (convention: append `-host` to PV name).

**NFS CSI mount option requirements** (learned from [PM-2026-04-14]):
- **ALWAYS set an NFSv4 version (`nfsvers=4.1`, the default since 2026-11-03)** in CSI mount options. NFSv3 is disabled on the PVE host (`vers3=n` in `/etc/nfs.conf`). Without this, mounts fail silently if kernel NFS client state is corrupt.
- **NEVER use `fsid=0`** in `/etc/exports` on `/srv/nfs`. `fsid=0` designates the NFSv4 pseudo-root, which breaks subdirectory path resolution for all CSI mounts. Only `fsid=1` (unique ID) is safe on `/srv/nfs-ssd`.
- **`/etc/exports` is git-managed** at `infra/scripts/pve-nfs-exports`. Deploy: `scp scripts/pve-nfs-exports root@192.168.1.127:/etc/exports && ssh root@192.168.1.127 exportfs -ra`
- **Critical services MUST NOT use NFS storage** — circular dependency risk. Alertmanager, Prometheus, and any monitoring that should alert about NFS must use `proxmox-lvm-encrypted`. Technitium DNS primary uses `proxmox-lvm-encrypted` (migrated 2026-04-14).
- **NFS PV template** (in `modules/kubernetes/nfs_volume/`): always include `mountOptions: ["nfsvers=4.1", "soft", "actimeo=5", "retrans=3", "timeo=30"]` (the module's `nfs_version` variable, default `"4.1"`)
- **Proxmox-host NFS mounts use 4.1, not 4.2** (Immich 2026-11-02, every volume 2026-11-03). Since the Proxmox host booted kernel 7.0.14-25 on 2026-10-23, `copy_file_range` over NFS 4.2 (server-side COPY) writes every byte and then never returns: the calling thread waits in `handle_async_copy` for a completion callback that does not arrive, even though `/proc/fs/nfsd/clients/*/info` shows the callback channel UP. Node's `fs.copyFile`, coreutils `cp` and anything else using `copy_file_range` are affected. `nfs_volume` defaults to `nfs_version = "4.1"`, and the `nfs-pve`, `nfs-truenas` and `verify-nfs` StorageClasses match; 4.1 has no COPY operation, so the client copies the data itself ([PM-2026-11-02](../post-mortems/2026-11-02-immich-thumbnails-nfs-copy-hang.md)). 4.1 does not support user extended attributes (setxattr returns EOPNOTSUPP), and `posix_fallocate` works through glibc's write-zeros fallback. The Synology volume (navidrome-music) passes `"4"` and stays on 4.2. A running pod keeps the version it mounted with until it restarts. Diagnose a suspected hang with `cat /proc/<pid>/task/*/wchan` inside the pod and look for `handle_async_copy`.

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

**PVE host scripts** (source: `infra/scripts/`; deployed by `.woodpecker/pve-scripts-sync.yml` to `/usr/local/bin/<name>`, strip the `.sh`):
- `/usr/local/bin/nightly-chain` — 00:00 UTC, the only nightly backup timer; runs the dumps and the six steps below in order under kured's node lock. `nightly-chain --only <name,...>` runs a subset by hand. Alerts `NightlyChainNotSucceeding`, `NightlyChainStepFailed`, `NightlyChainRanWithoutLock`.
- `/usr/local/bin/nfs-mirror` — nightly chain step 3, after the dumps. `rsync --delete /srv/nfs/<svc>/ → /mnt/backup/<svc>/` (sda leg 1), appends transferred paths to `/mnt/backup/.changed-files` for offsite Step 1. **EXCLUDES**: immich (too big — direct leg), frigate/temp (no backup), anca-elements (in Immich), and **(2026-06-01) ollama, prometheus-backup, audiblez, ebook2audiobook** — regenerable, live-only on sdc, kept off the space-constrained offsite. Does NOT mirror `/srv/nfs-ssd`.
- `/usr/local/bin/daily-backup` — nightly chain step 5, after lvm-pvc-snapshot. Mounts LVM thin snapshots ro → rsyncs FILES to `/mnt/backup/pvc-data/<YYYY-WW>/<ns>/<pvc>/` with `--link-dest` versioning (4 weeks). Auto SQLite backup (magic number check, `?mode=ro`). Also backs up pfSense (config.xml + tar), PVE config. Prunes snapshots >7d. **Skip-list (2026-06-01)**: `nextcloud/nextcloud-data-proxmox` (orphaned pre-encryption PV).
- `/usr/local/bin/t3-state-pull` — nightly chain step 7, after devvm-home-backup. Pulls the devvm's daily T3 snapshots to `/mnt/backup/t3-state/<user>/`, keep 3; Pushgateway job `t3-state-pull`.
- `/usr/local/bin/offsite-sync-backup` — nightly chain step 8, last. Step 1: sda → Synology `pve-backup/` (incremental via manifest; monthly full `rsync --delete` days 1–7). Step 2: NFS direct → Synology — **immich-only on BOTH `nfs/` and `nfs-ssd/` (2026-06-01)**; ollama/llamacpp on the SSD no longer ship offsite.
- `/usr/local/bin/lvm-pvc-snapshot` — nightly chain step 4. Thin snapshots of all PVCs except dbaas+monitoring, in every VG listed in `LVM_SNAP_VGS` (default `pve sas` since 2026-11-03; `daily-backup` reads the same set from `PVC_VGS`, and a new Proxmox-CSI pool must be added to both). 3-day retention (cut from 7 on 2026-06-29, code-oflt: fewer thin snapshots = less thin-pool tmeta CoW write-IOPS on sdc + ~1TB freed; `daily-backup` keeps 4wk file-level history). Instant restore: `lvm-pvc-snapshot restore <lv> <snap>`.
- `/usr/local/bin/vzdump-vms` — **RETIRED 2026-09-15 (`d05be720`); its three alerts removed 2026-09-23.** The timer is disabled on purpose and `scripts/ci/pve-scripts-sync.sh` keeps it disabled via `DISABLED_TIMERS`: each run read all 228 GiB of devvm's disk and took sdc read latency from 0.23 ms to 107.26 ms. **Recovering a devvm is now the devvm playbook plus `devvm-home-backup`**, not `qmrestore`; the three images on `/mnt/backup/vzdump/` (newest 2026-09-13) are a floor that no longer advances. What follows describes it as it ran. It was WEEKLY, Sunday 01:00 (daily until 2026-08-16). Live `vzdump --mode snapshot` of hand-managed VMs (the ones NOT in Terraform) → `/mnt/backup/vzdump/`, keep 3 per VMID (so 3 WEEKS of history now, not 3 days). **Went weekly because `.vma` has no incremental mode**: every run re-read devvm's entire 228 GiB disk in ~75 min = ~245 GB, about 40% of ALL reads on sdc, plus a 69.6 GB archive (~72% of sda's daily writes) — and during that window sdc had no headroom, which is where its ~90 ms p99 read latency came from. Day-to-day protection is now `devvm-home-backup` (below); this image is the **bare-metal restore floor** — it restores the whole VM in one shot, which rsync cannot. Recovering a destroyed devvm: `qmrestore` the newest image, then rsync the newest `devvm-home` generation over the top for the last day's work. `VZDUMP_VMIDS` default `102` (devvm) — **the only VM imaged today** (its per-user home dirs and any uncommitted or unpushed work are otherwise irreplaceable. The monorepo root had a remote and was clean and pushed when measured 2026-09-13; it was dissolved on 2026-11-03. Of 51 repos under wizard's `~/code`, one had no remote then, `cloud`, 332 KB of docs, pushed to Forgejo `viktor/cloud` on 2026-11-11). devvm has the guest agent (`agent: 1`) so dumps are fs-consistent. Deliberately NOT in the incremental offsite manifest (would balloon Synology); the monthly offsite full pass (days 1-7) mirrors `/mnt/backup/vzdump/`. Pushgateway job `vzdump-backup`. Added 2026-06-09 (closed the silent "VMs never imaged" DR gap). Restore: `qmrestore /mnt/backup/vzdump/vzdump-qemu-<vmid>-<ts>.vma.zst <vmid>`.
- `/usr/local/bin/router-config-backup` — Weekly, Sunday 04:30. `sysupgrade -b` config archive of each OpenWrt site router (mladost3-openwrt today) over the tunnel → `/mnt/backup/routers/<name>/`, 8 kept, offsite via the manifest. PULL with key `/root/.ssh/id_router_backup`, pinned on the router to `command="sysupgrade -b -"` (no shell). Pushgateway job `router-config-backup`, alerts `RouterConfigBackupStale`/`Failing`. `nfs-mirror` must keep `--exclude='/routers/'`. Details: `docs/architecture/backup-dr.md`.
- `/usr/local/bin/devvm-home-backup` — nightly chain step 6. File-level **incremental** backup of devvm's `/home` → `/mnt/backup/devvm-home/<YYYY-MM-DD>/`, `rsync --link-dest` hardlink generations, keep 14. Covers the same data `vzdump-vms` protects, but reads only deltas: the tracked set is ~29 GB (vs ~116 GiB raw `/home`) after excluding regenerable content (caches, `node_modules`, venvs, `.rustup`, `.vscode-server`, build dirs, language and cloud SDKs). **The exclude list was 8 GB leakier than it looked until 2026-09-03**: `**/.venv/`/`**/venv/` missed `~/.virtualenvs` and `~/bg-bakeoff-venv`, and `~/.terraform.d`, `~/android-sdk`, `~/.dotnet`, `~/google-cloud-sdk` and the non-`pkg/mod` half of `~/go` had no pattern at all — measured 37.8 GB before, 29.7 GB after. Since 2026-11-03 it also skips `~/.local/share/pnpm`, `~/.local/share/uv`, `~/.local/lib/python3*`, `~/.pyenv` and `~/.codex/.tmp` to cut the nightly stat-walk on sdc: 315k files / 45.9 GB in a dry run, against 553k entries the night before. Deliberately KEPT: `.ssh`, `.config`, `.claude`, `.gnupg`, `~/code` (git repos with uncommitted work; measured 2026-09-13, one of 51 repos had no remote, `cloud`, 332 KB of docs; it has been on Forgejo since 2026-11-11, and the monorepo root was dissolved on 2026-11-03). **PULL, not push** — the PVE host holds the credential and reaches into devvm, so a compromised devvm cannot delete its own backups; the devvm-side key is pinned `command="/usr/bin/rrsync -ro /home",restrict` (read-only, `/home`-scoped, no shell). Key: `/root/.ssh/id_devvm_backup` on the PVE host. The script keeps `/mnt/backup/devvm-home` at 700 root (since 2026-11-11): the generations keep devvm uids, and uid 1000 on the host is the local account emo. **devvm is 10.0.10.10, NOT 10.0.20.102** (the VMID is not in the address). Carried offsite by the monthly offsite-sync full pass, which uses `-H` so the hardlink farm doesn't explode into N full copies. Pushgateway job `devvm-home-backup`. Added 2026-08-16 — see the vzdump entry above for why.
- `nfs-change-tracker.service` — Continuous inotifywait on `/srv/nfs` + `/srv/nfs-ssd`. Logs changed file paths to `/mnt/backup/.nfs-changes.log`. Consumed by offsite-sync-backup for incremental rsync (completes in seconds instead of 30+ minutes).

**Synology layout** (`192.168.1.13:/volume1/Backup/Viki/`):
- `pve-backup/` — PVC file backups (`pvc-data/`), SQLite backups (`sqlite-backup/`), pfSense, PVE config (synced from sda)
- `nfs/` — mirrors `/srv/nfs` on Proxmox (inotify change-tracked rsync)
- `nfs-ssd/` — mirrors `/srv/nfs-ssd` on Proxmox (inotify change-tracked rsync)

**App-level CronJobs** (write to Proxmox host NFS, synced to Synology via inotify):
- MySQL (daily, grants + per-db), PostgreSQL (daily, globals + per-db), ClickHouse (daily, rybbit), Dolt (daily, beads-server), Vault (weekly), Vaultwarden (6h + integrity), Redis (weekly), etcd (weekly)
- **One pass per server (since 2026-11-03)**: `postgresql-backup` (00:00) writes `globals_<ts>.sql.gz` (`pg_dumpall --globals-only`: roles, tablespaces) and then `pg_dump -Fc` of every database to `/backup/per-db/<db>/dump_<ts>.dump`; `mysql-backup` (00:30) writes `grants_<ts>.sql.gz` (`SHOW CREATE USER` + `SHOW GRANTS` for every non-system account) and then `mysqldump --single-transaction --routines --events` of every database to `/backup/per-db/<db>/dump_<ts>.sql.gz`. Until then a full dump and a separate `*-per-db` job each read every database, twice a night on the IOPS-bound sdc. The per-db paths are unchanged. A failed database now fails the job and holds back `backup_last_success_timestamp`. Manual and pre-upgrade runs (`kubectl create job --from=cronjob/postgresql-backup`, `scripts/renovate-rails`) still produce a complete backup. The last full `dump_*.sql.gz` files age out by 2026-11-17.
- **Pushgateway push without curl**: the PostgreSQL backup jobs (dbaas full + per-db, Immich) run `postgres:16.15-trixie`, which has no curl or wget, and push `backup_last_success_timestamp` with Perl's core `HTTP::Tiny`. Do not add a run-time `apt-get install curl`: that is what broke the push when `bullseye-pgdg` left apt (2026-09-06 to 2026-10-10, dumps fine, timestamp stale). Keep the client major equal to `pg-cluster`'s.
- **Immich app settings that affect sdc (set through the Immich admin API on 2026-11-03, stored in Immich's own database, not in Terraform)**: the built-in database backup (`backup.database`, daily 02:00, 14 kept, ~1.5 GB each in `/srv/nfs/immich/backups`) is disabled because it duplicated `immich/postgresql-backup` below, which is the monitored one; and the integrity checksum job (`integrityChecks.checksumFiles`) runs weekly, Sunday 10:00 UTC, instead of daily at 03:00, where it read `/srv/nfs` at 700-1,125 IOPS for an hour. The missing/untracked-file checks stay daily at 03:00 (cheap stat passes). The existing 20 GB of built-in backups were left in place.
- **Immich Postgres** (`immich/postgresql-backup`, 00:00): `pg_dumpall | gzip -6` to `/srv/nfs/immich/postgresql/dump_<date>.sql.gz`, written as `.partial` and renamed when complete, 14-day retention. Until 2026-10-20 it wrote a plain 3.5 GB `.sql`; on 10-19 and 10-20 the dirty NFS page cache pushed the pod past its 1Gi limit, the memcg OOM killer took `pg_dump`, and the Job's retry wrote the complete dump. The truncated first attempts (`dump_2026_10_19_00_00.sql`, `dump_2026_10_20_00_00.sql`, both without the closing `-- PostgreSQL database cluster dump complete` line) are still on disk and age out with the 14-day rule; restore from the dump that ends with that line. Retention: `dump_*.sql` and `dump_*.sql.gz` older than 14 days, and `dump_*.sql.gz.partial` older than a day (left by a killed run; a running dump's `.partial` is newer). Reading a new dump: `zcat dump_<date>.sql.gz | tail -n 2` shows the completion line, and `zcat dump_<date>.sql.gz | psql ...` feeds a restore. Restore: `docs/runbooks/restore-immich-postgresql.md` (tested into a scratch server on 2026-10-20). Freshness is unaffected by the format: `PostgresBackupPushStale` reads the pushed `backup_last_success_timestamp`, which is now pushed only after a complete dump, and `stacks/immich/verify.sh` waits up to 1200 s for the Job (433 s with gzip on 2026-10-20). Offsite sync copies `/srv/nfs/immich/` whatever the file names.
- **Convention**: New proxmox-lvm apps MUST add a backup CronJob writing to `/mnt/main/<app>-backup/`

**Restore paths**:
- Single database: `pg_restore -d <db> --clean --if-exists` (PG) or `mysql <db> < dump.sql.gz` (MySQL) from per-db backup
- Whole server: PG `globals_<ts>.sql.gz` into psql, then `pg_restore --create -d postgres` per database; MySQL `grants_<ts>.sql.gz` into mysql, then each per-db dump (`docs/runbooks/restore-postgresql.md`, `restore-mysql.md`)
- Accidental delete: `lvm-pvc-snapshot restore` (instant, 7 daily snapshots)
- Older data: Browse `/mnt/backup/pvc-data/<week>/<ns>/<pvc>/`, rsync back
- Database (full cluster): Restore from dump at `/srv/nfs/<db>-backup/` or Synology `nfs/<db>-backup/`
- pfsense: Upload config.xml via web UI, or extract tar for custom scripts
- Full disaster: Restore from Synology
