# Cluster Hardening Design

**Date**: 2026-03-03
**Status**: Approved
**Scope**: Service availability, failure detection, DNS HA

## Context

Reliability audit identified gaps in failure detection (most services lack health probes), NFS monitoring (backbone for 70+ services has no dedicated alerting), and DNS high availability (AXFR-based secondary doesn't sync settings/blocklists).

## Decisions

- No PDBs for now — revisit when adding more replicas
- No NetworkPolicies in this phase — covered by security observability design
- Replicate only critical infra (DNS); apps stay at 1 replica
- Keep databases on NFS; harden via monitoring, not migration
- Backup/DR items (MinIO, rsync, PBS, runbooks) deferred to a separate effort

## Items

### 1. etcd Backup Alerts — DONE

- `EtcdBackupStale`: fires critical if last successful backup > 36h
- `EtcdBackupNeverSucceeded`: fires critical if backup has never completed
- etcd backup image updated to `registry.k8s.io/etcd:3.6.5-0` (matches cluster)
- Applied 2026-03-03

### 2. Liveness & Readiness Probes

Add HTTP probes to Terraform-managed deployments. Conservative timing to avoid spamming:
- `periodSeconds: 30`
- `failureThreshold: 5` (150s before restart)
- `initialDelaySeconds: 15`
- `timeoutSeconds: 5`

Use known health endpoints where available, fall back to `GET /` on container port.
Start with tier-0/tier-1 services, then extend to tier-3/tier-4.

### 3. NFS Health Monitoring

- **Prometheus alert**: `NFSServerDown` via blackbox exporter TCP probe on `10.0.10.15:2049`, fires critical after 2 minutes
- **Uptime Kuma**: TCP monitor on `10.0.10.15:2049`

### 4. Technitium DNS Clustering

Migrate from AXFR zone transfers to Technitium's built-in clustering:

**Architecture change**:
- Convert primary + secondary Deployments → single StatefulSet with 2 replicas
- Add headless Service for stable pod DNS names
- Separate NFS volumes per replica (existing pattern preserved)

**Clustering setup**:
- Cluster domain: `dns.viktorbarzin.lan` (permanent)
- Pod-0: primary (`/api/admin/cluster/init`)
- Pod-1: secondary (`/api/admin/cluster/initJoin`)
- HTTPS auto-enabled with self-signed certs (internal only)
- One-shot setup Job after StatefulSet is running

**What clustering syncs** (vs AXFR which only syncs zone records):
- Zones (via catalog zone — auto-syncs new zones)
- Blocklists and allowed lists
- DNS applications and their configs
- Users, groups, permissions, API tokens
- Settings

**Requires maintenance window**: brief DNS outage during StatefulSet migration.

## Implementation Order

1. NFS health monitoring (low effort, no disruption)
2. Health probes (medium effort, rolling restarts)
3. Technitium clustering (high effort, requires maintenance window)
