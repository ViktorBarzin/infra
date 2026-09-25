# Resource management

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/compute.md`, `docs/architecture/multi-tenancy.md`.

## Resource Management Patterns
- **CPU**: All CPU limits removed cluster-wide (CFS throttling). Only set CPU requests based on actual usage.
- **Memory**: Set explicit `requests=limits` based on VPA upperBound. Target: upperBound x 1.2 for stable services, x 1.3 for GPU/volatile workloads.
- **Right-sizing**: VPA/Goldilocks was **REMOVED 2026-06-12** (etcd-load-reduction — 349 VPAs all ran `updateMode=Off`, costing ~800 etcd objects + continuous recommender writes + a pod-creation admission webhook for dashboard-only value). Right-size **on demand with `krr`** (Robusta, Dockerized from the devvm — no cluster install, no admission webhook, no eviction risk; reads Prometheus). Set container resources explicitly in TF from krr output.
- **LimitRange**: Tier-based defaults silently apply to pods with `resources: {}`. Always set explicit resources on containers needing more than defaults. Tier 3-edge and 4-aux now use Burstable QoS (request < limit) to reduce scheduler pressure.
- **Democratic-CSI sidecars**: Must set explicit resources (32-80Mi) in Helm values — 17 sidecars default to 256Mi each via LimitRange. `csiProxy` is a TOP-LEVEL chart key, not nested under controller/node.
- **ResourceQuota blocks rolling updates**: When quota is tight, scale to 0 then back to 1 instead of RollingUpdate. Or use Recreate strategy.
- **NVIDIA GPU operator resources**: dcgm-exporter and cuda-validator resources configurable via `dcgmExporter.resources` and `validator.resources` in nvidia values.yaml.
- **Pin database versions**: Disable Diun (image update monitoring) for MySQL, PostgreSQL, Redis.
- **Quarterly right-sizing**: Run `krr` (Dockerized, against Prometheus) for recommendations; compare to current requests and adjust in TF. (Goldilocks dashboard removed 2026-06-12.)
- **The descheduler balances on memory REQUESTS since 2026-09-23** (`stacks/descheduler/values.yaml`, its own `balance-by-requests` profile: under 70% is a destination, over 90% a source, `nodeFit: true`, PVC pods never moved, at most 10 evictions per hourly run). It used to read actual usage, which never corrected the request imbalance a kured drain leaves behind: node2 came back at 49.9% of requests beside three nodes at 98-99%, and the Vaultwarden backup (pod affinity to Vaultwarden) could not schedule for ~15h. It balances placement only. The untainted workers hold 83-86% of their memory in requests overall, so N-1 headroom still needs `krr`. **It runs at :55, not :00**: 38 hourly CronJobs start at :00 (3,664 MiB of requests), and a run in that minute saw node2 inflated from 64% to 72%, over its 70% destination line, so it stalled for five runs.

## Tier System
`0-core` | `1-cluster` | `2-gpu` | `3-edge` | `4-aux` — Kyverno auto-generates LimitRange + ResourceQuota per namespace based on tier label.
- Containers without explicit `resources {}` get default limits (256Mi for edge/aux — causes OOMKill for heavy apps)
- Always set explicit resources on containers that need more than defaults
- Opt-out: labels `resource-governance/custom-quota=true` / `resource-governance/custom-limitrange=true`
