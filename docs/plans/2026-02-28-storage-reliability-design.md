# Storage Reliability: Database Replication + SQLite Consolidation

**Date**: 2026-02-28
**Status**: Approved
**Goal**: Eliminate data corruption risk from NFS outages by moving databases off NFS

## Problem

All 70+ services store data on a single TrueNAS VM (10.0.10.15) via NFS. When this VM crashes or hangs:

- **22 services** risk **data corruption** (databases with WAL/fsync requirements on NFS)
- **12 services** experience downtime but no corruption (media, configs)
- The shared PostgreSQL alone backs 12 services — a single NFS hiccup can corrupt data for all of them

SQLite-over-NFS is fundamentally broken (advisory locking unreliable, WAL mode unsafe).

## Constraints

- Zero cost — all self-hosted, OSS
- Must preserve backup workflow (consolidate to TrueNAS → rsync to backup NAS)
- Stop-and-verify after each service migration
- No data loss tolerance

## Design

### Strategy Overview

```
BEFORE:  All services → NFS (TrueNAS VM) → single point of failure

AFTER:   Databases → local disk + native replication (HA, proper fsync)
         SQLite apps → migrated to shared PostgreSQL where possible
         Media/configs → NFS (TrueNAS, non-critical path)
         Backups → all consolidate to NFS → rsync to backup NAS
```

### Component 1: PostgreSQL HA via CloudNativePG

**Current**: Single PostgreSQL 16 pod on NFS (`/mnt/main/postgresql/data`)
**Target**: CloudNativePG operator with 3-instance cluster on local disk

CloudNativePG is a CNCF K8s operator that manages PostgreSQL clusters with:
- Automatic primary/replica failover
- Streaming replication across nodes
- Continuous WAL archiving (to NFS for backup)
- Local PVCs for data (proper fsync)

Architecture:
```
CloudNativePG Cluster
├── Primary (node A) — local PVC
├── Replica (node B) — local PVC, streaming replication
├── Replica (node C) — local PVC, streaming replication
└── WAL archive → NFS:/mnt/main/postgresql-wal-archive/ (backup only)
```

Dependent services (unchanged connection, new reliable backend):
authentik, n8n, dawarich, tandoor, linkwarden, netbox, woodpecker,
rybbit, affine, health, resume, trading-bot

Resource overhead: ~3GB RAM total, ~50GB local disk per node

### Component 2: MySQL HA (or Migration to PostgreSQL)

**Current**: Single MySQL pod on NFS (`/mnt/main/mysql`)
**Target**: Either MySQL Operator (InnoDB Cluster) or migrate MySQL services to PostgreSQL

Services on MySQL: hackmd, speedtest, onlyoffice, crowdsec,
paperless-ngx, real-estate-crawler, url-shortener, grafana

Many of these support PostgreSQL. Consolidating to one DB engine
reduces operational complexity. Evaluate per-service during implementation.

### Component 3: Redis HA via Sentinel

**Current**: Single redis-stack pod on NFS (`/mnt/main/redis`)
**Target**: Redis Sentinel (3 instances) with data on local disk

Architecture:
```
Redis Sentinel (3 instances)
├── Primary (node A) — local PVC, RDB + AOF persistence
├── Replica (node B) — local PVC
├── Replica (node C) — local PVC
└── Sentinel monitors (3) — automatic failover
```

Resource overhead: ~1.5GB RAM total, ~2GB local disk per node

### Component 4: Immich PostgreSQL

**Current**: Dedicated PostgreSQL + pgvector on NFS
**Target**: Migrate to CloudNativePG cluster (separate database in same cluster, or dedicated cluster with pgvector extension)

### Component 5: ClickHouse HA (Rybbit)

**Current**: Single ClickHouse on NFS (`/mnt/main/clickhouse`)
**Target**: ClickHouse with native replication via ClickHouse Keeper, or accept risk (analytics data, rebuildable)

### Component 6: SQLite App Consolidation to PostgreSQL

Apps that support PostgreSQL — migrate to shared CloudNativePG cluster:

| App | Config mechanism | Priority |
|-----|-----------------|----------|
| Vaultwarden | `DATABASE_URL` env var | P0 (password vault) |
| Headscale | `db_type: postgres` in config | P0 (VPN) |
| Forgejo | `[database]` section in app.ini | P1 |
| Open WebUI | `DATABASE_URL` env var | P2 |
| Meshcentral | config.json `db` section | P2 |
| FreshRSS | `db` config | P2 |

Apps stuck on SQLite (accept risk or use Litestream for backup):

| App | Storage engine | Mitigation |
|-----|---------------|------------|
| Uptime Kuma | SQLite only | Litestream or accept |
| Navidrome | SQLite only | Litestream or accept |
| Audiobookshelf | SQLite only | Litestream or accept |
| Calibre-Web | SQLite (Calibre format) | Accept (format constraint) |
| Wealthfolio | SQLite only | Litestream or accept |
| Diun | BoltDB only | Accept (rebuildable state) |

### Component 7: Monitoring Stack

Prometheus, Loki, Alertmanager use specialized storage (TSDB, BoltDB).
Cannot migrate to PostgreSQL. Options:
- Move to local disk (emptyDir or local PVC)
- Accept NFS risk (metrics/logs are ephemeral, loss is annoying not catastrophic)
- Prometheus WAL is already on tmpfs (good)

Recommendation: Move to local PVCs. Losing metrics history on node
failure is acceptable for a homelab.

### Component 8: What Stays on NFS (unchanged)

All ~35 LOW risk services: media files, configs, caches, static content.
Immich photos, Jellyfin media, Audiobookshelf audiobooks, Calibre ebooks,
Frigate recordings, downloads, backups, model caches, etc.

NFS failure for these = temporary unavailability, not corruption.

## Backup Strategy

```
CloudNativePG     → continuous WAL archiving  → NFS:/mnt/main/postgresql-wal-archive/
MySQL (if kept)   → automated mysqldump       → NFS:/mnt/main/mysql-backup/
Redis Sentinel    → periodic RDB snapshots    → NFS:/mnt/main/redis-backup/
Litestream        → continuous SQLite backup   → NFS:/mnt/main/litestream/
Media/configs     → already on NFS

NFS (TrueNAS) → rsync → Backup NAS  (unchanged)
```

All backups still consolidate to TrueNAS. The rsync-to-backup-NAS
workflow is completely unchanged.

## Migration Order (Safety-First)

Each phase: backup → migrate → verify → user confirms → next phase.

### Phase 0: Infrastructure Prerequisites
- Install CloudNativePG operator
- Add local virtual disks to K8s nodes (via Proxmox)
- Set up local-path StorageClass
- Install Redis Sentinel

### Phase 1: PostgreSQL Migration (highest impact)
1. Full pg_dumpall backup to NFS
2. Deploy CloudNativePG cluster (empty)
3. Restore backup into CloudNativePG
4. Verify all 12 dependent services work
5. Decommission old PostgreSQL pod + NFS volume

### Phase 2: Redis Migration
1. RDB snapshot backup
2. Deploy Redis Sentinel cluster
3. Restore data
4. Update service connection strings
5. Verify all 11 dependent services

### Phase 3: Critical SQLite Apps → PostgreSQL
Migrate one at a time, verify after each:
3a. Vaultwarden (password vault — most critical)
3b. Headscale (VPN coordination)

### Phase 4: MySQL Migration
Either deploy MySQL Operator or migrate services to PostgreSQL.
One service at a time.

### Phase 5: Immich PostgreSQL
Migrate Immich's dedicated PostgreSQL to CloudNativePG.

### Phase 6: Remaining SQLite Apps → PostgreSQL
One at a time: Forgejo, Open WebUI, Meshcentral, FreshRSS

### Phase 7: Monitoring Stack
Move Prometheus, Loki, Alertmanager to local PVCs.

### Phase 8: ClickHouse + Remaining
ClickHouse replication or accept risk.
Litestream for SQLite-only apps (optional).

## Resource Budget

| Component | RAM | Local Disk |
|-----------|-----|-----------|
| CloudNativePG (3 instances) | ~3GB | ~50GB/node |
| Redis Sentinel (3 instances) | ~1.5GB | ~2GB/node |
| MySQL Operator (if kept) | ~2GB | ~20GB/node |
| Litestream (6 apps) | ~300MB | None |
| **Total new** | **~7GB** | **~72GB/node** |

Current cluster has 88GB RAM total. TrueNAS VM (16GB) could be
downsized since it no longer serves database workloads, partially
offsetting the new overhead.

## Success Criteria

- [ ] No database runs on NFS
- [ ] TrueNAS VM restart causes zero data corruption
- [ ] TrueNAS VM restart only affects media/config services (temporary unavailability)
- [ ] All backups still consolidate to TrueNAS for rsync to backup NAS
- [ ] Each migrated service verified working before proceeding to next
