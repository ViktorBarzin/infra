# Centralized Log Collection Design

## Date: 2026-02-13

## Goal

Centrally collect logs from all Kubernetes pods for monitoring and alerting. Minimize disk I/O by holding logs in memory for extended periods, flushing to NFS once daily. Alert on log patterns via existing Alertmanager pipeline.

## Requirements

- **Primary use case**: Monitoring and alerting (log-based alert rules evaluated in real-time)
- **Retention**: 7 days on disk after flush
- **Memory budget**: 4-8GB total (~6.6GB used)
- **Disk strategy**: 24h in-memory chunks, WAL on tmpfs, single daily flush to NFS
- **Crash policy**: Accept up to 24h log loss on pod/node crash (alerts still fire in real-time before flush)
- **Alert delivery**: Loki Ruler -> existing Alertmanager -> Slack/email

## Architecture

```
┌──────────────────┐     ┌──────────────────────┐     ┌──────────────┐
│ Alloy DaemonSet  │     │ Loki SingleBinary     │     │ Grafana       │
│ 5 pods, 128Mi ea │────>│ 1 pod, 6Gi RAM        │<────│ (existing)    │
│ tails /var/log/  │     │                        │     │ + Loki        │
│ pods on each node│     │ Ingester: 24h chunks   │     │   datasource  │
└──────────────────┘     │ WAL: tmpfs (in-memory) │     └──────────────┘
                         │ Storage: NFS 15Gi      │
┌──────────────────┐     │ Ruler ──> Alertmanager │
│ Sysctl DaemonSet │     └──────────────────────┘
│ 5 pods (pause)   │
│ sets inotify     │
│ limits on nodes  │
└──────────────────┘
```

## Components

### 1. Sysctl DaemonSet

Solves the `too many open files` / fsnotify watcher exhaustion problem that previously blocked Alloy.

- Privileged init container runs `sysctl -w` on each node
- Settings: `fs.inotify.max_user_watches=1048576`, `fs.inotify.max_user_instances=512`, `fs.inotify.max_queued_events=1048576`
- Main container: `pause` image (near-zero resources)
- Survives node reboots (DaemonSet recreates pod)
- Namespace: `monitoring`

### 2. Loki (Helm Release)

Single-binary deployment. Existing Helm chart config in `loki.yaml`, updated with:

**Ingester tuning (disk-friendly):**
- `chunk_idle_period: 12h` — don't flush idle streams quickly
- `max_chunk_age: 24h` — hold chunks in memory for full day
- `chunk_retain_period: 1m` — brief retain after flush
- `chunk_target_size: 1572864` (1.5MB) — larger chunks = fewer writes
- WAL: tmpfs emptyDir (`medium: Memory`, 2Gi limit)

**Retention:**
- `retention_period: 168h` (7 days)
- Compactor enabled for retention enforcement

**Ruler:**
- Evaluates LogQL alert rules in real-time (before chunk flush)
- Fires to `http://prometheus-alertmanager.monitoring.svc.cluster.local:9093`

**Storage:**
- NFS PV/PVC at `/mnt/main/loki/loki` (15Gi, existing)
- TSDB index with 24h period

**Resources:**
- Memory: 6Gi limit
- CPU: 1 limit

### 3. Alloy (Helm Release)

DaemonSet log collector. Existing config in `alloy.yaml` is complete:
- Discovers pods via `discovery.kubernetes`
- Labels: namespace, pod, container, app, job, container_runtime, cluster
- Tails `/var/log/pods/` on each node
- Forwards to `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`

**Resources per pod:**
- Memory: 128Mi limit
- CPU: 200m limit

### 4. Grafana Datasource

ConfigMap with label `grafana_datasource: "1"` for sidecar auto-discovery:
- Name: Loki
- Type: loki
- URL: `http://loki.monitoring.svc.cluster.local:3100`
- Existing `loki.json` dashboard already in dashboards directory

### 5. Starter Alert Rules

Configured in Loki Ruler (evaluated in real-time, before disk flush):

| Alert | LogQL Expression | Severity |
|-------|-----------------|----------|
| HighErrorRate | `sum(rate({namespace=~".+"} \|= "error" [5m])) by (namespace) > 10` | warning |
| PodCrashLoopBackOff | `count_over_time({namespace=~".+"} \|= "CrashLoopBackOff" [5m]) > 0` | critical |
| OOMKilled | `count_over_time({namespace=~".+"} \|= "OOMKilled" [5m]) > 0` | critical |

## Memory Budget

| Component | Per-pod | Pods | Total |
|-----------|---------|------|-------|
| Alloy | 128Mi | 5 | 640Mi |
| Loki | 6Gi | 1 | 6Gi |
| Sysctl DS | ~0 (pause) | 5 | ~0 |
| **Total** | | | **~6.6 GB** |

## Files to Change

| File | Action |
|------|--------|
| `modules/kubernetes/monitoring/loki.tf` | Uncomment Loki + Alloy helm releases, add sysctl DaemonSet, add Grafana Loki datasource ConfigMap |
| `modules/kubernetes/monitoring/loki.yaml` | Update with ingester tuning, ruler config, retention, resource limits |
| `modules/kubernetes/monitoring/alloy.yaml` | Add resource limits in Helm values wrapper |
| `secrets/nfs_directories.txt` | Ensure `/mnt/main/loki` entries exist |

## Implementation Steps

1. Add sysctl DaemonSet to `loki.tf`
2. Update `loki.yaml` with disk-friendly tuning, ruler, retention, resources
3. Update `alloy.yaml` with resource limits
4. Uncomment Loki Helm release in `loki.tf`, wire up NFS PV/PVC
5. Uncomment Alloy Helm release in `loki.tf`
6. Add Grafana Loki datasource ConfigMap to `loki.tf`
7. Add alert rules to Loki config
8. Ensure NFS exports exist in `secrets/nfs_directories.txt`
9. `terraform apply -target=module.kubernetes_cluster.module.monitoring`
10. Verify: Grafana Explore -> Loki datasource -> query `{namespace="monitoring"}`

## Risks

- **24h data loss on crash**: Accepted trade-off. Alerts fire in real-time before flush, so alert coverage is not affected — only historical log browsing is at risk.
- **Memory pressure**: 6Gi for Loki on a 16GB node is significant. Monitor with existing Prometheus memory alerts.
- **Log volume spikes**: A chatty pod could cause Loki to OOM. Alloy can be configured with rate limiting if needed (future enhancement).
