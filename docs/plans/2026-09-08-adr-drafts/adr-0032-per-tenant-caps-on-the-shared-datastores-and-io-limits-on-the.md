# ADR-0032: Per-tenant caps on the shared datastores, and IO limits on the shared spindle

Date: 2026-09-08
Status: Proposed

## Context

Runtime coupling on shared singletons is the largest incident bucket in the
window: 15 of 46, 35%. One NFS host, one 16 GB T4, one MySQL, one Redis, one
Postgres, one rotational disk carrying etcd. No repo restructuring, no typed
language and no rehearsal environment reaches any of them, because a rehearsal
environment cannot have a second T4.

The isolation machinery here is already substantial and it constrains the wrong
axes. 137 ResourceQuotas cover 135 of 151 namespaces and 142 LimitRanges cover
142, all driven from one Kyverno tier system with `generateExisting = true`, and
across all 137 quotas the only constrained keys are `limits.memory`,
`requests.cpu`, `requests.memory` and `pods`. None of the 15 incidents ran out of
any of those four. Every one ran out of database connections, disk IO, VRAM,
tmpfs, or single-node-loss headroom.

There is one worked example of getting this right, and it is the pattern to
copy. The GPU has a real quota: a `viktorbarzin.me/gpumem` extended resource
advertising 14,000 MiB, five tenants declaring 12,300 of it, a Kyverno Enforce
policy refusing an undeclared GPU pod at admission, and a runtime watchdog
behind that. It is also the only incident in the window that produced a control
which would stop a repeat.

Measured state of the other shared resources, 2026-09-07 and 2026-09-08:

| resource | cap today | consequence |
|---|---|---|
| MySQL | `max_connections = 80`, `max_user_connections = 0` on all 15 tenant users | any one tenant can take all 80. On 2026-09-01 forgejo plus an AI-crawler storm took out seven services |
| Postgres | `max_connections = 200`, `rolconnlimit = -1` on all 39 roles, `reserved_connections = 0`, 107 backends in use | a tenant storm takes out the apply path for 146 stacks, not just the app |
| Redis | one ACL user, `nopass`, `~* &* +@all`, no `requirepass`, 640 MB with `volatile-lru` | 24 to 26 stacks share it, including Authentik sessions and the Anubis challenge store. Any tenant can `FLUSHALL` it, and one tenant's growth evicts another's keys |
| storage and ephemeral-storage | 0 of 137 quotas constrain any storage key; 2 of 482 containers carry an `ephemeral-storage` limit; `local-path` is the default class | a pod filling node disk drives DiskPressure on nodes already at 85 to 94% of allocatable memory requests |
| disk IO | no `ionice`, `IOWeight`, `io.max` or `blkio` anywhere in the cluster or on the PVE host | on 2026-05-25 an import Job at `--concurrent-tasks 20` saturated the shared HDD and node1 rebooted, taking ~33 single-replica deployments with it |
| GPU seats | 5 tenants seated, 3 unseated by a named policy exclusion | `GPUVRAMLow` fired across 754 sample-intervals in 30 days and `gpu_vram_watchdog_recycles_total` has no series, so the runtime backstop has never acted |

The IO case has the largest blast radius measured anywhere in this study and it
appears in no existing coupling table. `sdc` is a single 10.7 TB rotational
device behind a PERC H730 Mini carrying the hypervisor root, `/srv/nfs` behind 69
PVCs, pfSense, Home Assistant, the devvm, and all six k8s node boot disks
including the one running etcd. It is saturated now: 886 read plus write IOPS
against the 150 to 200 random IOPS a 7200rpm pair sustains, 64% `io_time`,
average queue depth 16.7, 38 ms read latency, and etcd WAL fsync p99 1.48 s
against a 25 ms alert threshold and etcd's own 10 ms guidance. The pattern for
fixing it already exists in this repo, as `IOWeight` and `IOAccounting` drop-ins
for the devvm slice, and it is absent on the host that needs it.

Every `sdc` alert threshold is deliberately set above today's p99, and the rule
comments say why: they are set against this cluster rather than against healthy
hardware. They detect a regression from this baseline, and this baseline is the
problem.

## Decision

Cap the shared singletons per tenant, copying the GPU seat model: a declared
allocation, an admission or server-side refusal of an undeclared consumer, and a
runtime alert behind it. In order of cost:

1. **MySQL and Postgres per-tenant connection caps**, sized from measured peaks,
   plus a reserved pool for the apply path. A 25-connection cap on forgejo keeps
   55 of 80 available and confines that outage to one service. Authentik at 55
   of 200 needs an explicit exception at about 80; getting that number wrong is
   the one real risk here.
2. **Redis ACLs.** Split the single all-powerful user into per-tenant users
   scoped to their own keyspace, and set `requirepass`. Cheap, independent of any
   topology change, and it removes any tenant's ability to `FLUSHALL` the
   instance holding Authentik's sessions.
3. **cgroup IO limits on the PVE spindle** for the NFS-serving and batch
   workloads, using the drop-in pattern already in the repo. Throttle the batch
   producers, never `nfsd`.
4. **Seat the three unseated GPU tenants.** Do `stremio` and `ytdlp`, which are
   fixed and small. Treat `llama-swap` as a separate decision, since ADR-0016
   left it seatless for a stated reason.
5. **Add storage and ephemeral-storage dimensions** to the tier quota and
   LimitRange maps, sized from the live PVC census and set generously.

Do not add CPU limits. `strip-cpu-limits` has been live for 142 days and removes
them deliberately; CPU here is requests-only by design.

## Alternatives

- **Split the shared datastores into per-tenant instances.** Genuinely removes
  the coupling, and it is the wrong first move: adding Redis HA is what caused
  the 2026-05-30 split-brain, and 152 stacks reference the shared hosts through
  `config.tfvars`. Caps get most of the confinement for hours of work instead of
  weeks.
- **Move etcd off the shared HDD.** Correct, and separately tracked as bead
  `code-oflt`. It catches one confirmed incident and addresses a live chronic
  condition, but a botched data-dir move on a single-master cluster is a restore
  nobody has ever performed. IO limits reduce the pressure without that risk, so
  do them first.
- **Alert on the current thresholds instead of capping.** The thresholds are
  already above today's p99 by design, and raising the alerting is what produced
  `HighSystemLoad` being true 25% of the last 30 days at severity info. An alert
  on a condition nobody intends to fix within the month becomes furniture.
- **A standing rehearsal environment to catch these before production.** Does not
  reach this bucket at all: a scratch namespace shares every singleton whose
  exhaustion is the incident, so a rehearsal apply doing real work can cause the
  2026-05-25 shape rather than catch it.

## Consequences

**Positive**
- Attacks the largest bucket, 15 of 46, with items that are individually hours
  and mutually independent, so they can land in any order.
- Confines a tenant's failure to that tenant. The 2026-09-01 seven-service
  outage becomes a one-service outage.
- Protects the apply path. Today a tenant connection storm on the shared
  Postgres can stop 146 stacks from reading their own Terraform state.
- Fixes a real defect on the way past: the shared MySQL PodDisruptionBudget
  selects an abandoned StatefulSet at 0 replicas, so the datastore behind that
  outage currently has no disruption budget at all while kured's health-gate
  allowlist contains no application alert.

**Negative**
- Connection caps sized too tight cause the outage they prevent. Size from
  measured peaks, ship with headroom, and alert on approach rather than on
  breach.
- Redis ACLs touch every one of 24 to 26 consumer stacks, so the per-tenant user
  work is a fleet sweep. Do the `requirepass` and single-user hardening first,
  which is one stack.
- IO limits mis-scoped are worse than none. Throttling `nfsd` degrades 69 PVCs.
  The limit belongs on the batch producers and on the devvm slice, which is where
  the existing pattern already sits.
- Storage quota is one file edit propagating to 135 namespaces, which is also
  the hazard: a wrong ceiling has shared-root blast radius. Ship it as Audit
  first and read what it finds.
