---
name: clickhouse-k8s-nfs-system-log-bloat
description: |
  Fix for ClickHouse consuming excessive CPU (500m-1000m+) on Kubernetes when running on
  NFS storage, caused by unbounded system log table growth triggering continuous background
  merges. Use when: (1) ClickHouse burns ~1 CPU core with no active user queries,
  (2) system.merges shows constant merge activity on system.metric_log or system.trace_log,
  (3) system log tables (metric_log, trace_log, text_log, asynchronous_metric_log) have
  grown to gigabytes while actual user data is tiny, (4) ClickHouse crashes with exit code
  76 (loadOutdatedDataParts SIGSEGV), (5) attempting to mount custom config.d XML via
  Kubernetes ConfigMap causes exit code 36 (BAD_ARGUMENTS) crashes. Also covers why
  ClickHouse's MergeTree engine performs poorly on NFS and the CronJob workaround for
  system log truncation.
author: Claude Code
version: 1.0.0
date: 2026-03-01
---

# ClickHouse on Kubernetes/NFS: System Log Bloat & CPU Overhead

## Problem

ClickHouse deployed on Kubernetes with NFS storage consumes ~1 CPU core continuously,
even when actual user queries are negligible. The CPU is consumed by background merge
operations on system log tables that grow unboundedly with no default TTL.

## Context / Trigger Conditions

- ClickHouse pod using 500m-1000m+ CPU with no active user queries
- `SELECT * FROM system.processes` shows only diagnostic queries
- `SELECT * FROM system.merges` shows constant merge activity on `system.metric_log`
- System log tables have grown to gigabytes:
  - `system.trace_log`: 5+ GiB, 200M+ rows
  - `system.text_log`: 3+ GiB, 90M+ rows
  - `system.metric_log`: 1+ GiB with 80-100+ active parts (healthy is <20)
  - `system.asynchronous_metric_log`: 500+ MiB, 1B+ rows
- Actual user data (e.g., `clickhouse.events`) is only kilobytes
- ClickHouse crashes periodically with exit code 76 (`loadOutdatedDataParts` SIGSEGV)
- Data directory is on NFS (e.g., `/mnt/main/clickhouse`)

## Root Cause

Two compounding issues:

1. **No TTL on system log tables**: ClickHouse system tables (`metric_log`, `trace_log`,
   `text_log`, `asynchronous_metric_log`, `query_log`, `part_log`) have no default
   retention policy and grow indefinitely.

2. **NFS amplifies merge overhead**: ClickHouse's MergeTree engine relies on background
   merge operations that involve heavy sequential I/O. NFS latency makes merges 10-100x
   slower than local disk, creating a feedback loop:
   - Slow merges → parts accumulate faster than they can be merged
   - More parts → more merge operations spawned
   - More merges → more CPU for decompression/recompression while waiting on NFS I/O

## Solution

### Immediate Fix: Truncate System Tables

```bash
CH_POD=$(kubectl get pod -n <namespace> -l app=clickhouse -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.metric_log"
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.trace_log"
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.text_log"
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.asynchronous_metric_log"
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.query_log"
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query "TRUNCATE TABLE IF EXISTS system.part_log"
```

This can take 30-60+ seconds per table on NFS due to part cleanup I/O.

### Permanent Fix: CronJob for Periodic Truncation

Add a Kubernetes CronJob that truncates system tables via the ClickHouse HTTP API:

```hcl
resource "kubernetes_cron_job_v1" "clickhouse_truncate_logs" {
  metadata {
    name      = "clickhouse-truncate-logs"
    namespace = "<namespace>"
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "truncate"
              image = "curlimages/curl:8.12.1"
              command = ["sh", "-c", join(" && ", [
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.metric_log'",
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.trace_log'",
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.text_log'",
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.asynchronous_metric_log'",
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.query_log'",
                "curl -s 'http://clickhouse.<ns>.svc.cluster.local:8123/?user=default&password=<pw>' -d 'TRUNCATE TABLE IF EXISTS system.part_log'",
                "echo 'System logs truncated'"
              ])]
            }
          }
        }
      }
    }
  }
}
```

### What Does NOT Work: Config.d XML Mount

**DO NOT** attempt to mount custom XML config files into `/etc/clickhouse-server/config.d/`
via Kubernetes ConfigMap. Both approaches crash ClickHouse with exit code 36 (BAD_ARGUMENTS):

- **Full directory mount** (`mount_path = "/etc/clickhouse-server/config.d"`): Replaces
  the entire directory, deleting the built-in `docker_related_config.xml` that the
  entrypoint expects. Even if you include it in your ConfigMap, ClickHouse still crashes.

- **sub_path mount** (`sub_path = "custom.xml"`): Also crashes with exit code 36, even
  with minimal valid XML containing only `<background_pool_size>4</background_pool_size>`.

- Both `remove="1"` (to disable tables) and `<ttl>` (to set retention) config overrides
  crash with exit code 36.

This appears to be an issue with the `clickhouse/clickhouse-server:25.4.2` Docker image
and how it preprocesses config at startup. The CronJob approach bypasses this entirely.

## Verification

After truncation, verify:

```bash
# CPU should drop from ~900m to ~100m within minutes
kubectl top pod -n <namespace> -l app=clickhouse

# No active merges
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query \
  "SELECT count() FROM system.merges"

# System tables should be small
kubectl exec -n <namespace> $CH_POD -- clickhouse-client --query \
  "SELECT database, table, formatReadableSize(sum(bytes_on_disk)) as size, sum(rows) as rows \
   FROM system.parts WHERE active GROUP BY database, table ORDER BY sum(bytes_on_disk) DESC \
   FORMAT Pretty"
```

## Diagnostic Commands

```bash
# Check what's consuming CPU (merges vs queries)
kubectl exec -n <ns> $CH_POD -- clickhouse-client --query \
  "SELECT * FROM system.merges FORMAT Pretty"

kubectl exec -n <ns> $CH_POD -- clickhouse-client --query \
  "SELECT query_id, elapsed, query FROM system.processes WHERE is_initial_query FORMAT Pretty"

# Check background pool config
kubectl exec -n <ns> $CH_POD -- clickhouse-client --query \
  "SELECT name, value FROM system.server_settings \
   WHERE name IN ('background_pool_size', 'background_merges_mutations_concurrency_ratio') \
   FORMAT Pretty"

# Default is background_pool_size=16, concurrency_ratio=2 → up to 32 concurrent merges
```

## Notes

- **Exit code 76**: ClickHouse crashes in `loadOutdatedDataParts()` when there are hundreds
  of outdated parts on NFS. The truncation CronJob prevents this by keeping tables small.

- **Exit code 36**: `BAD_ARGUMENTS` in ClickHouse. Triggered by config.d XML mounts in
  Kubernetes. Root cause unclear but reproducible across mount methods.

- **Default thread pools**: ClickHouse defaults to `background_pool_size=16` and
  `background_schedule_pool_size=512`, spawning 700+ threads even for a single-table
  workload. This overhead is unavoidable without config file changes.

- **NFS is fundamentally unsuitable** for ClickHouse's MergeTree engine. If data
  persistence is not critical (e.g., analytics data is small), consider `emptyDir` or
  local PV storage instead.

## See Also

- `k8s-nfs-mount-troubleshooting` — NFS mount failures and permission issues
- `k8s-limitrange-oom-silent-kill` — LimitRange defaults causing OOM in ClickHouse containers
