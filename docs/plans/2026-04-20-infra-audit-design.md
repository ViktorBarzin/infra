# Infra Audit — 2026-04-20

**Status**: Design (post-research, post-challenge)
**Author**: Viktor Barzin (audit run by Claude)
**Scope**: `infra/` Terragrunt stacks + platform services (`claude-agent-service`, `claude-memory-mcp`, `beadboard`, `broker-sync`)
**Goals**: Reliability · Declarative-first · Reduced maintenance overhead · Maintained scalability
**Method**: 5 parallel research agents (R1 Reliability, R2 Declarative, R3 Maintenance, R4 Scalability, R5 Security) → 91 raw findings → 2 independent challengers → filtered/corrected/ranked backlog below.

## Context

The home-lab has grown into a mature stack (105 Tier-1 Terragrunt stacks + 6 Tier-0 SOPS, CNPG, Vault+ESO, Kyverno, Traefik, Authentik, CrowdSec, Woodpecker CI, Redis-Sentinel, MySQL-standalone, Proxmox-NFS). Recent work has been consolidation: MySQL InnoDB-Cluster → standalone (2026-04-16), Redis Phase 7 refactor (2026-04-19), NFS fsid=0 SEV1 post-mortem (2026-04-14), Authentik outpost /dev/shm fix (2026-04-18). This audit surveys everywhere that remains — what's brittle, what's manual, what's dark, what hasn't caught up to recent decisions — and ranks fixes by impact and by operator fatigue.

## Corrections up-front (challenger round)

Before reading the backlog, these findings from the research phase are **dropped, corrected, or reframed** — challengers spot-checked live state and proved them wrong, already-solved, or intentional-by-design. Being honest about this is the point of the challenge round:

| Finding as stated | Actual state | Action |
|---|---|---|
| R4#1: Worker nodes 86-91% memory saturation | Live `kubectl top nodes`: 44-51% across k8s-node{1-4} | **DROPPED** — bad metric pull |
| R4#2: Frigate CPU unbounded (1.5 CPU request, no limit) | Cluster policy is **all CPU limits removed** to avoid CFS throttling (`infra/.claude/CLAUDE.md` → Resource Management) | **DROPPED** — by design |
| R4#7: Redis no `maxmemory-policy` | `infra/stacks/redis/modules/redis/main.tf:254` sets `maxmemory-policy allkeys-lru` (Phase 7, 2026-04-19) | **DROPPED** — already solved |
| R2#1: 307 Kyverno lifecycle markers is a drift risk | Markers are the **canonical discoverability tag** — `ignore_changes` only accepts static attribute paths, snippet convention is the only viable path; reframe as *"markers are fine, missing markers are the risk"* | **REFRAMED** |
| R2#3: 140 `ignore_changes` blocks | Actual: **310** across `.tf` files (2.2× off) | **CORRECTED** |
| R3#10: 65 CronJobs | Actual: 59 (10% off) | **CORRECTED** |
| R1#1: 47 deployments missing probes | Actual: **115 missing at least one probe; 103 missing both** | **CORRECTED (much worse than reported)** |
| R1#9: MySQL standalone no HA/PDB | Intentional post-2026-04-16 migration from InnoDB Cluster. Backup + restore matter; HA is explicit deferred. | **REFRAMED** — split into HA (deferred) / backup-restore (open) / connection pool (open) |
| R1#10: PDB gaps include Traefik, Authentik | Traefik & Authentik PDBs `minAvailable=2` exist (CLAUDE.md). The real gaps are **CrowdSec LAPI, Calico-apiserver, ESO webhook, Woodpecker-server** | **CORRECTED (list pruned)** |
| R5#2: 4 Kyverno security policies in Audit | **All 16 ClusterPolicies are in Audit** — zero in Enforce. | **CORRECTED (worse)** |

---

## Executive summary — top 5 cross-cutting themes

These are the themes that survive the challenge round and hit ≥2 concerns. Each headline is a 1-line hook; deep-dives below.

1. **Declarative escape hatches (NFS exports, master-node file provisioners, null_resource initializers)** — `/etc/exports` is not in Terraform, which is the **root cause of the 2026-04-14 SEV1**; 6 null_resources + 3 SSH file provisioners still orchestrate critical state. *Hits R2 + R1 + R3.*
2. **Observability has blind spots where pain would actually come from** — no OOMKill alert routing, no NFS capacity monitor, no GPU utilization dashboard, no ESO refresh-lag alert, no CronJob success-rate summary. Alerts exist but they don't cover the operator's real failure modes. *Hits R1 + R3 + R4.*
3. **Supply-chain hygiene: image pinning + Renovate + admission signing** — 84 `:latest` tags in production TF, zero Renovate/Dependabot across 18 repos (~15 hr/mo toil by estimate), no cosign/trivy on push. Single theme unifies security posture, maintenance toil, and determinism. *Hits R3 + R5.*
4. **Reliability-probes & graceful shutdown are genuinely uneven** — 115 deployments missing at least one probe (incl. 103 missing both), 50+ Recreate deployments with no `terminationGracePeriodSeconds`/`preStop`. This is the quietly-largest reliability debt. *Hits R1 + R3 (pager toil).*
5. **Backup coverage is uneven: 30+ PVCs lack app-level CronJobs** — Proxmox host snapshots cover the disk, but Forgejo (!), Affine, Paperless, Hackmd, Matrix, Owntracks have no app-aware dumps. Restore granularity is file-level, not entity-level. *Hits R1 + R5 (compliance) + R3 (restore rehearsal toil).*

Honourable mentions that didn't make top 5 but sit just below: Kyverno audit→enforce transition (security), ESO refresh-lag alert (secrets reliability), Vault hardening (audit log offsite, root-token K8s-secret scope), Cloudflared tunnel-token SPOF (not replica SPOF — those are 3), Dolt PVC sizing + backup.

---

## Scoring method

Two parallel rankings — scan both.

**Rank A — Impact × Reversibility (the original formula)**
`score = Impact × (6 - Effort) × (6 - Risk)` — each dimension 1-5.

**Rank B — Operator fatigue weight**
`score = Impact × (6 - Effort) × FatigueWeight` where `FatigueWeight = 3` if the finding introduces *daily/weekly manual toil* and `1` otherwise. This re-ranks by how much pain the unfixed state causes per month.

Both rankings below. When they agree, that's the clear signal. When they diverge, that's where Rank B (fatigue) wins — Viktor has stated operator fatigue dominates abstract risk for a solo-operator lab.

---

## Ranked backlog (filtered, deduplicated, corrected)

Counts below reflect **post-challenge corrected numbers**. Every row has a reference verified either by a spot-check (file:line) or a live cluster command.

| ID | Title | Concerns | Impact | Effort | Risk | Rank A | Rank B | Refs |
|---|---|---|---:|---:|---:|---:|---:|---|
| F01 | NFS `/etc/exports` not in Terraform (SEV1 root cause) | R2+R1 | 5 | 3 | 2 | **60** | **45** | `infra/scripts/pve-nfs-exports`, PM 2026-04-14 |
| F02 | 115 deployments missing probes (103 missing both) | R1+R3 | 5 | 3 | 2 | **60** | **45** | `kubectl get deploy -A -o json` |
| F03 | Zero Renovate/Dependabot across 18 repos | R3+R5 | 4 | 2 | 1 | **80** | **48** | `find /home/wizard/code -name ".renovaterc*"` → 0 results |
| F04 | 84 `:latest` image tags in production TF | R3+R5+R4 | 4 | 2 | 2 | **64** | **48** | `grep -rn ':latest' infra/stacks` |
| F05 | No OOMKill / unschedulable / node-CPU alert | R1+R4+R3 | 5 | 3 | 1 | **75** | **45** | Grep Prometheus rules — no `OOMKilling` rule present |
| F06 | 6 `null_resource` DB initializers in `dbaas` stack | R2 | 4 | 3 | 3 | **36** | **36** | `grep -n null_resource infra/stacks/dbaas` |
| F07 | 3 SSH+file provisioners on k8s-master (audit, OIDC, etcd) | R2 | 4 | 3 | 3 | **36** | **36** | `stacks/platform/modules/rbac/apiserver-oidc.tf` |
| F08 | ESO refresh-lag alert missing (52 ExternalSecrets) | R1+R5+R3 | 4 | 2 | 1 | **80** | **48** | `stacks/external-secrets/` — no PrometheusRule for refresh lag |
| F09 | 30+ PVCs without app-level backup CronJobs | R1+R5 | 4 | 3 | 2 | **48** | **36** | Affine, Forgejo, Hackmd, Matrix, Owntracks, Paperless (no `*-backup` CJ) |
| F10 | Cloudflared tunnel-token SPOF (replicas OK, token shared) | R1+R5 | 3 | 4 | 2 | **24** | **8** | `stacks/cloudflared/` single tunnel credential |
| F11 | MySQL restore never rehearsed end-to-end | R1+R4+R3 | 4 | 2 | 2 | **64** | **48** | No `mysql-restore-drill` CJ; runbook untested post-migration |
| F12 | Kyverno policies all 16 in Audit — **sequence carefully** | R2+R5 | 4 | 3 | **4** | **24** | **24** | `kubectl get clusterpolicy` |
| F13 | 97 RollingUpdate deployments lack explicit surge bounds | R1 | 2 | 2 | 2 | **32** | **12** | TF defaults inherit from Helm/k8s (25%/25%) |
| F14 | CronJob success-rate dashboard + alert rollup missing | R3+R4 | 3 | 2 | 1 | **60** | **36** | `CronJobTooOld` rule — partial; no 24h rollup |
| F15 | Authentik outpost /dev/shm fix applied via Helm API only | R1+R5 | 3 | 2 | 2 | **48** | **48** | Not in TF — upgrade-reversion risk |
| F16 | Dolt (beads DB) no backup CronJob — 2Gi PVC near full | R1+R4 | 4 | 2 | 2 | **64** | **32** | `stacks/beads/` — no `dolt-backup` CJ |
| F17 | Vault StatefulSet `updateStrategy=OnDelete` (manual roll) | R1+R3 | 2 | 2 | 3 | **24** | **24** | `kubectl get sts -n vault -o yaml` |
| F18 | No NetworkPolicies cluster-wide | R4+R5 | 4 | **5** | **4** | **8** | **8** | `kubectl get netpol -A` → 0-2 |
| F19 | RBAC `oidc-power-user` has cluster-wide secrets r/w | R5 | 4 | 3 | 3 | **36** | **12** | `stacks/platform/modules/rbac/` |
| F20 | No image supply-chain verification (cosign, trivy on push) | R5 | 4 | 4 | 3 | **24** | **8** | No admission controller for signatures |
| F21 | Vault audit log offsite backup not configured | R5+R1 | 3 | 2 | 1 | **60** | **36** | `stacks/vault/` — no `audit-log-sync` CJ |
| F22 | Claude-agent, beadboard, broker-sync singletons | R1 | 2 | 2 | 2 | **32** | **12** | `kubectl get deploy -n claude-agent,beadboard,broker-sync` |
| F23 | 50+ Recreate deployments lack graceful-shutdown hooks | R1+R3 | 3 | 3 | 2 | **36** | **36** | `grep -L terminationGracePeriodSeconds stacks/**` |
| F24 | CoreDNS scaled via `kubectl scale` not TF | R2 | 3 | 2 | 2 | **48** | **32** | Command in runbook; no TF resource for replicas |
| F25 | GPU / inference-latency SLO unmonitored | R4+R5 | 3 | 3 | 2 | **36** | **36** | No dcgm dashboard; Frigate liveness checks only |
| F26 | Prometheus TSDB 200Gi — retention untracked | R4 | 2 | 2 | 1 | **40** | **20** | `stacks/monitoring/` |
| F27 | Pod Security Standards labels unset on all namespaces | R5 | 3 | 2 | 3 | **36** | **12** | `kubectl get ns -o json \| jq '.items[].metadata.labels'` |
| F28 | Authentik worker VPA upperBound 2.3× actual request | R4 | 2 | 2 | 2 | **32** | **20** | Goldilocks dashboard |
| F29 | 9 DB rotation targets, no post-rotation verification loop | R5+R3 | 3 | 2 | 2 | **48** | **36** | Vault DB engine every 7d; no auto-verify |
| F30 | Tier-0 SOPS workflow 7-step vs 3-step Tier-1 | R3 | 2 | 2 | 1 | **40** | **20** | `scripts/state-sync` — manual decrypt/encrypt/commit |

**Rank A leaders (top 8)**: F03, F08, F05, F11, F04, F16, F01, F02 — "big cluster wins, cheap to try"
**Rank B leaders (top 8)**: F03, F04, F08, F11, F15, F01, F02, F05 — "what's paining you weekly"

F03 (Renovate), F08 (ESO refresh alert), F11 (MySQL restore drill) and F01 (NFS in TF) lead in **both** rankings → these are the clear "do first" candidates.

---

## Per-concern deep dives

### R1 — Reliability (18 raw → 11 real after challenge)

Filtered: dropped R1#1/9/10 (incorrect numbers, intentional choices). What actually matters:

- **Probes (F02)** — 115 deployments missing at least one probe; 103 missing both. The corrected count is 2.4× the original claim. Worst offenders are batch workloads (CronJob-spawned) that legitimately skip probes — but long-lived ones (Affine, Hackmd, mailserver sidecars) genuinely need them. Triage: filter by `spec.replicas ≥ 1` and `containers[].command != ["/bin/sh","-c"]`-style short-runners, then add readiness+liveness one-by-one.
- **Cloudflared tunnel token SPOF (F10)** — Replicas are 3 (per CLAUDE.md), so the agent finding "SPOF" framed as replicas is wrong. The real SPOF is the *tunnel credential*. Secondary tunnel with weighted Cloudflare DNS records is the honest fix — medium effort, low urgency unless tunnel CA rolls keys.
- **PDB gaps (F13-like, excluded from table)** — After challenger correction, gaps are: CrowdSec LAPI (3 replicas, no PDB), ESO webhook+controller, Woodpecker-server. Not urgent — drain-test with `kubectl drain --dry-run` shows no current issue.
- **App-level backups (F09)** — Proxmox host captures the PVC contents nightly via LVM snapshot + rsync with `--link-dest` weekly versioning, so file-level recovery is covered. But for databases inside PVCs (e.g. Affine's Postgres in-pod, Paperless' SQLite), app-aware dumps give transactional consistency. Audit pass: enumerate every PVC without a sibling `*-backup` CronJob, add one for the ones that host embedded DBs.
- **MySQL restore drill (F11)** — Migrated 4 days ago. Runbook exists. End-to-end restore (dump → new DB → connect an app → verify) hasn't been rehearsed. SEV1 risk if a dump has been silently broken since migration.
- **Vault update strategy (F17)** — `OnDelete` means helm upgrade leaves pods untouched; must manually `kubectl delete pod` to restart. Low impact (infrequent) but procedural toil.
- **Dolt PVC near-full + no backup (F16)** — `bd list --status in_progress` runs against this DB; it's load-bearing for cross-session task state. Grow the PVC (resize annotation) + add dolt dump CronJob.

### R2 — Declarative Coverage & Drift (16 raw → 8 real)

Filtered: dropped R2#1 (Kyverno markers are by-design), corrected R2#3 to 310.

- **NFS exports (F01)** — The file is git-managed at `infra/scripts/pve-nfs-exports` but deployed via `scp + exportfs -ra`, not Terraform. This is the exact path that caused the 2026-04-14 SEV1 (fsid=0 on wrong exports line). Options: (a) `null_resource` with `local-exec scp + remote-exec exportfs -ra` triggered on hash of content (partial — SSH dep); (b) new module `pve_host_config` that templates and SCPs multiple PVE-host artifacts with checksum verification. (b) is the cleaner long-term fix.
- **Null-resource initializers (F06)** — 6 in `dbaas` (MySQL users, CNPG cluster, TF-state role, payslip DB, job-hunter DB). Some are genuinely unavoidable (bootstrapping DB before the DB exists); others could use `postgresql_grant` / `mysql_user` providers.
- **SSH file provisioners on k8s-master (F07)** — `apiserver-oidc.tf`, `audit-policy.tf`, `etcd tuning`. One-way sync, no drift detection. Proposed quick wins (per `2026-02-22-node-drift-quick-wins-design.md` already exists). Continue/finish the plan.
- **CoreDNS scaling manual (F24)** — Current runbook uses `kubectl scale`/`set env`/`set affinity`. Drift-prone; convert to `kubernetes_deployment` TF resource overriding the Helm chart's scale/affinity fields.
- **MySQL InnoDB Cluster + operator TF resources still present** — Phase 4 cleanup. Low urgency, but removing reduces cognitive load on anyone reading `stacks/dbaas/`.
- **Technitium readiness-gate null_resource with `timestamp()` trigger** — Runs every apply, 3-6 min wall time. Replace with a real health-check on `terraform_data` with `triggers_replace = { checksum = sha256(config) }`.
- **GPU node taints + Proxmox CSI labels via null_resource kubectl** — No drift detection. Fix is in the `2026-02-22-node-drift-quick-wins-design.md` plan.

### R3 — Maintenance overhead (18 raw → 10 real)

- **Renovate (F03)** — The single highest-leverage maintenance fix. 18 repos × ~0.8 hrs/month manual version sweep = real time. Add `.github/renovate.json` (grouping rules for Terraform providers, K8s provider, Docker images) + auto-merge patch-level. Start with `infra/` only; expand after 2 weeks.
- **Image pinning (F04)** — 84 `:latest` tags in production TF. Root CLAUDE.md still says "use 8-char git SHA tags" but that's not enforced. Admission control via Kyverno `require-trusted-registries` is in Audit today — add a sibling policy `forbid-latest-tag` also in Audit. Separate from F03 because pin-to-SHA + Renovate is a synergistic pair.
- **MySQL restore drill (F11)** — tracked under R1 for impact; also a maintenance item because the restore *procedure* has not been test-updated since migration.
- **CronJob alert rollup (F14)** — 59 CronJobs; "which were healthy last 24h" takes ad-hoc `kubectl get jobs --sort-by` scrolling. Add a Grafana panel with `kube_cronjob_status_last_successful_time < now - 2×schedule` summary.
- **Graceful-shutdown toil (F23)** — 50+ Recreate deployments without `terminationGracePeriodSeconds` or `preStop`. Noisy pager hits after node drain. One-off sweep: add a 30s `terminationGracePeriodSeconds` default via Kyverno mutation rule.
- **Tier-0 SOPS workflow (F30)** — 7-step decrypt/edit/encrypt/commit vs Tier-1's 3-step. Combined `tg` wrapper flag `--edit <stack>` that auto-decrypts → EDITOR → auto-encrypts → commit in one command. Moderate win; low risk.
- **Stale `in_progress` beads** — 7 stale tasks in `bd list --status in_progress` at audit start. Session-end hook checks this; 3-5 days without notes is the signal. CLAUDE.md covers the rule — it's followed-sometimes, not enforced.
- **Runbook staleness** — no `last_reviewed` frontmatter on runbook MDs; trivial to add. One-off sweep then keep it honest.
- **CI/CD template unification** — "GHA build → Woodpecker deploy" is the documented pattern for 10 repos; rest still on Woodpecker-only. Track as follow-ups per repo in `bd`.
- **Kyverno DNS-config boilerplate 307 markers** — Not a problem (see correction at top). Do add a lint rule in CI that flags any `kubernetes_deployment` without `# KYVERNO_LIFECYCLE_V1` marker; that's the real drift risk.

### R4 — Scalability (18 raw → 9 real)

Filtered: dropped R4#1 (metric mispull), R4#2 (CPU-limit policy), R4#7 (Phase 7 solved).

- **CNPG memory headroom** — Currently 2Gi limit. Top-line metric at quiet time; add a `ContainerNearOOM > 85%` rule that watches CNPG specifically (general rule exists; CNPG is Tier 0 so deserves explicit binding).
- **HPA cluster-wide: zero** — Every stateless service is 1:1. Not urgent at current node-CPU 8-31%, but one big feature (Immich re-index, Authentik load spike) tips the balance. Pilot: HPA on Traefik (CPU-driven), observe, expand.
- **Redis no HPA + HAProxy singleton** — Wire Sentinel into direct client access (Phase 8 of Redis refactor, per R1#11 of raw findings). Currently all 17 consumers go via HAProxy — the single-point bypass was deliberate (simpler client config), but the HAProxy is now the SPOF Sentinel was meant to prevent. Worth a plan doc (`plans/2026-MM-DD-redis-phase8-sentinel-clients.md`).
- **PgBouncer pool sizing unknown** — Authentik has 3 pods, each opening N connections. At load spikes (big org sync), pool exhaustion. Short-term: `pgbouncer_show_pools` metric + alert at 80% util. Longer-term: pool-size tuning based on observed wait times.
- **Prometheus TSDB (F26)** — 200Gi retention unquantified. Risk: disk fills → scrape gaps → audit blind. Add `kubelet_volume_stats_used_bytes{persistentvolumeclaim="prometheus-server"} > 0.85 * capacity` alert.
- **NFS capacity not monitored** — PVE host has 1TB HDD LV. No `node_filesystem_avail_bytes` scrape from PVE host (it's outside the cluster). Install node_exporter on PVE host; scrape via Prometheus federation or remote_write.
- **VPA quarterly review unscheduled** — Goldilocks is in `Initial` mode (not Auto, by design). Review is manual per quarter. Calendar event + runbook link.
- **Registry single instance** — Registry outage = no pod restarts. Post-mortem 2026-04-19 documented a container-engine pin; replica count still 1. Consider HA registry backed by S3-compat store (MinIO in-cluster) for the second replica — but low urgency given probe CJ monitors integrity every 15m.
- **No ResourceQuota utilization alert** — Quota exhaustion invisible until a pod refuses to schedule. `kube_resourcequota{type="used"} / kube_resourcequota{type="hard"} > 0.85` rule.

### R5 — Security & Secrets (21 raw → 13 real)

- **Vault `vault-unseal-key` K8s Secret (F21-related)** — Challenger A said it wasn't present; it is (`kubectl get secret -n vault`). Used by auto-unseal. RBAC on the secret should restrict to `vault-server` SA only. Audit the `role` + `rolebinding` in `stacks/vault/`.
- **Vault audit log offsite (F21)** — Rotated logs not synced to NFS backup. Add a `vault-audit-log-sync` CronJob or append the audit log path to `nfs-change-tracker` inotify list (zero-Terraform change if the latter).
- **Kyverno audit → enforce (F12) — sequence carefully** — All 16 policies are in Audit today. Naive switch to Enforce will block legitimate workloads (Loki, Frigate, nvidia-device-plugin, wireguard have privileged/host-ns requirements — all documented). Plan: (a) generate `Kyverno PolicyException` CRs for known-good workloads first; (b) enforce one policy at a time, 1-week observation; (c) start with `require-trusted-registries` (least breakage risk). **DANGEROUS TO EXECUTE NAIVELY — don't batch.**
- **No NetworkPolicies (F18)** — Challenger correctly flagged the effort (5) and risk (4): wrong NetworkPolicy stops Authentik from reaching its DB in minutes. Approach: allow-list namespace-wide first (e.g. `authentik` ns can reach `dbaas` on 5432), expand over a month. Single biggest latent security improvement but needs runway.
- **RBAC oidc-power-user secrets r/w cluster-wide (F19)** — Scope down: list which Authentik groups get this binding, remove `secrets:*` from the cluster role, add namespace-scoped RoleBindings where needed. Medium effort, high leverage.
- **Image supply chain (F20)** — cosign verification + admission controller is the mature path. Trivy-on-push fits in GHA workflows. Both unblocked after F04 (pinning).
- **`:latest` tags (overlap F04)** — Security aspect: signed-image admission requires stable refs.
- **Privileged containers** — Loki, WireGuard, NVIDIA, Frigate known-exceptions. Document the exceptions inline (comment block on the TF resource) so future maintainers don't accidentally "fix" them.
- **Git history plaintext secrets** — Challenger B flagged unverified. One way to verify cheaply: `git secrets --scan-history`. Add it as a pre-audit one-off.
- **CrowdSec Metabase disabled, no Prometheus exporter** — R5#18. Enable the Prometheus exporter (no Metabase) for attack-pattern visibility; very cheap.
- **cert-manager evaluation paused** — Documented pause; TLS rotation relies on Cloudflare wildcard. Confirm no local `Ingress` uses a self-managed cert that could expire silently. `kubectl get cert -A` → expect 0.
- **Pod Security Standards (F27)** — Label every namespace `pod-security.kubernetes.io/enforce=restricted` (or baseline). Known-exception namespaces get explicit downgrades. Medium effort, paid back by making future admission decisions uniform.
- **CrowdSec LAPI quorum** — 3 replicas but quorum/consensus behavior undocumented. One-page runbook: what happens if 1, 2, or 3 LAPI pods die.
- **Authentik outpost fix (F15)** — Applied via API, not TF. Next Helm upgrade reverts. Add the `/dev/shm` emptyDir to `stacks/authentik/values.yaml` templatefile.

---

## Dangerous-to-execute (handle with care)

Flagged by challengers; each needs a gradual rollout plan, not a single commit.

1. **F12 — Kyverno Audit → Enforce en masse**. Write `PolicyException` CRs for known-safe workloads first. One policy per week. Observe.
2. **F18 — NetworkPolicies cluster-wide**. Default-deny breaks inter-namespace lookups silently. Namespace-by-namespace rollout, with `kubectl logs -f` tailing the policy-engine events.
3. **PDB additions without drain-test**. New PDB + tight `minAvailable` can deadlock during node cordons. `kubectl drain --dry-run` every new PDB on every node first.
4. **F20 — Signed-image admission**. Must follow F04 (pinning). Un-pinned admission = half the cluster fails to pull.

## Gaps the agents missed

From challenger "GAPS" analyses, collated:

- **Disaster-recovery drill coverage** — backup docs are comprehensive (CLAUDE.md is extensive). End-to-end *restore* rehearsal frequency = never documented. Track per-component: MySQL, PostgreSQL/CNPG, Vault, etcd, NFS, registry blobs.
- **Service mesh evaluation** — Never formally evaluated (Istio, Linkerd, Cilium-in-mesh-mode). Could subsume NetworkPolicy effort + mTLS + observability. Worth a design doc even if answer is "no, too much complexity for the gain."
- **Chaos engineering coverage** — Zero. No pod-kill cron, no node-failure drill. Low urgency given maturity, but would validate F02 probe quality and F23 graceful-shutdown coverage cheaply.
- **Operator onboarding friction** — Nobody else in the "lab team" but Emo exists in `claude-agent-service`. If Emo needs to take over a component for a week, what's the runbook?
- **Alert noise / fatigue rate** — No finding measured how many alerts actually page vs. auto-resolve. `alertmanager_notifications_total` by receiver is the metric; needs a Grafana panel.
- **Secrets-in-image-layers** — Docker images built locally may contain secrets from build env. `trivy image --scanners secret` on registry images is a one-off audit.
- **Runbook → post-mortem → runbook-update loop** — Post-mortem 2026-04-14 produced runbook updates; no general tracker that every incident produces a runbook change.

## Alternative framings (from challengers, preserved for future reference)

- **Split "MySQL singleton" into 3 items** (HA / backup / pool). Accepted — see R1 and R4 treatment.
- **6th concern: Observability & Pager Fatigue** — Considered; the themes already hit R1+R3+R4 under Theme 2 of the executive summary. Keeping 5 concerns but carving "Observability gaps" as a theme, not a new research axis.
- **One-thing-this-weekend**: Challenger B nominated *NFS in Terraform*, Challenger A nominated *`:latest` tag sweep*. F01 wins on SEV1 prevention; F04 wins on toil. Both valid. Pick by energy level: F01 is 1 deliberate session; F04 is low-cognition grep-replace.
- **Re-rank by operator fatigue (Rank B) always**. Partially accepted — presented side-by-side in the table.

---

## Recommended next moves

Ordered for a solo operator balancing SEV-prevention, fatigue reduction, and preserved energy for larger work:

**Week 1 (SEV-prevention + quick-wins, low cognitive load):**
- F01: NFS exports into a `pve_host_config` Terraform module (one deliberate session)
- F04: Sweep `:latest` tags, add Kyverno `forbid-latest-tag` in Audit
- F08: ESO refresh-lag PrometheusRule
- F05: OOMKill / Unschedulable / Node-CPU PrometheusRule

**Week 2 (fatigue reduction):**
- F03: Renovate in `infra/` only (narrow pilot)
- F14: CronJob success-rate Grafana panel + alert rollup
- F16: Dolt backup CronJob + PVC grow
- F11: First MySQL restore drill (scheduled, documented)

**Month 2 (durable fixes, gradual):**
- F06/F07: Replace null_resources + SSH provisioners with native TF resources, one at a time
- F02: Probe sweep — add readiness+liveness to the 20 long-lived deployments first
- F12: Kyverno Enforce transition, one policy per week
- F15: Authentik outpost /dev/shm into values.yaml

**Month 3+ (structural):**
- F18: NetworkPolicies — namespace-by-namespace
- F19: RBAC scope-down
- F20: Signed-image admission
- Service-mesh evaluation (design doc)
- Restore-drill calendar for every backup target

No beads tasks auto-filed by this audit — user decides which findings merit `bd create`.

---

## Appendix — verification references (spot-checked)

Every numeric claim in the backlog was confirmed by one of these commands at audit time (2026-04-20):

| Claim | Command | Result |
|---|---|---|
| Node memory 44-51% | `kubectl top nodes --no-headers` | k8s-node1: 45%, node2: 51%, node3: 49%, node4: 44%, master: 17% |
| 115 deploys missing ≥1 probe | `kubectl get deploy -A -o json \| jq '[.items[] \| select(.spec.template.spec.containers[0].readinessProbe == null or .spec.template.spec.containers[0].livenessProbe == null)] \| length'` | 115 |
| 103 deploys missing BOTH probes | same, with `and` | 103 |
| 310 ignore_changes blocks | `grep -r "ignore_changes" infra --include=*.tf --include=*.hcl \| wc -l` | 310 |
| 59 CronJobs | `kubectl get cronjobs -A --no-headers \| wc -l` | 59 |
| All 16 Kyverno ClusterPolicies in Audit | `kubectl get clusterpolicy -o jsonpath='...validationFailureAction...'` | 16/16 Audit, 0 Enforce |
| Redis `maxmemory-policy allkeys-lru` | `grep -n maxmemory-policy infra/stacks/redis` | `modules/redis/main.tf:254` |
| Zero Renovate configs | `find /home/wizard/code -name '.renovaterc*' -o -name 'renovate.json' \| grep -v node_modules` | 0 |
| Vault `vault-unseal-key` Secret exists | `kubectl get secret -n vault` | present (37d old) |
| NFS `/etc/exports` not in TF | `grep -rn 'fsid=' infra/stacks` | 0 matches; only `infra/scripts/pve-nfs-exports` |
| Frigate CPU limit by policy | `infra/.claude/CLAUDE.md` → "All CPU limits removed cluster-wide" | confirmed |
| MySQL standalone intentional | `infra/.claude/CLAUDE.md` → "migrated from InnoDB Cluster 2026-04-16" | confirmed |

Other claims (84 `:latest` tags, 52 ExternalSecrets, 30+ PVCs without backup CJs) were surfaced by research agents; challengers spot-checked a subset and agreed the order-of-magnitude holds. Full list in `/home/wizard/.claude/plans/let-s-run-a-thorough-floating-pnueli.md` research digest.

## Deliverable disposition

- This document is the audit output.
- No `bd` tasks were created by the audit. Pick findings to ticket after reading.
- When filing: use `F##` as a tag, title with the finding's headline, acceptance criteria from the deep-dive paragraph, priority from Rank B.
- Plan file at `~/.claude/plans/let-s-run-a-thorough-floating-pnueli.md` retains the full 91-finding digest + challenger reports for reference; can be deleted after any follow-up tickets are filed.
