# Node reboot downtime and chaos testing: evaluation and fixes

Status: phase 1 landed 2026-11-10 (infra a0cdad17, CI #3609). Chaos tooling
deferred.

## Question

Viktor asked whether to add chaos testing, then narrowed it: node reboots
should cause fewer failures and less app downtime. kured already reboots
nodes, so the question became what those reboots and other disruptions cost,
and what to fix.

## Method and its limits

A workload counts as down for a minute when `kube_deployment_status_replicas_available`
is 0 while `kube_deployment_spec_replicas` is above 0 (StatefulSets:
`kube_statefulset_status_replicas_ready`), summed per day, excluding workloads
down more than 10 hours that day. kube-state-metrics is scraped every 2
minutes, so a single scrape at zero counts as down: about 1,592 of the 30-day
total are single-sample blips. Per-pod restart times come from kubelet
`Observed pod startup duration` lines in Loki. Prometheus has gaps on 10-13,
10-24, 10-23 04:00-06:50 and 11-02 22:04-00:26, so those periods are
undercounted.

## How often kured reboots

10 reboots on 9 days between 2026-10-14 and 2026-11-10, at most one node per
24 hours (sentinel gate check 4). Not daily. kured only exercises graceful
drains; the most expensive events were ungraceful.

## Where 30 days of downtime came from

About 15,500 workload-minutes at zero ready (2026-10-11 to 2026-11-10).

| cause | workload-minutes |
|---|---|
| 10-23 Proxmox host reset, VMs killed, slow recovery after nodes were Ready | ~4,230 |
| 11-02 weekly upgrade chain: CNPG primary deleted before cordon, Proxmox CSI slot leaks | ~3,450 |
| Image bumps that passed verify and crash-looped until reverted | ~1,216 |
| kured reboots (8 windows) | ~1,124 |
| Node reboots outside kured with no drain (10-18, 10-19, 10-24) | ~1,018 |
| tor-proxy on a stale image for 43 h | ~540 |
| Rollouts of single-replica or Recreate workloads | ~468 |
| etcd stalls on the shared disk (mostly fixed 10-19) | ~396 |
| Other (crashes, GPU work, readiness failures, Sablier, OOM) | ~1,200 |
| Single-scrape blips | ~1,592 |

Each kured worker reboot puts 24 to 45 workloads at zero for 4 to 20 minutes.
On the 11-10 node3 drain, pods with no image pull took 100 to 115 s to start
on the receiving node because about 20 started at once; RWO Proxmox CSI pods
took 3.5 to 6.5 minutes.

## Decisions

**Chaos tooling deferred.** Chaos Mesh was evaluated (pod kill, network
partition, NFS stall, VM hard stop). kured already supplies graceful-drain
chaos every ~3 days, and most measured downtime came from known causes with
direct fixes. Revisit once those are fixed and the baseline is lower.

**Surge on drain rejected for now.** Azure/eviction-autoscaler would scale a
single-replica Deployment up before its pod is evicted. Two blind reviewers
found it would address about 2% of downtime and conflict with the upgrade
chain's `predrain_unstick`, which deletes pods whose PDB allows no
disruption. Its PDB creator also covers Recreate workloads that cannot surge,
and if the controller is down every drain blocks for kured's 30-minute
timeout. Kubernetes' own EvictionRequest API (KEP-4563) missed 1.35.

## Landed

| change | targets |
|---|---|
| Upgrade chain cordons before `predrain_unstick`; CNPG PDBs skipped so CNPG switches over (`stacks/k8s-version-upgrade/scripts/upgrade-step.sh`, test `test_upgrade_step_drain.py`) | ~1,500 min of 11-02 |
| Upgrade chain at Sunday 21:00 UTC, finishing before the host's nfs-mirror at 00:10 UTC | 11-02 CSI leak trigger |
| verify `floor_restarts`: a pod created by the change that restarts twice in the alert window fails the run (`scripts/verify/lib.sh`) | ~1,216 min |
| grafana liveness on `/healthz`, readiness stays `/api/health` | grafana restarts during MySQL moves |
| descheduler 7-day PodLifeTime in its own profile with `minReplicas: 2` | weekly restarts of single replicas |
| Runbooks: host reboot procedure (`docs/runbooks/proxmox-host.md`), never reboot a node without kured or a drain (`docs/runbooks/k8s-node-auto-upgrades.md`) | 10-23 class, ~1,018 min |

Already fixed before this work: 1800 s NotReady toleration (863d23065) and two
Proxmox CSI controllers (f8f4aa898), which address most of the 10-23 recovery
tail; CSI v0.22.0 and the `csi-leak-reconcile` timer for leaked slots.

## Open

- An app at zero for 30 minutes still only raises `DeploymentReplicasMismatch`,
  which has no `notify: page` label and so does not post. No Alertmanager to
  Forgejo issue bridge exists (memory #10260).
- `csi-leak-reconcile` has never fired in production; an end-to-end test needs
  a throwaway VM on the host.
- MySQL `dbaas/mysql-v26` is single-replica; each move takes 5 to 9 minutes,
  of which mysqld is about 20 s. The 2-minute volume teardown and 2-minute
  Pending gaps are unexplained. Moving the small PG-capable apps (grafana,
  shlink, forgejo, freshrss, roundcube, speedtest) to `pg-cluster-v18` is the
  larger option.
- No CNPG primary has been on a drained node since the 2-instance layout; the
  first Sunday chain after this change is the first test of the switchover
  path.
- No post-mortem exists for the 2026-10-23 outage.
- Image pre-pull for offline recovery was not built: with the 1800 s
  toleration pods stay on nodes that already hold their images.
