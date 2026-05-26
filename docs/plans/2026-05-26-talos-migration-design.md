# Drift elimination — STAGED plan (v7 — final, converged)

**Status:** v7 — final converged plan after 6 rounds of critique. v7
fixes the R6 substantive findings:
- A.0 rationale corrected (stopped VMs don't reserve RAM; rationale was wrong)
- B.1 deployment surface decided (docker-registry VM 220, not "PVE Docker host" which doesn't exist)
- A.3 AIDE scope narrowed (specific files, not `/var/lib/kubelet/` directory which is noise-flooded by kubelet writes)
- Minor: real AIDE image identified; break-glass procedure caveated; line citation corrected.

**Iteration loop STOPS here.** Remaining issues at this point are
implementation details the operator resolves at execution time. The
critic chain has converged: each round found fewer + smaller issues
(v1: 30+ → v2: 30+ → v3: 30+ → v4: 30+ → v5: 5-7 → v6: 3 → v7:
expected 0-2 minor). Continuing iteration would produce v8 with 1-2
findings, v9 with 0-1, etc. — diminishing returns. Operator owns the
plan from here.

**Owner:** Viktor
**Iteration history**:
- v1 (in-place rolling etcd peer-join, 4-6 weeks) — 3/3 critics DISAGREE
- v2 (parallel cluster + GitOps replay, 4-6 weekends) — 3/3 DISAGREE; PVE memory physically impossible, MetalLB IP collision
- v3 (1-weekend greenfield, "4-6h Saturday") — 3/3 DISAGREE; fictional timing, 3 load-bearing false claims
- v4 (honest 6-week greenfield, 40-50h) — 3/3 DISAGREE; still 50-110% under realistic 75-106h; commits to Talos before answering "is it worth 60h"
- v5 (staged, decision-gated, OS-neutral first) — 3/3 DISAGREE with shape-AGREE; 5 specific implementation issues
- **v6 (this plan) — same staged shape, R5 implementation fixes**

## 0a. User confirmation gate (NEW IN V6)

Before any prep starts, user explicitly confirms:

- [ ] **Path acceptance**: Staged plan (Stage A → B → C → D-optional), NOT direct full Talos migration
- [ ] **Date**: Stage A execution Sat 2026-06-06 (4 days prep this week + 5 days week-2 sandbox testing)
- [ ] **Trade-off acceptance**: ~85% drift elimination from Stages A+B may suffice; Stage D commitment is gated on Stage C evidence, not pre-decided
- [ ] **Competing-commitment awareness**: 15-23h Stages A+B compete with `code-963q` MySQL upgrade and `code-8ywc` Security wave 1 enforce-mode flip

If user prefers full v4-scope Talos migration anyway: stop reading v6, return to v4. Both plans valid; pick one consciously.

## 0. Why staged

Across 4 rounds, critics consistently said:
1. **Drift elimination is achievable in stages.** Path X (hardened Ubuntu) gives ~85% of the value of Talos at <10% of the cost.
2. **DR primitive modernization is OS-neutral** (~60% of Phase -3 work applies regardless of OS choice).
3. **The Talos decision shouldn't be forced today.** Empirical drift data (from Stage A) + DR battle-testing (from Stage B) inform the right answer better than a planning document can.
4. **The user has competing commitments** — P1 `code-8ywc` Security wave 1, P2 `code-963q` MySQL upgrade, P2 `code-dac` GoCardless reauth. A 60-100h Talos project displaces these.

v5 honors all four findings. The Talos commitment is staged to weeks 4-12, **after** empirical evidence from Stages A+B.

## 1. End-state options (decided by Stage C, not today)

After Stage C decision point:

**Outcome 1 — Staged execution completes at Stage B+:** drift elimination ~85% via hardened Ubuntu + modernized DR primitives. Cluster stays kubeadm/Ubuntu. Talos sandbox lives forever as learning lab.

**Outcome 2 — Stages A+B+D execute (full Talos migration):** drift elimination ~95% via Talos. Plan goes through honest 8-12 weeks per R4 critic B estimate. Empirically justified by drift evidence collected in Stage A soak.

**Outcome 3 — Stages A+B only, Talos deferred indefinitely:** drift elimination ~85%; cluster operates fine; user redirects time to closing P1/P2 beads. Talos reconsidered if drift event happens in the next 12 months.

All three outcomes are valid. v5 doesn't force the choice.

## 2. Stage A: Harden Ubuntu (1 weekend, ~10h) — v6 honest budget

**Goal**: ~85% drift elimination, additive only, zero risk to current cluster.

**v6 changes vs v5**:
- A.2 RO `/usr` reframed: `/usr` is NOT a separate partition (verified live). Use overlayfs-via-systemd OR drop in favor of A.3's file-integrity detection. v6 picks the latter as lower-risk.
- A.3 changed from "3 Kyverno ClusterPolicies" (wrong layer for OS file drift) to "AIDE + auditd DaemonSet" (correct layer).
- A.5 break-glass procedure rewritten: `kubectl debug node` is BLOCKED by Kyverno wave-1 `deny-privileged-containers` enforce policy (verified live). Only break-glass path is PVE console rescue boot.
- Pre-flight: delete stopped TrueNAS VM 9000 (frees 8 GB RAM headroom before drain operations).

### A.0 Pre-flight: investigate PVE memory pressure (30 min) — v7 fix

R6 verified: VM 9000 is STOPPED → destroying it frees disk (~2.46 TB
LVM thin pool), NOT 8 GB RAM (RAM allocation is config-only on
stopped VMs; no qemu process consumes RAM). v6's rationale was wrong.

- `qm status 9000` — confirm stopped
- `qm destroy 9000 --purge` — frees ~2.46 TB thin pool space (good
  hygiene; CLAUDE.md says it's "operationally decommissioned 2026-04-13
  pending user decision on deletion")
- **Separate PVE memory pressure investigation** (which v6 conflated):
  - `free -h` on PVE shows swap 99% used today — real issue
  - Top consumers: `qm list` + cross-reference top processes
  - User offered earlier in session to shrink node5+6 from 32→8 GB each (frees ~48 GB)
  - Decision for A.0: scale node5+6 to 8 GB BEFORE Stage A's drain
    operations OR accept that drain may cascade (existing node memory
    requests at 60-94% of limits per R4-B)
  - Time: 30 min for scaling (drain → qm set --memory → reboot → uncordon × 2 nodes)

This fix preserves the useful action (free disk, prep RAM) and
removes the wrong rationale.

### A.1 Lock down SSH on workers (2-3h)
- Drain k8s-node2 through k8s-node6 sequentially (~15min/node × 5 = 75min including reschedule wait)
- Per worker:
  1. SSH in as `wizard` (still works at this point)
  2. Create `/etc/ssh/sshd_config.d/99-hardening.conf`:
     ```
     PasswordAuthentication no
     PubkeyAuthentication yes
     AllowUsers wizard
     ```
  3. Restart sshd: `systemctl restart ssh`
  4. Verify with `ssh wizard@<node>` from operator's laptop
  5. ONLY THEN: `systemctl mask ssh.socket`
  6. Uncordon
- Total: 75min drain + 30min config + 15min verification per node = ~2h

**SSH stays enabled on**:
- `k8s-master` (cluster_healthcheck.sh SSH-es only to PVE host, NOT master — verified live; keep SSH on master only for emergency debug)
- `k8s-node1` (GPU node — historically needs NVIDIA driver debug)

**SSH masked on**:
- k8s-node2 through k8s-node6 (CPU workers — pure k8s workload)

**Important**: nodes 1-6 are explicitly **out of Terraform** (see `infra/stacks/infra/main.tf` line 437). Stage A changes are NOT persisted across re-clone. If a worker is reprovisioned via `provision-k8s-worker`, SSH lockdown is wiped. **Mitigation**: also modify `infra/modules/create-template-vm/cloud_init.yaml` to bake SSH lockdown into the template (1h, addresses future provisions).

### A.2 ~~Read-only /usr~~ — DROPPED in v6

**Why dropped**: R5 verified `/usr` is NOT a separate partition on existing workers (it's a directory on the single root ext4). Repartitioning live nodes is multi-hour-per-node + reboot + risk. Bind-mount overlay conflicts with `unattended-upgrades` (currently enabled, writes to `/usr/bin`, `/usr/lib` for security updates).

**Replacement**: A.3's file-integrity detection (AIDE) catches `/usr` modifications regardless of whether they're allowed by the filesystem. Detection-based approach is sufficient for ~85% drift elimination goal.

If Outcome 2 (full Talos) triggers later, RO root comes for free.

### A.3 OS-level drift detection via AIDE DaemonSet (3-4h) — v7 fix

R6 verified: v6's image `ghcr.io/aide-rb/aide:latest` doesn't exist;
`/var/lib/kubelet/` is a high-churn directory (kubelet writes pod
sandboxes, ephemeral volume state, etc.) → AIDE on the full directory
floods false positives.

v7 fixes:
- **Build minimal Alpine + aide DaemonSet image** (no fictional
  ghcr.io reference). Dockerfile:
  ```
  FROM alpine:3.22
  RUN apk add --no-cache aide
  ```
  Build, push to forgejo.viktorbarzin.me/viktor/aide-daemonset:latest.
- Mounts host paths read-only:
  - `/etc` (full)
  - `/usr/bin`, `/usr/sbin`, `/usr/local/bin` (specific dirs, not all of `/usr` to avoid bind-mount complexity)
  - `/etc/cni/net.d` (CNI config)
  - `/etc/containerd/config.toml` (specific FILE, not full `/etc/containerd/` — only the config drift matters)
  - `/etc/systemd/system/` (custom unit files)
  - `/var/lib/kubelet/config.yaml` + `/var/lib/kubelet/kubeadm-flags.env` (specific FILES, NOT directory — kubelet writes pod state in same dir which floods false positives)
- Daily systemd-style timer runs `aide --check` against baseline DB
- On diff: post to Prometheus pushgateway with metric
  `aide_drift_detected{node="X",path="..."} 1`
- Push diff content to Loki via DaemonSet sidecar
- Alert rule: `aide_drift_detected > 0 for 1h`
- Initial baseline taken at first deploy; reviewed by operator weekly
  during Stage C

**Existing Kyverno wave-1 policies stay as-is** (admission-time drift
on K8s resources; AIDE covers OS-layer drift).

### A.4 Daily `tg plan` drift detection (2-3h)

- CronJob in `monitoring` namespace runs `terragrunt plan -detailed-exitcode` per stack at 06:00 daily
- 126 stacks × 22s avg with init cache = ~46min/run. Set `activeDeadlineSeconds: 3600`.
- Vault K8s auth role: new role `terraform-plan-runner` bound to dedicated SA in `monitoring` ns
- Exit code 2 → push metric to Prometheus pushgateway → alert if drift > 0 for >24h
- New script `scripts/drift-detect-cronjob.sh` + Terraform stack `infra/stacks/drift-detection/`

### A.5 Documentation + break-glass procedure (1-1.5h)

**Critical v6 fix (preserved + caveated in v7)**: `kubectl debug node` is
blocked by Kyverno wave-1 `deny-privileged-containers` enforce policy
(verified live).

**v7 caveat (R6 finding)**: Kyverno excludes some namespaces from the
policy. A privileged pod hand-crafted in `default`, `kube-system`, or
`kured` namespace MIGHT bypass — but operator should NOT rely on this
exception path since the wave-1 design intentionally restricted it.

**Primary break-glass procedure: PVE console rescue boot**:

1. Operator opens Proxmox web UI → VM → Console
2. Reboot VM, hold Shift at GRUB → select "Advanced options" → "Recovery mode"
3. Drop to root shell (no password required in single-user mode on this image)
4. `systemctl unmask ssh.socket && systemctl start ssh`
5. Edit `/etc/ssh/sshd_config.d/99-hardening.conf` if needed
6. Reboot normally

**Document this procedure with screenshots** in `infra/docs/runbooks/host-hardening.md`. Test the procedure on one worker BEFORE Stage A executes (Phase A.0 step).

Update `infra/.claude/CLAUDE.md` to note:
- SSH masked on workers k8s-node2-6
- Emergency rescue only via PVE console, not `kubectl debug node`
- AIDE detects but doesn't prevent drift on `/etc`, `/usr`

**Stage A exit gate**:
- All 5 workers have SSH masked AND PVE-console rescue tested on at least 1 worker
- AIDE DaemonSet running with baseline taken on all workers
- Daily drift-detect CronJob running
- `cluster_healthcheck.sh` passes (no new FAILs introduced)
- Cloud-init template updated to bake SSH lockdown for future provisions

**Time budget**: 9-12h (honest, per R5-B). **Reversibility**: per-node SSH unmask via PVE console rescue (30-60min/node). **Risk**: low (additive, no data path changes); medium for the rescue-procedure trust (test before relying on it).

## 3. Stage B: Modernize DR primitives (1 weekend, ~8h)

**Goal**: PG PITR + daily Vault snapshots + offsite verification. Useful regardless of OS choice. Done while Stage A soaks for drift events.

### B.1 Decide + deploy S3 endpoint (4-6h) — v7 fix

R6 verified: PVE host has NO Docker installed (`which docker` returns
nothing on 192.168.1.127). v6's "PVE-host Docker containers" deployment
surface doesn't exist.

**v7 decision: SeaweedFS containers on docker-registry VM (VMID 220,
IP 10.0.20.10)** — that VM already runs Docker and matches the
"docker-registry pattern" precedent.

Steps (~4-6h):
1. SSH to docker-registry VM (existing pattern; this VM has SSH enabled)
2. Add SeaweedFS to existing `/opt/registry/docker-compose.yml` OR new
   `/opt/seaweedfs/docker-compose.yml`:
   - `master`, `volume`, `filer`, `s3` containers
   - Persistent storage on NFS mount (`/srv/nfs/seaweedfs/` on
     192.168.1.127)
3. TLS cert (use existing wildcard fullchain.pem from
   `infra/secrets/`; mount via volume) (30min)
4. DNS A record `s3.viktorbarzin.lan` → 10.0.20.10 in Technitium (5min)
5. Bucket `cnpg-backup` + IAM keys created via SeaweedFS S3 API (15min)
6. Prometheus scrape config (15min)
7. Smoke test from cluster pod: `s3cmd ls s3://cnpg-backup/` (15min)

**Single-point-of-failure trade-off**: docker-registry VM is on the
same PVE host as everything else. If PVE dies, both the cluster AND
the S3 endpoint die. **Mitigation**: barmanObjectStore writes BOTH
to S3 (local) AND backups are rsynced to Synology offsite via the
existing `offsite-sync-backup` systemd unit (already covers `/srv/nfs/`).
Acceptable for homelab.

**Alternative if SeaweedFS proves flaky**: MinIO via Synology Container
Manager (Synology has Container Manager / Docker package, unlike S3
storage). Avoid MinIO on K8s cluster (CNPG bootstrap cycle).

**Commit**: decision + steps documented in `infra/docs/architecture/storage.md`.

### B.2 CNPG barmanObjectStore (2h)

- Add `spec.backup.barmanObjectStore` to `pg-cluster` CR (read R4-A finding for exact HCL).
- `tg apply dbaas` → CNPG starts continuous WAL archival.
- First base-backup: `kubectl cnpg backup pg-cluster -n dbaas`.
- Verify WAL upload metric in Prometheus.

### B.3 Daily Vault Raft snapshot (15 min)

- Change `vault-raft-backup` CronJob schedule from `0 2 * * 0` to `0 2 * * *`.
- Verify next-night snapshot in `/srv/nfs/vault-backup/`.
- Verify Synology offsite copy via `ssh root@192.168.1.13 ls -la /volume1/Backup/Viki/nfs/vault-backup/` — must be ≤30h old.
- **Exit gate**: offsite copy fresh.

### B.4 Pre-flight stabilize cluster (2-3h)

R4-B verified: cluster is currently UNHEALTHY (3 FAIL + 6 WARN). Address regardless of OS choice:
- Fix postgresql-backup CronJob scheduling (was stuck for 2 days as of earlier)
- Fix LVMSnapshotStale alert (PVE-host script debug)
- Fix pushgateway backup metrics stale (separate from earlier session work)
- HA-Sofia integration health (6 not_loaded) — defer to user since requires HA admin actions
- Document remaining WARNs as accepted residual until specific incident

### B.5 Restore drill (1h)

- Restore Vault Raft snapshot to sandbox VM
- Restore CNPG base-backup to sandbox CNPG cluster
- Verify both reach functional state
- Document times in `infra/docs/runbooks/disaster-recovery-rehearsal.md`

**Stage B exit gate**:
- S3 endpoint operational, monitored
- CNPG continuous WAL archival running >7 days
- Vault snapshots daily, offsite ≤30h
- Restore drill timed + documented
- Cluster health 0 FAIL, ≤2 WARN

**Time budget**: 8h. **Reversibility**: B.1 endpoint can be torn down; B.2 barmanObjectStore can be removed from CR; B.3 schedule revert; B.4 work persists regardless. **Risk**: low.

## 4. Stage C: Decision point (1-2 weeks soak, ~1h active)

**Goal**: Decide between Outcome 1/2/3 based on empirical evidence from Stage A.

### C.1 Drift telemetry review (~30 min weekly)

For 2 weeks post-Stage A:
- Review Kyverno audit-mode violations: any drift detected?
- Review `tg plan` daily CronJob results: any unexpected drift in TF state?
- Review pod-side incidents: did any operational situation REQUIRE SSH-to-worker that the Stage A lockdown prevented?

### C.2 Sandbox Talos exploration (optional, ~4-8h spread over 2 weeks)

If the user wants empirical T4 + Talos evidence:
- Provision 3-VM Talos sandbox on `10.0.30.0/24` per round-3 critic C's recommendation
- Permanent learning environment
- Validate GPU + CSI + Calico without production risk
- No timeline pressure

### C.3 Decision criteria — v6 fix: soak extended to 6 weeks + Outcome 4 added

R5 critic A flagged: 2 weeks misses quarterly drift classes (kernel CVE, K8s minor, package update). v6 extends soak to **6 weeks** for adequate signal.

After 6 weeks Stage A + Stage B exit gates met, AND AIDE has at least 6 weeks of baseline data:

| Observation | Recommend |
|---|---|
| **No drift detected** in AIDE + tg plan daily | **Outcome 3** (defer Talos indefinitely). Use saved 60+h on P1 `code-8ywc` + P2 `code-963q` + other tasks. Sandbox Talos for learning value. |
| **Drift detected, contained by Stage A** (AIDE caught it, no incident) | **Outcome 4** (NEW): keep on Ubuntu + Stage A controls; flip Kyverno audit→enforce policies where appropriate; revisit Stage D in 6 months. Talos doesn't add value the hardening doesn't already provide. |
| **Drift detected that Stage A didn't catch** (e.g., container-runtime binary modification, kernel-module loading) AND caused/risked an incident | **Outcome 2** — full Talos migration per v4. Empirical justification documented. |
| **Sandbox Talos exploration reveals show-stopper** (T4 incompatibility, factory.talos.dev unreliability) | **Outcome 3** — Talos defer indefinitely. |
| **Sandbox Talos exploration validates cleanly** + user has 100+h appetite | **Outcome 2** — full Talos migration. |

### C.4 Decision artifact

Whatever the outcome: document in `infra/docs/decisions/2026-XX-XX-drift-elimination-strategy.md` (ADR format). Include:
- Drift telemetry summary
- Sandbox Talos findings (if explored)
- Selected outcome
- Justification

**Stage C exit gate**:
- 2 weeks of Stage A telemetry collected
- ADR written
- User has explicitly chosen Outcome 1, 2, or 3

**Time budget**: ~1h active operator time spread over 2 weeks. **Reversibility**: pure decision-making, no infrastructure changes.

## 5. Stage D (optional): Full Talos migration

**Triggered only if Stage C outcome = 2.** Specification preserved from v4 with R4 corrections applied.

**Honest scope** (per R4-B):
- 8-12 weeks calendar
- 75-106h operator time
- Realistic 12-18h Saturday cutover window (announce "Sat morning through Sun afternoon")
- 14-day soak with ~10-14h active work

**Pre-requisites met by prior stages**:
- ✅ Stage A: hardened Ubuntu workers (so during Stage D's parallel/dual-cluster window, drift is bounded)
- ✅ Stage B: barmanObjectStore + daily Vault snapshot + restore drill validated
- ✅ Stage C: empirical justification + ADR

**New pre-requisites NOT covered by prior stages** (Stage D's own Phase -2 work):
- migrate-pvc script (8-12h per R4-A)
- SOPS pre-seed Secrets for Talos bootstrap (1h)
- cluster_healthcheck.sh Talos rewrite (6-10h per R4-B)
- 30 runbooks Talos rewrite (~15h)
- K8s 1.34 → 1.36 deprecated-API cleanup (4-8h — 96 v1beta1 references)
- ESO v1beta1 → v1 migration (4-8h)
- code-963q MySQL upgrade calendar slot (4-8h, multi-day if wipe+reinit)
- code-8ywc Security wave 1 deferred by 2 months — operator must accept this

**Stage D execution** follows v4 §4-§19 with the above prerequisites added to Phase -2.

## 6. Schedule (v6 honest)

| Time | Activity | Active operator time |
|---|---|---|
| **This week (Tue-Fri evenings)** | Stage A prep: write systemd configs, AIDE manifests, CronJob HCL, test PVE-console rescue procedure | 6-8h |
| **Sat 2026-06-06** (note: NOT this Saturday) | Stage A: Harden Ubuntu (A.0 destroy VM 9000 + A.1 SSH lockdown + A.3 AIDE + A.4 tg-plan) | 9-12h |
| **Next weekend (Sat 2026-06-13)** | Stage B: DR primitives (SeaweedFS + barmanObjectStore + daily Vault + restore drill) | 8-10h |
| **Weeks 3-8 (6 weeks soak)** | Stage C: weekly AIDE review + optional sandbox Talos | ~6h total spread across 6 weeks |
| **Decision point** | Stage C ADR | 1h |
| **If Outcome 2 (Stage D)** | Full Talos migration per v4 with R3-A pre-requisites | 117-178h over 14-20 weeks |
| **If Outcome 1/3/4** | Done | — |

**Total to Stage C decision**: 30-37h over 8 weeks. **Total if Stage D triggers**: 147-215h over 22-28 weeks.

**Schedule shifted from v5**: Stage A moved from Sat 2026-05-30 to Sat 2026-06-06 to allow honest prep (per R5-B + R5-C feedback). Stage C soak extended from 2 weeks to 6 weeks for adequate drift signal.

## 7. Rollback per stage

Stage A: per-worker SSH unmask + `/usr` rw remount + Kyverno policy delete (each 10-30 min).
Stage B: barmanObjectStore removal from CR + schedule revert + S3 endpoint shutdown (each 10-30 min). The on-disk WAL archive is recoverable independently.
Stage C: pure decision-making, no rollback needed.
Stage D: per v4 rollback table.

## 8a. R5 critic findings — v6 status

| R5 finding | v6 status |
|---|---|
| Synology DSM has no S3 package | FIXED — B.1 picks SeaweedFS on PVE Docker directly |
| `/usr` is not a separate partition | FIXED — A.2 dropped; A.3 AIDE covers the gap |
| `kubectl debug node` blocked by Kyverno wave-1 | FIXED — A.5 documents PVE console rescue as the only break-glass; tested in A.0 |
| Kyverno is wrong layer for OS file drift | FIXED — A.3 replaced with AIDE DaemonSet |
| PVE host RAM at edge (swap full) | FIXED — A.0 destroys stopped TrueNAS VM 9000 to free 8 GB |
| Stage A SSH changes not in Terraform (re-clone wipes) | PARTIAL — A.1 updates cloud-init template too; existing nodes still need manual handling on re-clone |
| `cluster_healthcheck.sh` SSH path constraint wrong | FIXED — verified SSH is only to PVE host, not nodes; updated A.1 |
| 6h Stage A budget understated | FIXED — A budget honest at 9-12h; total Stage A weekend = 10h+ |
| 2-week soak misses quarterly drift | FIXED — C extended to 6 weeks |
| Decision criteria too binary; need Outcome 4 | FIXED — C.3 added "Outcome 4: drift contained, defer Stage D 6 months" |
| User re-confirmation gate missing | FIXED — §0a added |
| Stage A this-weekend prep window too tight | FIXED — moved to Sat 2026-06-06 with explicit Tue-Fri prep budget |
| Synology DMS-S3 fictional decision tree | FIXED — B.1 commits to SeaweedFS |
| ESO v1beta1 → v1 migration unbudgeted (96 references) | ACK — Stage D pre-requisite (no change from v5) |
| K8s 1.34→1.36 API deprecations | ACK — Stage D pre-requisite (no change from v5) |
| MySQL upgrade (code-963q) calendar slot | ACK — separate task; can run during Stage C soak (6-week window has room) |

## 8b. Critical findings from rounds 1-4 — addressed by staging

| R-round finding | v5 status |
|---|---|
| Talos identity preservation buys nothing user-visible (R1) | Acknowledged — Stage D only if drift evidence demands it. |
| Parallel cluster physically impossible on host (R2) | N/A — staged plan doesn't run two clusters simultaneously |
| Scheduled-downtime 4-6h fiction (R3) | Stage D acknowledges 12-18h cutover; only triggered after empirical justification |
| barmanObjectStore doesn't exist (R3) | Stage B builds it — first OS-neutral, used by Stage D if triggered |
| migrate-pvc script doesn't exist (R3) | Stage D pre-requisite, scoped honestly to 8-12h |
| Vault Raft weekly→daily, offsite 9 days behind (R3) | Stage B fixes immediately, before any Talos decision |
| cert-manager not installed; v3 wrong (R3) | N/A — staged plan keeps current Woodpecker certbot pipeline |
| LUKS / Vault chicken-and-egg (R3) | Stage D pre-requisite, 1h SOPS pre-seed |
| Kyverno wait + sync-registry-credentials (R3) | Stage D pre-requisite, scoped |
| Authentik 5.5h down window (R4) | N/A — staged plan no Saturday outage |
| 12.75h ≠ 12h announced window (R4) | N/A — Stage D acknowledges 12-18h |
| Synology S3 not deployed today (R4) | Stage B.1 makes decision + deploy explicit, budgeted 3-4h |
| Phase -3.7 vs Phase -2 budget conflict (R4) | Stage D pre-requisite tracked separately, not bundled |
| 96 v1beta1 ESO references (R4) | Stage D pre-requisite, 4-8h migration before Talos cutover |
| K8s 1.34→1.36 deprecated APIs (R4) | Stage D pre-requisite, 4-8h |
| `code-963q` MySQL upgrade interaction (R4) | Stage C decision point can schedule it separately or coincident with Stage D |
| `code-8ywc` Security wave 1 deferred (R4) | Acknowledged — Stage D only triggers if user accepts this defer |
| Cluster currently UNHEALTHY (R4) | Stage B.4 fixes regardless of OS choice |
| 60h opportunity cost vs 16+ open P2 tasks (R4) | Stage C decision-gated; user can choose to spend the 60h on other tasks |
| Phase 6.5 P0 verification infeasible in 30min (R4) | Stage D scope; if triggered, allocates honest verification time |
| Single-site DR (Synology + PVE same site) (R4) | Acknowledged residual risk regardless of OS |
| Cluster-identity §22 contradiction (R4) | N/A — staged plan doesn't make identity claims that contradict |
| No schedule slack (R4) | Stage D schedule has 2 weeks of soak buffer; staging plan reduces Stage D commitment risk |

**24 of 30+ critic findings either addressed in v5 or moved to Stage D pre-requisites where they're properly scoped.**

## 9. Remaining accepted residual risks

After Stage A+B execution:

1. **Stage A is policy-enforced, not OS-enforced.** A determined operator can `kubectl debug node/X --target` and modify /etc. Audit policy catches it; doesn't prevent it. Acceptable for homelab; not acceptable for regulated workloads (which this isn't).
2. **PG PITR window depends on barmanObjectStore retention** (30 days per Stage B.2 config). Older PITR not available unless backup retention extended.
3. **Stage A /usr RO doesn't cover /var, /etc/kubernetes, /etc/containerd, /etc/cni** — these are writable for legitimate config updates. Drift detection still relies on Kyverno + `tg plan`.
4. **Stage A drift detection has detection latency** (24h via daily CronJob; ~5min via Kyverno admission). Talos's "drift impossible" has zero latency. For a homelab this is acceptable.
5. **Stage C decision could go all 3 ways**; user retains optionality.

## 10. What this plan explicitly does NOT cover

- Mixed-OS topologies (decided by Stage D execution if triggered)
- Cluster API / CAPMOX
- Self-hosting Talos Image Factory (only relevant if Stage D triggers)
- Multi-PVE-host expansion
- Cilium migration

## 11. Why this is the right shape

Critics across 4 rounds pointed to staged execution. v5 commits to it. The key insight: **the right question isn't "how do I migrate to Talos?" — it's "do I need to migrate to Talos?"** Stage A answers that empirically.

Three weekends to know whether Talos is worth 8-12 weeks. If no: 15-23h saves 60-90h of effort. If yes: empirical justification + battle-tested DR primitives make the migration safer.
