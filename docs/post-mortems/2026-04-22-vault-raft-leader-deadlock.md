# Post-Mortem: Vault Raft Leader Deadlock + NFS Kernel Client Corruption Cascade

| Field | Value |
|-------|-------|
| **Date** | 2026-04-22 |
| **Duration** | External endpoint 503 from ~09:00 UTC to 11:03 UTC (~2h). Full cluster recovery ~12:30 UTC after node4 reboot. |
| **Severity** | SEV1 (Vault — single source of secrets for 40+ services) |
| **Affected Services** | All ESO-backed services (password rotation paused). CronJobs that read plan-time secrets (14 stacks). Woodpecker CI (blocked pipeline `d39770b3`). Everything with `ExternalSecret` refresh interval ≤ 2h. |
| **Status** | Resolved for user traffic; vault-0 pod replacement pending node4 reboot. Terraform not yet reapplied. |

## Summary

A Vault raft leader (`vault-2`) entered a stuck goroutine state where its cluster port (8201) accepted TCP but never completed msgpack RPC. Standbys could not detect leader death because the TCP layer looked healthy, so no re-election fired. The only recovery was to kill the leader. During recovery, abrupt `kubectl delete --force` of the stuck Vault pods left kernel-side NFS client state on k8s-node1/node3/node4 in a corrupted state — **all new NFS mounts from those nodes timed out at 110s**, while existing mounts kept working. This created a cascade: the stuck leader blocked quorum, killing the leader broke NFS on the destination node for the recreated pod, force-killing the stuck pods left zombie `containerd-shim` processes kubelet couldn't clean up, and the resulting volume-manager loops pegged kubelet into 2-minute timeouts. Recovery required a VM hard-reset for node2 and node3 (kubelet was zombie on both). vault-0 remains down pending node4 reboot.

## Impact

- **User-facing**: `vault.viktorbarzin.me` returned HTTP 503 for ~2h. Any service that needed a Vault token during that window was degraded; Woodpecker CI pipeline blocked.
- **Blast radius**: 3/3 Vault pods affected (raft deadlock blocked re-election even with standbys up). Three k8s nodes degraded simultaneously with kernel NFS client stuck state (node1, node3, node4). Two nodes required VM hard-reset to recover kubelet (node2, node3).
- **Duration**: Degraded ~2h; resolution required sequential hard reboots.
- **Data loss**: None. Raft data integrity preserved on NFS. vault-1 came up with index 2475732, caught up to 2476009+ once leader was elected.
- **Observability gap**: No alert fired for the stuck raft leader. Standbys report `HA Mode: standby, Active Node Address: <leader IP>` as if healthy even when leader is hung.

## Timeline (UTC)

| Time | Event |
|------|-------|
| **~09:00** | `vault-2` (original raft leader) enters hung state — port 8201 open but msgpack RPCs hang. Its own logs go silent. Standbys continue heartbeat/appendEntries with `msgpack decode error [pos 0]: i/o timeout`. Neither standby triggers re-election because raft transport does not distinguish "TCP open + silent" from "TCP open + healthy". |
| **~09:15** | External endpoint starts serving 503. Woodpecker CI pipeline `d39770b3` blocks waiting for Vault. |
| **09:59** | Operator force-deletes `vault-2` pod — replacement comes up on node3 and enters candidate loop (term=32), cannot get quorum because DNS for `vault-0` is NXDOMAIN (ContainerCreating) and vault-1 does not respond (its raft goroutine also hung). |
| **10:07** | Operator force-deletes `vault-1` — new `vault-1` gets scheduled to node2. Its raft would be fine, but kubelet on node2 hangs in the pod cleanup path for the old pod's NFS mount. Concurrently, a new `vault-0` pod is attempted on node4, but **NFS mount from node4 times out at 110s** — the host kernel NFS client is in a degraded state that blocks all new mounts (including to completely different NFS paths like `/srv/nfs/ytdlp`). |
| **10:09** | Diagnostic test: from node1 and node4 CSI pods, `mount -t nfs -o nfsvers=4 192.168.1.127:/srv/nfs/ytdlp /tmp/test` times out. From node2 and node3 the same mount succeeds. NFS server is healthy (`showmount -e` works; `rpcinfo` shows all programs registered). The common factor on the broken nodes: they had a force-terminated Vault pod earlier in the session, leaving stuck `mount.nfs` processes in D-state. |
| **10:18** | Manual unmount of stale NFS mount from the force-deleted old vault-0 pod on node4. New mount attempts from CSI still time out — clearing the old mount did not recover kernel NFS client state. |
| **10:22** | Workaround discovered: mounting with `nfsvers=4.0` or `nfsvers=4.1` (instead of default `nfsvers=4` which negotiates to 4.2) succeeds on broken nodes. Confirms the stuck state is version-specific (NFSv4.2 session state), not a general NFS issue. Decision: rather than change CSI mount options cluster-wide (risk of remounting existing 48+ PVs), fix the nodes directly. |
| **10:31** | Investigated node2 kubelet state: old `vault-1` container shows `vault` process in **Z (zombie)** state with its `sh` wrapper stuck in `do_wait` in kernel (`zap_pid_ns_processes`). Containerd-shim PID killed manually — `sh` and zombie reparented to init but remained stuck (uninterruptible kernel wait tied to NFS). |
| **10:34** | Attempted `systemctl restart kubelet` on node2 — kubelet itself went into Z (zombie) with 2 tasks still attached. Classic NFS-related kernel deadlock. |
| **10:42** | **Decision: hard-reset node2 VM** (`qm reset 202`). Disruption: 22 pods evicted. |
| **10:43** | node2 back up (Ready). CSI registered. New `vault-1` scheduled to node2. NFS mount succeeded (fresh kernel state). Kubelet began chowning volume — **extremely slow, ~3 files per minute over NFS**. |
| **10:48** | `vault-1` (2/2 Running) unsealed. **Raft leader elected: `vault-2` wins term 32, election tally=2** (vault-1 voted yes once it came up, vault-0 unreachable). However vault-2's vault-layer (HA active/standby) never transitioned to active — raft leader with `active_time: 0001-01-01T00:00:00Z` and `/sys/ha-status` returning 500. |
| **10:50** | Restarted `vault-2` pod to force clean leader transition. New `vault-2` stuck in chown loop on node3 (same pattern as node2 earlier). |
| **10:54** | Patched the Vault `StatefulSet` with `fsGroupChangePolicy: OnRootMismatch` so subsequent recreations skip the recursive chown. |
| **10:57** | Force-deleted `vault-2` and `06fa940b` pod directory on node3. New pod spawned but kubelet again stuck on phantom state from the old pod. |
| **11:01** | **Hard-reset node3 VM** (`qm reset 203`). |
| **11:03** | **External endpoint returns 200.** vault-1 elected leader, vault-2 standby, both 2/2 Running. |

## Root Cause Chain

```
[1] Vault-2 raft goroutine hang (root cause — upstream Vault bug or infra-induced)
 └─> Cluster port 8201 accepts TCP but never responds to msgpack RPCs
     └─> Standbys' appendEntries calls return `msgpack decode error [pos 0]: i/o timeout`
         └─> Raft protocol: no re-election because leader is heartbeating at the TCP level
            └─> External endpoint returns 503 because HA layer has no active leader

[2] Recovery complication — abrupt pod termination
 └─> `kubectl delete --force --grace-period=0` on vault-0/1/2
     └─> containerd-shim fails to kill container cleanly (NFS I/O in D-state)
         └─> vault process ends as zombie; sh wrapper stuck in do_wait
             └─> Kubelet retries forever, cannot tear down old pod volumes
                └─> NFS-CSI unmount requests succeed at the NFS layer but kubelet's
                    volume state-machine never marks the volume as unmounted
                    (stale 0000-mode mount directory blocks teardown completion)

[3] Kernel NFS client corruption on node1/node4
 └─> Force-terminated Vault pod left stuck `mount.nfs` processes in D-state
     └─> Kernel NFS4.2 client session state corrupted (held open mount slot)
         └─> All subsequent mount syscalls for nfsvers=4 block 110s+ waiting for
             session slot that will never be freed
            └─> Manual workaround: nfsvers=4.1 bypasses the corrupted session state

[4] Kubelet starvation
 └─> Combination of (2) and (3) means kubelet is stuck in a 2-minute volume-setup
     context deadline loop — each iteration times out, new iteration restarts,
     infinite loop
     └─> Hard VM reset is the only exit
         └─> After reset, kubelet starts clean, CSI re-registers, mounts succeed

[5] Slow recursive chown amplifies impact
 └─> Default fsGroupChangePolicy: Always (Vault Helm chart 0.29.1 default)
     └─> Kubelet walks every file on NFS setting gid=1000
        └─> Over a 1GB audit log and a 47MB raft.db on NFS with timeo=30,retrans=3,
            each chown syscall takes seconds; kubelet 2-minute deadline runs out
            before the walk finishes
           └─> Loop never exits even when ownership is already correct
```

## Why This Failed

1. **Raft transport does not detect stuck leaders.** If TCP is open and the process is alive enough to hold the port, standbys assume the leader is healthy. A stuck goroutine that never responds to RPCs appears to raft as "leader with high RTT" and does not trigger re-election. This is an upstream Vault bug (or at least a missing liveness check).

2. **Abrupt pod termination + NFS = kernel-level zombie.** When a Vault pod holding an NFS mount is force-killed before it cleanly closes file handles, the kernel's NFS4.2 client session state enters a corrupted state. This blocks all new mounts from that node — not just to the same NFS path, but to ANY NFS path on the same server. The fix is a kernel reboot; there is no userspace recovery.

3. **Vault data on NFS violates the documented rule.** `infra/.claude/CLAUDE.md` explicitly states: *"Critical services MUST NOT use NFS storage — circular dependency risk."* Vault currently uses `nfs-proxmox` for both `dataStorage` and `auditStorage`. If Vault had been on `proxmox-lvm-encrypted`, none of the NFS corruption cascade would have happened.

4. **fsGroupChangePolicy: Always is the Helm default.** Every pod restart walks every file over NFS. On a 1GB audit log with degraded NFS RTT, this takes longer than kubelet's internal 2-minute deadline, causing infinite restart loops. `OnRootMismatch` makes chown a no-op when the root is already correct (which it always is after first setup).

5. **No alert for this failure mode.** Prometheus alerts exist for `VaultSealed`, `VaultDown` (`up` metric), and backup staleness, but none for "raft leader has been running without advancing commit index" or "standby reports leader but leader's `/sys/ha-status` returns 500".

## Remediation (Applied)

- [x] Hard-reset node2 and node3 VMs to clear kernel NFS state and kubelet zombies.
- [x] Manually patched live `StatefulSet vault/vault` with `fsGroupChangePolicy: OnRootMismatch` to stop the chown loop.
- [x] Lazy-unmounted stale NFS mounts from force-deleted pod directories on node2 and node3.
- [x] Removed stale kubelet pod directories (`/var/lib/kubelet/pods/<UID>`) that had 0000-mode mount subdirectories blocking teardown.
- [x] Updated `stacks/vault/main.tf` with the `fsGroupChangePolicy` setting so the next `scripts/tg apply vault` makes it durable.

## Remediation (Pending)

- [ ] **Hard-reset node4** to recover vault-0 (same NFS kernel corruption pattern).
- [ ] **Run `scripts/tg apply` on the vault stack** to persist the fsGroupChangePolicy change.
- [ ] **Add Prometheus alert `VaultRaftLeaderStuck`** — fire when `vault_raft_last_index_gauge` (or derivation from `vault_runtime_total_gc_runs`) stops advancing for >2 minutes while `vault_core_active` is 1.
- [ ] **Add Prometheus alert `VaultHAStatusUnavailable`** — fire when `vault_core_active{}` reports 0 across all pods but `up{job="vault"}` reports 1 (HA layer broken but pods alive).
- [ ] **Migrate Vault to `proxmox-lvm-encrypted` block storage** — eliminates the entire NFS failure class. This follows the rule already documented in `infra/.claude/CLAUDE.md`. Tracked as beads task (open after Dolt is back up; currently down on node4).
- [ ] **Consider raising kubelet volume-manager deadline** for large-volume chown scenarios, or document the `fsGroupChangePolicy: OnRootMismatch` requirement for all NFS-backed StatefulSets.
- [ ] **Runbook**: `docs/runbooks/vault-raft-leader-deadlock.md` — how to detect stuck leader, safe force-restart procedure that avoids zombie pods, NFS kernel state recovery.

## Contributing Factors

1. **NFS mount options use bare `nfsvers=4`**. This negotiates to the highest version the server supports (NFSv4.2). When 4.2 session state corrupts, mounts fail; 4.1 works. Pinning to `nfsvers=4.1` in the `nfs-proxmox` StorageClass would make the failure mode recoverable without node reboot, but would also require recreating 48+ existing PVs (volumeAttributes are immutable). Deferred.

2. **`kubectl delete --force` is the default for stuck pods**. Operators reach for force-delete when a pod won't terminate, but this leaves containerd in an inconsistent state when the underlying storage is hung. Better approach: identify the stuck process (typically `mount.nfs` or a kernel NFS callback) and fix the root cause before force-deleting.

3. **Beads / Dolt server was on node4**, so beads task tracking went offline during this incident and couldn't be used to log progress cross-session.

4. **node1 was cordoned mid-incident** to prevent rescheduling to a node with confirmed NFS issues, but this reduced the scheduling surface for anti-affinity-sensitive StatefulSets.

## Learnings

1. **NFS for stateful critical services is structurally unsafe.** When NFS breaks, the recovery involves killing pods → which can break NFS further → until a reboot. The rule exists for a reason; Vault should never have been on NFS.

2. **Raft liveness needs application-layer probing, not TCP.** Every time we've seen a "stuck leader" issue in the homelab, TCP was fine and the app was unresponsive. A lightweight RPC probe with a short timeout and Prometheus alert would catch this in minutes instead of hours.

3. **kubelet volume-manager is fragile against stuck NFS.** Once kubelet enters a chown loop with a context deadline shorter than the chown duration, it cannot make progress — even when the filesystem is otherwise healthy. `OnRootMismatch` is effectively mandatory for any pod with `fsGroup` and a volume >100MB.

4. **VM hard-reset is cheap but disruptive.** The two reboots took ~60 seconds each but evicted 22+44 = 66 pods. Doing this twice in one session is a lot of churn. A post-mortem-driven improvement: pre-prepare "hot-standby" capacity so we can cordon+drain instead of hard-reset when kubelet zombies appear.

5. **Documentation of this rule is worth more than the rule itself.** The CLAUDE.md already says "critical services must not use NFS". The vault stack violates it. The rule without enforcement (validation, linting, CI) is ignored during the rush to ship.

## References

- Related: `docs/post-mortems/2026-04-14-nfs-fsid0-dns-vault-outage.md` — previous Vault+NFS incident (different root cause, similar blast pattern).
- Vault helm chart 0.29.1 default `fsGroupChangePolicy` is unset (behaves as `Always`).
- Upstream Vault HA layer: raft leader → vault-active transition is in `vault/external_tests/raft`. Stuck goroutine pattern not documented as a known issue.
