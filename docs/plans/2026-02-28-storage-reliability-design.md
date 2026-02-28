# Storage Reliability: Database Replication + SQLite Consolidation

**Date**: 2026-02-28
**Status**: Revised (v2) — incorporates research agent findings
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

## Single-Host Limitation (Explicit Acknowledgment)

All K8s nodes are VMs on a single Proxmox host (192.168.1.127). This means:

**Replication PROTECTS against**: individual VM crash/restart, NFS outage,
individual node rebuild, pod OOM/eviction, software-level failures.

**Replication does NOT protect against**: Proxmox host failure, physical
disk failure, power loss — all replicas die simultaneously.

Given this, the plan uses **minimal replication** (1 primary + 1 replica
for PostgreSQL, single instance for Redis) rather than full 3-instance
clusters. The primary reliability gain comes from moving off NFS to local
disk with proper fsync semantics, not from replication count.

## Design

### Strategy Overview

```
BEFORE:  All services → NFS (TrueNAS VM) → single point of failure

AFTER:   Databases → local disk (proper fsync, no NFS SPOF)
         SQLite apps → migrated to shared PostgreSQL where supported
         Media/configs → NFS (TrueNAS, non-critical path)
         Backups → all consolidate to NFS → rsync to backup NAS
```

### Component 1: PostgreSQL via CloudNativePG

**Current**: Single PostgreSQL 16 pod on NFS (`/mnt/main/postgresql/data`)
using custom image `viktorbarzin/postgres:16-master` (postgis + pgvector + pgvecto-rs).

**Target**: CloudNativePG operator with 2-instance cluster on local disk.

CloudNativePG (CNCF project, v1.28+, supports K8s 1.34 and PG 14-18):
- Automatic primary/replica failover
- Streaming replication
- Declarative CRD-based management (Terraform/Terragrunt compatible)
- Built-in monolith import mode (better than manual pg_dumpall)
- Built-in PgBouncer pooler CRD

Architecture:
```
CloudNativePG Cluster (namespace: dbaas)
├── Primary (worker node A) — local PVC via local-path-provisioner
├── Replica (worker node B) — local PVC, streaming replication
└── Services: <cluster>-rw (read-write), <cluster>-ro (read-only)
```

**Migration approach**: Use CNPG's native monolith import mode, which
connects to the running old PostgreSQL and imports databases + roles
using pg_dump -Fd per database. Superior to manual pg_dumpall.

**Service endpoint strategy**: Create an ExternalName Service called
`postgresql` in namespace `dbaas` pointing to the CNPG `-rw` service.
This preserves `var.postgresql_host` = `postgresql.dbaas.svc.cluster.local`
with zero changes to dependent services.

**Special cases**:
- Authentik: Replace manual PgBouncer deployment with CNPG's built-in
  Pooler CRD, or update PgBouncer to point to CNPG's `-rw` service
- Init containers (woodpecker, trading-bot): Enable `enableSuperuserAccess: true`
  in CNPG Cluster spec — CNPG strips SUPERUSER from imported roles by default
- Custom image: Test `viktorbarzin/postgres:16-master` with CNPG first.
  Move `shared_preload_libraries=vectors.so` to CNPG `postgresql.parameters`
  (CNPG overrides container CMD). Tag format may need adjusting.

**Backup**: Keep existing pg_dumpall CronJob, pointed at new CNPG endpoint.
CNPG's native WAL archiving requires S3-compatible backend (not NFS) —
adding MinIO is a future enhancement, not a blocker.

Dependent services (12): authentik, n8n, dawarich, tandoor, linkwarden,
netbox, woodpecker, rybbit, affine, health, resume, trading-bot

Resource overhead: ~2GB RAM total (2 instances), ~50GB local disk per node

### Component 2: Redis — Single Instance on Local Disk

**Current**: Single redis-stack pod on NFS (`/mnt/main/redis`).
RDB background save takes 39 seconds on NFS (should be <1s on local disk).

**Finding**: redis-stack modules (RedisJSON, RediSearch, RedisTimeSeries,
RedisBloom, RedisGears) are completely unused. Zero module commands in
`INFO commandstats`. All 11 services use plain Redis commands only
(GET, SET, BullMQ queues, Celery broker, caching).

**Finding**: No service stores critical primary data in Redis. All use it
for job queues and caching. Losing Redis data means: users re-login,
jobs retry, caches rebuild. Inconvenient but never catastrophic.

**Finding**: None of the 11 services support Sentinel-aware connections.
Redis Sentinel would require a proxy layer with no reliability gain on
a single physical host.

**Target**: Single `redis:7-alpine` (or `valkey:9`) on local PVC.
Drop redis-stack — modules are unused overhead (~100MB RAM saved).

Architecture:
```
Redis 7 (single instance)
├── Local PVC via local-path-provisioner (fast RDB saves)
├── K8s Service: redis.redis.svc.cluster.local (unchanged)
└── Hourly CronJob: cp dump.rdb → NFS:/mnt/main/redis-backup/
```

No client changes needed. Same service endpoint. Same Redis commands.

Resource overhead: ~650MB RAM (same as today minus module overhead),
~1GB local disk

### Component 3: MySQL — Single Instance on Local Disk

**Current**: Single MySQL pod on NFS (`/mnt/main/mysql`)
**Target**: Single MySQL on local PVC

Services on MySQL (8): hackmd, speedtest, onlyoffice, crowdsec,
paperless-ngx, real-estate-crawler, url-shortener, grafana

Evaluate per-service whether migration to PostgreSQL is feasible
(reduces operational complexity to one DB engine). Do during
implementation research phase.

**Backup**: Keep existing mysqldump CronJob.

### Component 4: Immich PostgreSQL

**Current**: Dedicated PostgreSQL + pgvector on NFS
(`ghcr.io/immich-app/postgres:15-vectorchord0.3.0-pgvectors0.2.0`)

**Target**: Move to local PVC (same image, same single instance).
Immich's PG has specialized extensions (VectorChord, pgvectors) that
may not be compatible with CNPG operand images. Simpler to keep as
standalone PG on local disk.

### Component 5: ClickHouse (Rybbit)

**Current**: Single ClickHouse on NFS (`/mnt/main/clickhouse`)
**Target**: Move to local PVC (single instance). Analytics data is
rebuildable. ClickHouse replication is not justified for a homelab.

### Component 6: SQLite App Consolidation to PostgreSQL

**REVISED based on per-app research:**

Apps confirmed safe to migrate:

| App | Config mechanism | Migration tool | Risk | Notes |
|-----|-----------------|---------------|------|-------|
| Forgejo | `[database]` in app.ini | `forgejo dump --database postgres` | Moderate | Git repos stay on NFS |
| FreshRSS | `DB_HOST` env vars | OPML export/import (fresh install) | Low | PG is the recommended backend |
| Open WebUI | `DATABASE_URL` env var | None (start fresh) | Low | Chat history is disposable |

**Apps REMOVED from migration plan:**

| App | Reason |
|-----|--------|
| **Headscale** | Project EXPLICITLY DISCOURAGES PostgreSQL: "highly discouraged, only supported for legacy reasons. All new development and testing are SQLite." Migrating risks VPN stability. |
| **MeshCentral** | Uses NeDB (document store), not SQLite. NeDB→PG migration path is poorly documented and risky. |

Apps confirmed SQLite/BoltDB-only (stay on NFS):

| App | Storage engine | Mitigation |
|-----|---------------|------------|
| Headscale | SQLite (recommended by project) | Accept (project-recommended config) |
| Vaultwarden | SQLite | Defer (migration too risky for password vault) |
| Uptime Kuma | SQLite (v2 adds MariaDB, not PG) | Accept or Litestream |
| Navidrome | SQLite only | Accept or Litestream |
| Audiobookshelf | SQLite only | Accept or Litestream |
| Calibre-Web | SQLite (Calibre format) | Accept (format constraint) |
| Wealthfolio | SQLite only | Accept or Litestream |
| MeshCentral | NeDB (document store) | Accept |
| Diun | bbolt (BoltDB fork) | Accept (rebuildable state) |

### Component 7: Monitoring Stack

Prometheus, Loki, Alertmanager use specialized storage (TSDB, BoltDB).
Cannot migrate to PostgreSQL. Prometheus WAL is already on tmpfs (good).

Recommendation: Move to local PVCs. Losing metrics history on node
failure is acceptable for a homelab.

### Component 8: What Stays on NFS (unchanged)

All ~35 LOW risk services: media files, configs, caches, static content.
Immich photos, Jellyfin media, Audiobookshelf audiobooks, Calibre ebooks,
Frigate recordings, downloads, backups, model caches, etc.

NFS failure for these = temporary unavailability, not corruption.

## Backup Strategy

```
CNPG PostgreSQL  → pg_dumpall CronJob (daily) → NFS:/mnt/main/postgresql-backup/
MySQL            → mysqldump CronJob (daily)  → NFS:/mnt/main/mysql-backup/
Redis            → RDB copy CronJob (hourly)  → NFS:/mnt/main/redis-backup/
Immich PG        → pg_dump CronJob (daily)    → NFS:/mnt/main/immich-pg-backup/
Litestream       → continuous SQLite backup   → NFS:/mnt/main/litestream/ (optional)
Media/configs    → already on NFS

NFS (TrueNAS) → rsync → Backup NAS  (unchanged)
```

All backups still consolidate to TrueNAS. Rsync-to-backup-NAS workflow
is completely unchanged.

**Note**: CNPG's native WAL archiving requires S3-compatible storage
(not NFS). Adding MinIO for PITR capability is a future enhancement.
The pg_dumpall CronJob provides adequate backup for a homelab.

## Migration Order (Safety-First)

Each phase: research → backup → migrate → verify → user confirms → next.

Before each service migration, a research subagent will:
1. Confirm current setup and configuration
2. Research online best practices and documentation
3. Scrutinize the migration plan for that specific service
4. Present findings for review before execution

### Phase 0: Infrastructure Prerequisites
- Verify RAM headroom (current overcommit must be addressed first)
- Add dedicated local virtual disks to K8s worker nodes (via Proxmox)
- Verify local-path-provisioner is configured for new disks
- Install CloudNativePG operator (Helm)
- Test CNPG with custom PostgreSQL image (throwaway cluster)

### Phase 1: PostgreSQL Migration (highest impact, most preparation)
1. Deploy throwaway CNPG cluster to test image compatibility and import
2. Full pg_dumpall backup to NFS
3. Deploy production CNPG cluster with monolith import from running PG
4. Create ExternalName Service for backwards compatibility
5. Migrate ONE low-risk service first (e.g., `resume` or `health`)
6. Verify for 24-48 hours
7. Migrate remaining services one at a time, verify each
8. Migrate authentik LAST (identity provider — highest blast radius)
9. Keep old PG pod scaled to 0 for one week as rollback safety net
10. Decommission old PG only after stability confirmed

### Phase 2: Redis Migration
1. RDB snapshot backup to NFS
2. Deploy single redis:7-alpine on local PVC (same namespace, new pod)
3. Restore RDB snapshot
4. Update redis Service to point to new pod
5. Verify all 11 dependent services
6. Add hourly RDB backup CronJob to NFS
7. Decommission old redis-stack pod

### Phase 3: MySQL Migration
1. mysqldump backup
2. Deploy single MySQL on local PVC
3. Restore dump
4. Verify all 8 dependent services
5. Research per-service PostgreSQL migration feasibility (future work)

### Phase 4: Immich PostgreSQL
1. pg_dump backup
2. Move Immich PG to local PVC (same image, same config)
3. Verify Immich functionality (upload, search, face recognition)

### Phase 5: SQLite Apps → PostgreSQL
Migrate one at a time, safest first:
5a. FreshRSS (lowest risk — fresh install with OPML import)
5b. Open WebUI (low risk — start fresh, chat history disposable)
5c. Forgejo (moderate risk — use forgejo dump, verify git operations)

### Phase 6: ClickHouse + Monitoring
6a. ClickHouse → local PVC
6b. Prometheus → local PVC
6c. Loki → local PVC
6d. Alertmanager → local PVC

### Phase 7: Cleanup + Optional Enhancements
- Remove old NFS directories from nfs_directories.txt
- Update nfs_exports.sh
- Optional: Add Litestream for SQLite-only apps
- Optional: Add MinIO for CNPG WAL archiving (PITR capability)
- Optional: Evaluate MySQL→PostgreSQL consolidation

## Rollback Plan (per component)

**PostgreSQL**: Old pod kept scaled to 0 with NFS data intact. Rollback =
scale old pod back up, revert ExternalName Service. Pre-migration
pg_dumpall available if NFS data is stale.

**Redis**: Old redis-stack pod kept scaled to 0. Rollback = scale up,
revert Service. Pre-migration RDB snapshot on NFS.

**MySQL**: Same pattern — old pod scaled to 0, mysqldump on NFS.

**SQLite apps**: Original SQLite databases remain on NFS untouched.
Rollback = remove DATABASE_URL env var, restart pod.

## Resource Budget

| Component | RAM | Local Disk |
|-----------|-----|-----------|
| CloudNativePG (2 instances) | ~2GB | ~50GB/node (2 nodes) |
| Redis 7 (single instance) | ~550MB | ~1GB |
| MySQL (single instance) | ~1GB | ~20GB |
| Immich PG (single instance) | ~500MB | ~10GB |
| CNPG Operator | ~200MB | None |
| **Total new overhead** | **~4.25GB** | **~81GB across 2 nodes** |

**RAM WARNING**: Proxmox host has 142GB physical RAM with ~156GB
allocated to running VMs (already ~10% overcommitted). This plan adds
~4.25GB but also frees ~1.5GB by dropping redis-stack modules and
removing old DB pods. Net increase: ~2.75GB. The old DB pods
(postgresql, mysql, redis-stack on NFS) will be decommissioned,
partially offsetting the new resource usage. Monitor swap usage closely.

Consider stopping unused VMs (PBS is already stopped, Windows10 uses
8GB and may not need to run continuously).

## Monitoring Additions

After migration, add alerts for:
- CNPG replication lag
- CNPG instance count (< 2 = degraded)
- Local disk space on `/opt/local-path-provisioner` per node
- Redis RDB save failures
- Backup CronJob failures (pg_dumpall, mysqldump, RDB copy)

## Success Criteria

- [ ] PostgreSQL, MySQL, Redis, Immich PG, ClickHouse all on local disk
- [ ] TrueNAS VM restart causes zero data corruption
- [ ] TrueNAS VM restart only affects media/config services (temporary unavailability)
- [ ] All backups still consolidate to TrueNAS for rsync to backup NAS
- [ ] Each migrated service verified working before proceeding to next
- [ ] Rollback tested for PostgreSQL before decommissioning old pod
