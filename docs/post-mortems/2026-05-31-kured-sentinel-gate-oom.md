# Post-Mortem: kured-sentinel-gate OOM while k8s-master stuck pending-reboot

| Field | Value |
|-------|-------|
| **Date** | 2026-05-31 |
| **Duration** | OOMs began 2026-05-30 ~03:33, escalating until fixed 2026-05-31 14:40 UTC |
| **Severity** | SEV4 — no user-facing impact; noisy + latent risk (a wedged gate pod could eventually mis-gate reboots) |
| **Affected** | `kured-sentinel-gate` pod on k8s-master only |
| **Status** | Fixed (gate hardened). Two contributing alerts still open, tracked separately. |

## Summary

Noticed by the operator during a routine cluster health check ("an app OOMing
periodically"). The `kured-sentinel-gate` pod on k8s-master was the *only*
container in the cluster with OOM events: `container_oom_events_total` showed
0/day through May 29, **15 on May 30, 134 on May 31** (by 08:21). The kernel
OOM-killer was killing child `kubectl` processes inside the pod's cgroup; PID 1
(bash) survived, so the pod never restarted — restartCount stayed at 1 despite
149 oom_events in 7d. Symptom: the gate's check cycle stretched from 5 min to
~25 min.

## Root cause (chain)

```
hermes-agent deploy = 0/0 (parked 2026-04-22, PVC-perms bug) → PVC WaitForFirstConsumer
  never binds → PVCStuckPending fires; its dead external monitor → ExternalAccessDivergence
/mnt/synology-backup (192.168.1.13 offsite NAS) at 96% → NodeFilesystemFull fires
        │  none of these 3 are in kured's alert ignore-list
        ▼
kured halts ALL reboots (correct fail-safe)
        ▼
k8s-master got /var/run/reboot-required on 2026-05-30 03:33 (kernel update) but can't reboot
        ▼
master's gate pod is now the ONLY one running the kubectl-heavy hot path every cycle
(the other 6 hit the early "no reboot required → continue" at ~3 MiB)
        ▼
the immortal `while true` bash loop slowly leaks (repeated kubectl forks + the
Check-4 `< <(kubectl ...)` process substitution), crosses the 64Mi cgroup limit
~5 days in, and the OOM-killer culls child kubectls — accelerating as it wedges
```

The 64Mi limit was the proximate misconfiguration: each `kubectl` fork is a
~30-50Mi Go binary, and the hot path runs up to 3 per cycle.

## Why hard to spot

- The pod showed `Running` / `1 restart` the whole time — the OOMs hit child
  processes, not PID 1. Only `container_oom_events_total` (cAdvisor) revealed it;
  `kube_pod_container_status_*` restart metrics did not.
- Logs looked clean ("ALL CHECKS PASSED") — the gate kept producing correct
  decisions, just slowly.
- Same blind spot as the 2026-05-16 PM: there is still no Prometheus signal for
  "a node has been pending-reboot too long" (the deferred `KuredRebootBacklog`
  alert). That alert would have surfaced the stuck-master state on May 30.

## Fix (`stacks/kured/main.tf`, applied + committed 2026-05-31)

1. **Immediate**: deleted the leaking pod (DaemonSet recreated it at ~3 MiB).
2. **Durable**: memory limit `64Mi → 256Mi` (headroom for kubectl forks) **plus**
   a self-restart guard — the loop counts iterations and `exit 0`s every
   `MAX_ITER=72` cycles (~6h at 300s), so kubelet restarts the pod fresh and the
   slow leak can never accumulate, regardless of how long a node stays
   pending-reboot. Verified: all 7 pods at 256Mi, `iter N/72` loop live, OOMs
   stopped.

## Contributing items (open — being addressed separately)

- **hermes-agent** parked at `replicas=0` since 2026-04-22 (PVC `/opt/data` perms
  mismatch). Its orphaned `WaitForFirstConsumer` PVC drives PVCStuckPending +
  ExternalAccessDivergence. Resolve = fix perms + scale up, OR remove the PVC and
  external monitor while parked, OR scope PVCStuckPending to ignore 0-replica
  consumers.
- **Synology offsite backup at 96%** (5.0T/5.3T, 265G free; `#recycle` holds 17G).
  Resolve = prune retention / empty recycle / expand volume. NodeFilesystemFull
  cannot be blanket-ignored in kured (a full *node* disk SHOULD block reboots) —
  if scoped, scope to the offsite mount only.

Until at least the first two clear, kured will keep (correctly) refusing to
reboot master — but the gate pod is now leak-proof either way.

## Lessons

1. **`container_oom_events_total` is the canonical "is anything OOMing" signal** —
   not restart counts. A cgroup can OOM-kill children while PID 1 lives.
2. **Immortal in-pod loops that fork heavy binaries need either a generous limit
   or a periodic self-restart.** A periodic task is really a CronJob; the
   self-exit guard is the minimal fix within the DaemonSet model.
3. **The `KuredRebootBacklog` alert (deferred from 2026-05-16) is now twice-implicated.**
   Worth promoting from the backlog: `kured_reboot_required == 1 for > 24h`.
