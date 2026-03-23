# Backup & Disaster Recovery Strategy

Last updated: 2026-03-23

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TrueNAS (10.0.10.15)                        │
│                                                                     │
│  ZFS Pool "main" (1.64 TiB)     ZFS Pool "ssd"                    │
│  ├── NFS shares (~100)           ├── Immich ML data                │
│  └── iSCSI zvols (~19 PVCs)     └── PostgreSQL data               │
│                                                                     │
│  Layer 1: ZFS Auto-Snapshots                                       │
│  ┌──────────────────────────────────────────────┐                  │
│  │ Every 12h  → auto-12h-*  (24h retention)     │                  │
│  │ Daily      → auto-*      (3-week retention)  │                  │
│  │ Both pools, recursive, near-instant (<1s)     │                  │
│  └──────────────────────────────────────────────┘                  │
└────────────────┬────────────────────────────────┬───────────────────┘
                 │                                │
    ┌────────────▼────────────┐      ┌────────────▼────────────┐
    │  Layer 2: App Backups   │      │  Layer 3: Offsite Sync  │
    │  (K8s CronJobs → NFS)  │      │  (TrueNAS → Synology)   │
    └────────────┬────────────┘      └────────────┬────────────┘
                 │                                │
                 ▼                                ▼
    ┌─────────────────────┐      ┌──────────────────────────────┐
    │  /mnt/main/*-backup │      │  Synology NAS (192.168.1.13) │
    │  (NFS-exported dirs) │      │  /Backup/Viki/truenas        │
    └─────────────────────┘      └──────────────────────────────┘
```

## Layer 1: ZFS Auto-Snapshots

Near-instant copy-on-write snapshots. No disk I/O beyond tiny metadata writes.

| Pool   | Schedule       | Retention | Naming Schema             |
|--------|----------------|-----------|---------------------------|
| `main` | Every 12h      | 24 hours  | `auto-12h-YYYY-MM-DD_HH-MM` |
| `main` | Daily 00:00    | 3 weeks   | `auto-YYYY-MM-DD_HH-MM`     |
| `ssd`  | Every 12h      | 24 hours  | `auto-12h-YYYY-MM-DD_HH-MM` |
| `ssd`  | Daily 00:00    | 3 weeks   | `auto-YYYY-MM-DD_HH-MM`     |

**Performance**: Both pools snapshot in <1 second (tested 2026-03-23).

## Layer 2: Application-Level Backups

K8s CronJobs dump application data to NFS-exported backup directories.

```
┌──────────────────────────────────────────────────────────────────┐
│                    K8s CronJob Backup Schedule                   │
│                                                                  │
│  00:00 ─── PostgreSQL (pg_dumpall → gzip -9) ──→ 14d retention  │
│  00:30 ─── MySQL (mysqldump → gzip -9) ─────────→ 14d retention │
│                                                                  │
│  Sunday:                                                         │
│  01:00 ─── etcd (etcdctl snapshot) ──────────────→ 30d retention │
│  01:30 ─── Vaultwarden (sqlite3 .backup) ────────→ 30d retention │
│  02:00 ─── Vault (raft snapshot) ────────────────→ 30d retention │
│  03:00 ─── Redis (BGSAVE + copy) ────────────────→ 30d retention │
│  03:00 ─── plotting-book (sqlite3 .backup) ──────→ 30d retention │
│                                                                  │
│  Monthly (1st Sunday):                                           │
│  04:00 ─── Prometheus TSDB (snapshot → tar.gz) ──→ 2 copies     │
│                                                                  │
│  Every 6h:                                                       │
│  */6   ─── Vaultwarden backup ───────────────────→ 30d retention │
│  :30   ─── Vaultwarden integrity check ──────────→ metric push  │
└──────────────────────────────────────────────────────────────────┘
```

### Vaultwarden Enhanced Protection

Vaultwarden uses iSCSI storage (SQLite on block device) and has extra safeguards:

```
Every 6 hours                          Every hour
┌─────────────────────────┐            ┌────────────────────────────┐
│ vaultwarden-backup      │            │ vaultwarden-integrity-check│
│                         │            │                            │
│ 1. PRAGMA integrity_check│           │ 1. PRAGMA integrity_check  │
│    (fail → abort)       │            │ 2. Push metric to          │
│ 2. sqlite3 .backup      │            │    Pushgateway:            │
│ 3. PRAGMA integrity_check│           │    vaultwarden_sqlite_     │
│    on backup copy       │            │    integrity_ok {0|1}      │
│ 4. Copy RSA keys,       │            └────────────────────────────┘
│    attachments, sends,  │
│    config.json          │
│ 5. Rotate (30d)         │
└─────────────────────────┘
```

## Layer 3: Offsite Sync to Synology NAS

Hybrid approach: fast incremental copies + weekly full sync for cleanup.

```
                    TrueNAS                              Synology
                 (10.0.10.15)                        (192.168.1.13)
                      │                                    │
  Every 6h (cron)     │    zfs diff → changed files list   │
  ════════════════     │                                    │
  /root/cloudsync-     │  rclone copy --files-from          │
  copy.sh              │  --no-traverse                     │
                       │──────────────────────────────────→ │
                       │    Only changed files,             │
                       │    seconds to minutes              │
                       │                                    │
  Sunday 09:00         │    rclone sync                     │
  (Cloud Sync Task 1)  │    (full traversal)                │
  ════════════════     │──────────────────────────────────→ │
                       │    ~30-60 min,                     │
                       │    handles deletions               │
                       │                                    │
```

### Incremental COPY — How It Works

```
  cloudsync-copy-prev          cloudsync-copy
  (previous snapshot)          (new snapshot)
         │                          │
         └────── zfs diff -F -H ────┘
                      │
                      ▼
              Changed files only
              (type=F, excludes applied)
                      │
                      ▼
         /tmp/cloudsync_copy_files.txt
                      │
                      ▼
         rclone copy --files-from-raw
         --no-traverse (skip SFTP scan)
                      │
                      ▼
              Synology updated
                      │
                      ▼
         Rotate: prev→destroy, new→prev
```

**Key files**:
- Script: `/root/cloudsync-copy.sh`
- Log: `/var/log/cloudsync-copy.log`
- Cron job: TrueNAS cron id=1, `0 */6 * * *`

### Excludes (both incremental and weekly sync)

| Pattern                | Reason                              |
|------------------------|-------------------------------------|
| `clickhouse/**`        | 2.47M files, regenerable            |
| `loki/**`              | 68K files, regenerable logs         |
| `iocage/**`            | 96K files, legacy FreeBSD jails     |
| `frigate/recordings/**`| 57K files, ephemeral video clips    |
| `prometheus/**`        | Large TSDB, separate monthly backup |
| `crowdsec/**`          | Regenerable threat data             |
| `servarr/downloads/**` | Transient download staging          |
| `iscsi/**`             | Raw zvols, backed up at app level   |
| `iscsi-snaps/**`       | Snapshot metadata                   |
| `ytldp/**`             | YouTube downloads, replaceable      |
| `*.log`                | Log files                           |
| `post`                 | Transient POST data                 |

### Weekly SYNC (Cloud Sync Task 1)

- **Mode**: SYNC (mirrors source → destination, removes deleted files)
- **Schedule**: Sunday 09:00
- **Pre-script**: Creates ZFS snapshot `main@cloudsync-new`
- **Post-script**: Rotates snapshots (`new` → `prev`, creates placeholder)
- **Source path**: `/mnt/main/.zfs/snapshot/cloudsync-new`
- **Destination**: `synology:/Backup/Viki/truenas` (SFTP)

## iSCSI Hardening

To prevent SQLite corruption from transient network disruptions, iSCSI
initiator timeouts are relaxed on all K8s nodes:

```
Setting                              Default    Hardened
─────────────────────────────────────────────────────────
node.session.timeo.replacement_timeout  120s      300s
node.conn[0].timeo.noop_out_interval      5s       10s
node.conn[0].timeo.noop_out_timeout       5s       15s
node.conn[0].iscsi.HeaderDigest         None   CRC32C,None
node.conn[0].iscsi.DataDigest           None   CRC32C,None
```

- Applied to all 5 nodes (k8s-master + k8s-node1-4) on 2026-03-23
- Baked into cloud-init template (`modules/create-template-vm/cloud_init.yaml`)
  so new nodes get these settings automatically

## Monitoring & Alerting

```
┌─────────────────────────────────────────────────────────┐
│                   Prometheus Alerts                      │
│                                                         │
│  PostgreSQLBackupStale      > 36h since last success    │
│  MySQLBackupStale           > 36h since last success    │
│  EtcdBackupStale            > 8d  since last success    │
│  VaultBackupStale           > 8d  since last success    │
│  VaultwardenBackupStale     > 8d  since last success    │
│  RedisBackupStale           > 8d  since last success    │
│  PrometheusBackupStale      > 32d since last success    │
│  CloudSyncStale             > 8d  since last success    │
│  CloudSyncNeverRun          task never completed        │
│  CloudSyncFailing           task in error state         │
│  VaultwardenIntegrityFail   integrity_ok == 0           │
└─────────────────────────────────────────────────────────┘
```

- `cloudsync-monitor` CronJob queries TrueNAS API every 6h, pushes to Pushgateway
- Vaultwarden integrity check pushes `vaultwarden_sqlite_integrity_ok` hourly

## Service Protection Matrix

| Service | Layer 1 (ZFS) | Layer 2 (App) | Layer 3 (Offsite) | Storage |
|---------|:---:|:---:|:---:|---------|
| PostgreSQL (12 DBs) | ✓ | ✓ daily | ✓ | NFS |
| MySQL (7 DBs) | ✓ | ✓ daily | ✓ | NFS |
| Vault | ✓ | ✓ weekly | ✓ | iSCSI |
| etcd | ✓ | ✓ weekly | ✓ | local |
| Vaultwarden | ✓ | ✓ 6h + integrity | ✓ | iSCSI |
| Redis | ✓ | ✓ weekly | ✓ | iSCSI |
| Prometheus | ✓ | ✓ monthly | excluded | NFS |
| plotting-book | ✓ | ✓ weekly | ✓ | iSCSI |
| Immich | ✓ | — | ✓ | NFS |
| Forgejo | ✓ | — | ✓ | NFS |
| Paperless-ngx | ✓ | — | ✓ | NFS |
| Other NFS services | ✓ | — | ✓ | NFS |

NFS-backed services with simple data (files, SQLite) rely on ZFS snapshots +
offsite sync. Application-level backups are only needed for services with
complex state (databases, Raft consensus, multi-file consistency).

## Recovery Procedures

See individual runbooks in `docs/runbooks/`:
- `restore-postgresql.md`
- `restore-mysql.md`
- `restore-vault.md`
- `restore-vaultwarden.md`
- `restore-etcd.md`
- `restore-full-cluster.md`
