# Post-Mortem: NFS CSI Cascade Failure

| Field | Value |
|-------|-------|
| **Date** | 2026-03-16 |
| **Duration** | ~47h (ongoing) |
| **Severity** | SEV1 |
| **Affected Services** | 40+ pods across 20+ namespaces |
| **Status** | Draft |

## Summary

The NFS CSI driver entered a crash-loop due to a liveness-probe port conflict (~47h ago), causing all NFS-backed PV mounts to fail. This cascaded into 15+ pods stuck in ContainerCreating, MySQL InnoDB data file lock failures, Vault Raft storage timeouts, and MetalLB speaker port conflicts. Critical path services (Traefik, PostgreSQL) remained partially operational.

## Impact

- **User-facing**: Services dependent on NFS storage (calibre, forgejo, pgadmin, uptime-kuma, etc.) completely unavailable. Grafana down (MySQL dependency). Vault unavailable.
- **Services affected**: 40+ pods across 20+ namespaces — storage layer, databases, monitoring, CI/CD
- **Duration**: ~47h and ongoing at time of investigation
- **Data loss**: None confirmed; MySQL ibdata1 lock issue may indicate risk if not resolved cleanly

## Timeline (UTC)

| Time | Event | Source |
|------|-------|--------|
| ~47h ago | NFS CSI driver starts crash-looping — liveness-probe port 29653 conflict | cluster-health-checker (pod age + restart count) |
| ~30h ago | iSCSI CSI controller deployed (stable) | pod age |
| ~27h ago | Vault, MySQL, Headscale, Woodpecker, CrowdSec agents start failing | pod ages, events |
| ~26h ago | mysql-cluster-0 enters ContainerStatusUnknown | sre investigation |
| ~20-22h ago | Cascade of service restarts across cluster | pod restart timestamps |
| ~1h ago | Latest wave of pod rescheduling/restarts | events |

## Root Cause

**NFS CSI driver liveness-probe port conflict**: The liveness-probe containers on all worker nodes fail with `listen tcp 127.0.0.1:29653: bind: address already in use`. The port conflict suggests a previous liveness-probe process did not cleanly terminate, or pods were restarted while old processes lingered in the network namespace.

**Impact chain**: NFS CSI not registered on nodes → all NFS PV mounts fail → 15+ pods stuck in ContainerCreating with "driver name nfs.csi.k8s.io not found in the list of registered CSI drivers"

## Contributing Factors

- **MySQL InnoDB data corruption**: Cannot open `ibdata1` (OS error 11 — EAGAIN). Likely caused by NFS storage instability or stale lock from mysql-cluster-0 in ContainerStatusUnknown
- **Vault Raft lock timeout**: vault-0 fails with "failed to open bolt file: timeout" — BoltDB locked by previous instance. vault-2 cannot mount NFS volume at all
- **MetalLB speaker port conflicts**: 3/4 speakers fail with memberlist port 7946 already in use — same pattern as NFS CSI, suggesting containerd instability ~47h ago
- **Node3 memory pressure**: 80% utilization, hosting both mysql-cluster-1 and mysql-cluster-2

## Detection

- **How detected**: Manual investigation (this post-mortem)
- **Time to detect**: ~47h from start of NFS CSI crash-loop
- **Gap analysis**: No alerting on CSI driver health. Existing pod alerts likely firing but root cause (CSI driver) not surfaced. Need CSI-specific health alerts.

## Resolution

Not yet resolved at time of investigation. Recommended steps:

1. Delete NFS CSI node pods one at a time (DaemonSet will recreate with clean port allocation)
2. Delete MetalLB crash-looping speaker pods (same approach)
3. Force-delete mysql-cluster-0 (ContainerStatusUnknown) to release ibdata1 lock
4. Once NFS healthy, vault-2 should start; vault-0 may need BoltDB lock file cleared

## Action Items

### Preventive (stop recurrence)

| Priority | Action | Type | Details |
|----------|--------|------|---------|
| P1 | Investigate containerd health on worker nodes | Investigation | Port conflicts across NFS CSI + MetalLB suggest containerd restart/instability ~47h ago |
| P1 | Fix NFS CSI liveness probe port allocation | Config | Use ephemeral ports or add port uniqueness checks to avoid stale port conflicts |
| P2 | Add node anti-affinity for MySQL replicas | Terraform | mysql-cluster-1 and -2 both on node3 (80% memory) — spread across nodes |

### Detective (catch faster)

| Priority | Action | Type | Details |
|----------|--------|------|---------|
| P1 | Add CSI driver health alerting | Alert | PrometheusRule for CSI driver pod crash-loops — `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace="democratic-csi"}` |
| P1 | Add NFS mount failure alerting | Alert | Alert on pods stuck in ContainerCreating > 10min with volume mount errors |
| P2 | Add Uptime Kuma monitor for Vault | Monitor | Vault health endpoint check |

### Mitigative (reduce blast radius)

| Priority | Action | Type | Details |
|----------|--------|------|---------|
| P2 | Add PDB for NFS CSI node DaemonSet | Config | Ensure at least N-1 nodes always have healthy CSI driver |
| P2 | Document NFS CSI recovery runbook | Runbook | Steps to recover from port conflict scenario |
| P3 | Evaluate moving MySQL off NFS to iSCSI | Architecture | iSCSI remained stable throughout; MySQL on NFS is fragile |

## Lessons Learned

- **Went well**: Critical path services (Traefik 3/3, Authentik 2/3, PostgreSQL) survived due to not depending on NFS CSI
- **Went poorly**: 47h detection gap — no alerting on CSI driver health despite it being a single point of failure for all NFS workloads
- **Got lucky**: iSCSI CSI remained stable, keeping PostgreSQL (CNPG) operational. If both CSI drivers had failed, the entire cluster would have been fully down

## Raw Investigation Data

<details>
<summary>Cluster State Summary</summary>

- **Nodes**: All 5 Ready. k8s-node2 metrics `<unknown>`. k8s-node3 at 80% memory.
- **Tier 1 (Critical)**: Traefik OK (3/3), Authentik degraded (2/3), PostgreSQL degraded (1/2), Vault DOWN, Redis starting, MetalLB degraded (1/4)
- **Tier 2 (Storage)**: NFS CSI FAILING (port conflict on all workers), iSCSI CSI OK
- **Tier 3 (Apps)**: 15+ ContainerCreating (NFS), 5+ Pending (GPU/memory), 10+ CrashLoopBackOff (DB deps)
- **Tier 4 (Databases)**: PostgreSQL recovering, MySQL DOWN (ibdata1 lock)

</details>

<details>
<summary>NFS CSI Error Details</summary>

Controller pods (2): CrashLoopBackOff — `listen tcp 127.0.0.1:29653: bind: address already in use`
Node DaemonSet: 4/5 crash-looping (same error). Only k8s-master healthy.
Age: ~47h with 96+ restarts.

</details>

<details>
<summary>MySQL Error Details</summary>

mysql-cluster-0: ContainerStatusUnknown
mysql-cluster-1, mysql-cluster-2: CrashLoopBackOff — `Cannot open datafile './ibdata1'` (OS error 11: Resource temporarily unavailable)
mysql-cluster-router: crash-looping (no healthy backend)

</details>

<details>
<summary>Vault Error Details</summary>

vault-0: CrashLoopBackOff — "failed to open bolt file: timeout" (Raft BoltDB lock)
vault-2: ContainerCreating — NFS mount failure

</details>
