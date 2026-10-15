# Keeping the homelab current and CVE-aware

- Status: executing
- Date: 2026-10-09
- Decision record: ADR-0030 (Renovate lands version bumps straight to master, with CI rails and no agent)
- Origin: Muse flagged CVE-2026-88879 in Traefik on 2026-10-08. Traefik was on v3.7.1 while v3.7.14 existed. Viktor asked what our posture is against upgrades like this and wants the cluster always on the latest software.

## Goal

1. Every component moves to new upstream versions without someone having to notice first, including majors, cluster operators and database engines.
2. Every automated upgrade proves the component still works before it counts as landed, with the deepest checks on databases and the GPU stack.
3. A fixable, high-severity CVE on an internet-reachable workload reaches Slack within a day, without depending on an outside tool noticing it.
4. If the upgrade automation itself stops running, we hear about it.

## What exists today (measured 2026-10-09)

| Layer | Mechanism | State |
|---|---|---|
| Node OS | unattended-upgrades + kured, gated by upgrade-gate alerts | Working |
| Kubernetes components | daily detection CronJob + phase Job chain | Working |
| App images | Keel, injected by the Kyverno `inject-keel-annotations` policy | 159 deployments `patch`, 63 `never`, 5 `minor`, 4 `major`, 4 `force` |
| Helm charts and Terraform image pins | none automatic | 28 `helm_release`; 21 pinned, 7 with no `version` at all |
| DIUN → n8n → service-upgrade agent | workflow active | Last agent upgrade commit 2026-04-19 (see below) |
| CVE scanning | none | |

The DIUN filter passes only `status=update` (same tag, new digest) and drops `new` (a new tag). Real version bumps arrive as `new`, so the upgrade agent has received digest re-pushes but no version bumps since April. `docs/architecture/automated-upgrades.md` describes the filter as intended.

The weekly "upgrade report" (`k8s-upgrade-nightly-report`) covers Kubernetes components only. The DIUN stack comment and `automated-upgrades.md` point readers at it as if it covered images.

### Drift on the Helm-managed layer

```stats
~25 | Vault CVE fixes missing
34 months | Prometheus age
7 of 28 | charts with no pin
2026-04-19 | last DIUN agent upgrade
```

| Component | Running | Latest | Public |
|---|---|---|---|
| Prometheus | v2.48.1 (Dec 2023) | v3.15.0 | yes, behind Authentik |
| Alertmanager | v0.26.0 | v0.34.1 | yes, behind Authentik |
| Vault | 1.18.1 | 2.1.2 | yes, Vault's own auth only |
| Nextcloud | 32.0.14 | 35.0.1 | yes, app login |
| Calico | 3.30.7 | 3.33.0 | |
| GPU operator | 25.10.1 | 26.7.1 | |
| External Secrets | 2.6.0 | 2.12.0 | |
| CNPG | 1.28.1 | 1.30.1 | |
| CrowdSec | 1.7.8 | 1.8.1 | |
| Woodpecker | 3.14.1 | 3.19.0 | yes, app login |
| Traefik, Authentik, Keel | current | | |

Vault 1.18.1 is missing roughly 25 Community-relevant CVE fixes, including CVE-2025-6000 (critical, audit-plugin RCE, fixed in 1.20.1). HashiCorp now ships Community patches only on the newest line, so every one of those fixes means moving to 2.1.2. The CVE list came from a research pass and has not been checked ID by ID against the HCSEC posts.

The 2026-04-20 infra audit (`docs/plans/2026-04-20-infra-audit-design.md`, finding F03) recommended Renovate as its first "do first" item.

## Design

Renovate-owned pins land through the rails in the existing Woodpecker pipeline:

```mermaid
flowchart TD
  R[Renovate<br/>every 10m, 1 bump] -->|commit| W[Woodpecker]
  W --> G{upgrade-gate<br/>alerts clear?}
  G -->|no| H[hold]
  G -->|yes| S[snapshot<br/>if stateful]
  S --> A[terragrunt apply]
  A --> V{health check}
  V -->|pass| OK[done]
  V -->|fail| RV[revert +<br/>page]
```

Every third-party version, apps included, moves through that path; Keel is retired. Trivy findings route by severity and exposure:

```mermaid
flowchart TD
  T[Trivy Operator] --> Q{fixable Crit/High<br/>on public,<br/>or secret?}
  Q -->|yes| AL[Slack<br/>#alerts]
  Q -->|no| D[weekly<br/>digest]
```

### Ownership of versions

| What | Owner |
|---|---|
| `helm_release` chart versions (all 28, after pinning the 7 unpinned ones to their live versions) | Renovate |
| Every third-party image pin in `.tf` and Helm values: about 230 apps (moved from Keel at their live tags), chart `tag` values, and the 91 `:latest` pins (pinned to the concrete version they run today, or by digest where an image publishes no version tags) | Renovate |
| Database engines: pg-cluster image, MySQL (latest innovation release), Redis, ClickHouse, Dolt | Renovate |
| Immich Postgres | Renovate, tracking the `immich-app/postgres` tag in Immich's own release compose |
| Our own images (`viktorbarzin/*`, `ghcr.io/viktorbarzin/*`), deployed by their CI | unchanged (existing build and deploy path) |
| Base images and language dependencies in our own image repos that opt in with `renovate.json` (Forgejo and GitHub) | Renovate, gated by that repo's own CI |
| Node OS packages, Kubernetes components | unchanged (unattended-upgrades + kured, k8s version chain) |

### Verification contract

An upgrade counts as landed only when the component's checks pass. Checks run as Kubernetes Jobs from a `verify` script kept next to each stack, so they can be run by the Woodpecker rails or by hand.

As built (2026-10-10): `scripts/verify/run <stack>` starts a Job in the `verify` namespace that runs the floor (`scripts/verify/lib.sh`) and `stacks/<stack>/verify.sh`, streams the log, returns pass/fail and deletes the Job. All 30 stacks in the chart, database and GPU groups have a script and passed against the versions running that day; a stack in those groups without one exits 3. Database probes log in over the network as a `verify_probe` user (Vault static roles through ESO) rather than exec into database pods. Usage and the per-stack checks: `docs/runbooks/verify-jobs.md`.

| Component | Checks |
|---|---|
| Floor (everything) | rollout complete within 10 minutes, ingress HTTP check where one exists, no new firing alerts in the component's namespaces for 10 minutes |
| Charts, databases, GPU stack | the floor, plus its own `verify` script exercising real function. Fail closed: a component in these groups without a script does not auto-land |
| Databases | operator or cluster healthy and replication lag 0; a scratch table written, read back and dropped; extensions load and answer a query where used (postgis, vector, vchord); every dependent app passes its own check; the backup job runs successfully on the new version |
| GPU stack (gpu-operator, driver, toolkit, device plugin) | `nvidia.com/gpu` allocatable still 100 and validator pods succeed; a test pod runs `nvidia-smi` and a small CUDA operation; one real inference each on llama-swap (`/v1/chat/completions`), Immich ML (`/predict`) and Frigate (`/api/stats` detector inference speed); DCGM metrics (`nvidia_tesla_t4_DCGM_*`) still flowing |
| Apps | the floor, plus the app's `verify` script where one exists. Apps go through the same rails as everything else: snapshot if stateful, and revert plus skip-that-version on failure |

Inventory behind these checks (2026-10-09):

- Databases: CNPG `dbaas/pg-cluster` (PG 16.9, 3 instances, 34 databases, custom `cnpg-postgis-pgvector` image), Immich PG 15.14 (vchord 0.4.3, vector 0.8.1), MySQL `mysql-standalone` 8.4.8 (20 schemas), Redis 8.10.0, ClickHouse 25.4.13 (rybbit), Dolt 2.0.7 (beads), Vault raft.
- GPU: one Tesla T4 on node1, time-sliced to 100 slots, driver 570.195.03 compiled at runtime. Live consumers: llama-swap, Immich ML and worker, Frigate, claude-memory, f1-stream, stremio, android-emulator.

### Database and GPU upgrade paths

- **pg-cluster majors** use CNPG's declarative offline in-place upgrade (since CNPG 1.26; we run 1.28.1) after a fresh `pg_dumpall`. Each new major needs our `cnpg-postgis-pgvector` image built for it first. After the upgrade, run the `update_extensions.sql` that `pg_upgrade` writes and an `ANALYZE`. The backup CronJob clients (`postgres:16.15-trixie`, dbaas and Immich) move in the same change, because `pg_dump` 16 refuses a PG 17 server.
- **Immich PG** moves only when Immich's release compose moves its tag. A major is an automated dump, image swap and restore, followed by the DB checks and a smart-search query.
- **MySQL** tracks the latest innovation release. It upgrades in place after a dump; the 2026-09-04 rehearsal measured an 8.4 patch upgrade at 25 s end to end.
- **Redis, ClickHouse, Dolt** upgrade in place after their backup runs.
- No restore test before DB upgrades. Recovery from a failed major is a manual restore from the pre-upgrade dump.
- **GPU node kernel stays held** at 6.8.0-117. The driver compiles against kernel headers at runtime, and the 2026-05-17 post-mortem covers what happens when the headers are missing. Everything above the kernel upgrades automatically under the GPU checks. A kernel move becomes a supervised step when a driver version supports a newer kernel whose headers exist in the repos.

### Phase 1: supervised Vault and Prometheus upgrades

These two go first because both are reachable from the internet and are one to three years behind. They are done by hand, one hop at a time, with the result checked after each.

**Vault 1.18.1 → 2.1.2**, stepping each line: 1.19.5 → 1.20.4 → 1.21.4 → 2.1.2. HashiCorp neither certifies nor forbids the direct skip, and Vault holds the secrets behind 138 ExternalSecrets, so each line gets its own hop.

- Before each hop: `vault operator raft snapshot save` to the existing NFS backup target, checked for size and readability.
- The `auto-unseal` sidecar (`stacks/vault/main.tf:216`) and the `vault-raft-backup` CronJob image (`:435`) are pinned separately and move with the chart.
- Skip 2.0.1 (IPC_LOCK regression).
- Already compatible: audit file mode `-rw-------` (CVE-2025-6000 unseal refusal does not apply), lowercase dot-free policy names, `file_path` set on the audit device, `disable_mlock` appended by the chart.
- To check before the 2.x hop: `audience` on the 6 Kubernetes auth roles, and duplicate-attribute HCL in policies (2.0.4+ fails to parse those).
- Verified after each hop: all 3 pods unsealed with one leader, ESO ClusterSecretStores `vault-kv` and `vault-database` Valid, an ExternalSecret refresh, a Woodpecker job that reads Vault, OIDC login, `homelab vault kv get`.
- Vault stays reachable at `vault.viktorbarzin.me` with its own auth (decided, see open questions).

**Prometheus v2.48.1 → v3.15**, in two hops:

1. Image to 2.55.1 on the current chart. 2.55 reads v3 TSDB blocks, so it is the rollback point.
2. Chart 25.8.2 → 29.36.1 (Prometheus v3.15, Alertmanager 0.34.1), in one commit with:
   - remove `--storage.tsdb.allow-overlapping-blocks` (removed in v3)
   - `--enable-feature=otlp-write-receiver` → `--web.enable-otlp-receiver`
   - `scrapeConfigs: null`, so chart 28+ default jobs don't duplicate our `serverFiles` jobs
   - a Terraform ClusterRole + binding granting `get nodes/proxy` to `monitoring/prometheus-server`: chart 29 dropped it from its own role, and the `kubernetes-nodes` and `kubernetes-nodes-cadvisor` jobs scrape kubelets through the API server node proxy (12 targets, all `container_*` and `kubelet_volume_stats_*`)
   - `fallback_scrape_protocol: PrometheusText0.0.4` on the 7 tuya-bridge jobs, which answer `Content-Type: text/html` that 3.x otherwise refuses

Checked already: Alertmanager matchers are all new-style; `le`/`quantile` literals are unaffected by normalization; every dependent (kured, pvc-autoresizer, the k8s version chain, vpn-portal, `homelab metrics query`) uses the `prometheus-server` Service name, which the chart keeps. The regex `.` now matching newline was audited before hop 2: one label value in the TSDB contains a newline and no rule or relabel matches it. Verified after: 26 weeks of history queryable, all scrape jobs up except `openwrt` (down at baseline), alert rules loaded, a test alert reaching Slack.

**Doc corrections** in the same phase: `docs/architecture/secrets.md` (backup target is NFS on the PVE host, not S3; Vault version), `docs/runbooks/restore-vault.md` (single-key unseal sidecar, not three-key manual), `docs/runbooks/vault-raft-leader-deadlock.md` (version), `docs/architecture/automated-upgrades.md` and the DIUN stack comment (what the weekly report covers).

### Phase 2: Trivy Operator

- New stack `stacks/trivy-operator`, chart pinned and owned by Renovate from day one.
- Scans: workload image vulnerabilities, exposed secrets in images, config audit (including RBAC), node and Kubernetes components.
- Cluster: 6 nodes, about 400 pods, 248 unique images. Scan-job concurrency capped at 3 so node1 (67% memory) and node5 (71%) aren't pushed over.
- Prerequisites:
  - Kyverno `require-trusted-registries` allows `mirror.gcr.io/aquasec/*` (confirmed as the chart's default registry for the operator, server and scan jobs).
  - A Kyverno PolicyException scoped to the node-collector, which needs host namespaces and privileges that `deny-host-namespaces`, `deny-privileged-containers` and `restrict-sys-admin` block.
  - Metrics service annotated with `prometheus.io/scrape`, and `trivy_.+` added to the `kubernetes-service-endpoints` keep allowlist (`prometheus_chart_values.tpl:858`). Without it every series is dropped.
- "Internet-reachable" means a namespace with an ingress whose `dns_type` is `proxied` or `non-proxied`. `ingress_factory` labels such ingresses so alert rules can join on namespace.
  - As built (2026-10-10): the rules join on the `cloudflare.viktorbarzin.me/dns-type` annotation `ingress_factory` already sets, exported by kube-state-metrics, instead of a new label. A label would have been an `ingress_factory` change, which CI re-applies to all 113 consuming stacks plus every platform stack.
- Alerts to Slack `#alerts` (once per finding, existing `repeat_interval`):
  - fixable Critical or High CVE on an internet-reachable workload
  - a secret found in an image layer
- Everything else (non-public or unfixable CVEs, config audit, node findings) becomes a weekly section in the existing `alert-digest`: counts by severity, top fixable items, change since last week.
- No automatic trigger from a finding to an upgrade. Renovate runs every 10 minutes, so a fixed version is picked up on its next run once the backlog has cleared. The runbook documents how to start a Renovate run by hand.

### Phase 3: Renovate, Woodpecker rails, Keel retired

**Groundwork before Renovate lands anything**

- Move the GPU time-slicing config to the right key. `stacks/nvidia/modules/nvidia/values.yaml:54` nests `devicePlugin.config` under `driver:`. The live ClusterPolicy only has it because of an earlier manual patch that Helm's 3-way merge has kept, so a gpu-operator upgrade would likely drop GPU slots from 100 to 1.
- Add an alert for `nvidia.com/gpu` allocatable below 100 (asked for in the 2026-05-17 post-mortem).
- Add a MySQL exporter, a pg-cluster Uptime Kuma monitor, and ClickHouse metrics, so the DB checks and the floor have signals to read.
- Add backup CronJobs for ClickHouse and Dolt, so the snapshot step has something to run.
- Write the `verify` script for every Renovate-owned component, and the shared Job runner.
- Give the CI Vault role the admin rights the vault stack needs, and remove the vault skip at `.woodpecker/default.yml:288`, so Vault chart bumps actually apply.

**Adjacent fixes, in the same build**

- Backup freshness metrics: the dbaas and Immich backup jobs succeed, but `apt-get update` fails on bullseye, so the Pushgateway push never happens and `backup_last_success_timestamp` reads about 33 days old.
- Remove the leftover MySQL InnoDB Cluster CR and CRDs (0 pods, reports ONLINE) and the stale postiz backup metric. `drone-logbook-backup` (failing since 2026-08-04) was planned for removal; wave 3 found the app is live behind Sablier and fixed the backup instead.
- Fix the stale MySQL upgrade comment (`stacks/dbaas/modules/dbaas/main.tf:255-262`, superseded by the 2026-09-04 rehearsal) and the gpu-operator pin rationale (`stacks/nvidia/main.tf:136-141`; node1 runs 24.04).

**Renovate**

- New stack `stacks/renovate`: `renovate/renovate` image as a CronJob every 30 minutes (every 10 since 2026-10-11), `platform: forgejo` (Forgejo 11.0.14; native since Renovate 41.41.0), plus a GitHub run for opted-in GitHub repos.
- A dedicated Forgejo bot account, allowed to push to master. Tokens in Vault via ESO. Kyverno allowlist gets the full `docker.io/renovate/*` form.
- Lands straight to master, no PRs (branch automerge with no required status checks). One commit per chart or pin.
- At most one bump lands per run. Woodpecker cancels a running pipeline when the next push arrives, so several commits in one run would cancel each other's health checks and reverts. Each run takes about 15 to 20 minutes including the 10-minute check window, so 30-minute runs don't overlap. That is up to 48 bumps a day. Keel rolled 23 workloads in the 30 days to 2026-10-09 on `patch` only (a lower bound), so steady state fits easily. The first backlog (about 20 charts plus the apps that are a minor or major behind) clears in about 4 days.
- `customManagers` regexes cover the pins Renovate's Terraform manager skips (`tag` inside Helm values maps, YAML/tpl values files).
- Grouped exceptions, where versions must move together: Vault chart + unseal sidecar + backup image.
- Stepping only where upstream requires it (`separateMultipleMajor`/`separateMultipleMinor` package rules): Vault, Authentik, CNPG, Calico, Nextcloud. Everything else jumps straight to the newest version.
- Kill switch: a Terraform variable sets the CronJob `suspend: true`.
- Liveness: each successful run pushes a timestamp to Pushgateway. An alert fires if no run has succeeded for 2 hours.
- Commit messages say what changed and why (the upstream release-note summary), as for any other commit.

**Woodpecker rails** (only for commits authored by the Renovate bot, inside the existing pipeline):

1. Upgrade gate: the same opt-in blocking-alert allowlist used by kured and the k8s version chain. Blocked → the pipeline exits without applying, and the next Renovate run tries again.
2. Snapshot for stateful stacks: Vault raft snapshot, DB dump through the existing backup CronJobs, etcd snapshot for charts that change CRDs.
3. `terragrunt apply` for the touched stack.
4. Verification: run the component's checks from the verification contract above. The Woodpecker apply loop has no per-stack hook today, so a new step reads the list of applied stacks and runs each one's verify Job.
5. On failure: `git revert` of the Renovate commit, with that exact version added to Renovate's ignore list in the same commit, and a Slack page naming the snapshot location. The next upstream release is tried automatically. No automatic data restore.

As built (2026-10-10): `scripts/renovate-rails`, called from the apply step of `.woodpecker/default.yml` (runbook `docs/runbooks/renovate.md`, section "Rails").

- The gate reads both existing lists from their source files: the k8s version chain's `UPGRADE_GATE_ALERTS` (firing criticals) and kured's `alertFilterRegexp`. It waits up to 10 minutes for them to clear.
- A blocked gate or a failed snapshot reverts the bump without an ignore entry instead of leaving it on master unapplied, because Renovate does not push a bump again once master has it. The Renovate wrapper then skips runs for 2 hours after a hold.
- Snapshot: every `*-backup` CronJob in the stack's namespaces (this covers Vault raft, dbaas, Immich, Redis, the ClickHouse and Dolt backups from wave 3, and the app backups), plus `default/backup-etcd` for any chart bump.
- A failed apply counts as a failed check, so a bump that never rolls out is reverted too. The revert commit is applied in the same pipeline and pushed without `[CI SKIP]`, so the next pipeline applies it again.
- Cancellation: ConfigMap `woodpecker/renovate-rails` records the last master commit up to which every Renovate commit was verified or reverted. Any later pipeline verifies Renovate commits after it.
- Added 2026-10-14, after a revert to AIOStreams v2.35.9 crash-looped for 20 hours on a database v2.36.0 had already migrated: a baseline run of the checks before the apply, so only checks that newly fail revert a bump (22 of the first 27 reverts were not caused by the bump); a 2-minute watch of the previous version's pods after the rollback apply, with a roll forward and a page when it does not run; a 180 s grace on the ingress floor; and snapshot namespaces read from the stack source. Details in the runbook, section "Rails".

**Keel retirement** (one change)

1. Scale Keel to 0 first. An active Keel writes back its cached copy of a workload and would revert annotation changes mid-cutover.
2. Write every live image tag into Terraform, resolving `:latest` pins to the version running today.
3. Remove the `KEEL_IGNORE_IMAGE` / `KEEL_LIFECYCLE_V1` / `KYVERNO_LIFECYCLE_V2` keel lines from `ignore_changes`, the Kyverno `inject-keel-annotations` policy, the `keel.sh/*` annotations, the Keel stack and its patched-fork image.
4. Check the plan before applying: pins equal the running tags, so it should show no pod restarts. Any planned restart is investigated before the apply.
5. Apply, then confirm every workload still runs the same image digest as before.

**DIUN retirement**

- Delete the n8n "DIUN Upgrade Agent" workflow and its backup JSON, remove DIUN's webhook notifier, and remove `.claude/agents/service-upgrade.md` and `.claude/reference/upgrade-config.json`.
- DIUN goes entirely, including the Keel release watch, since Keel is retired.
- `docs/architecture/automated-upgrades.md` is rewritten around Renovate and Trivy, and `docs/agents/kyverno-drift.md` drops the Keel markers.

### Renovate upgrade best practices

Recorded 2026-10-11 against Renovate 44.115.9. The config is `renovate.json5` and `stacks/renovate/files/config.js`.

Adopted:

- Dependency Dashboard as a Forgejo issue ("Renovate dashboard"), rewritten every run with pending, held and abandoned updates. Writing it does not count against the one-commit limit and starts no pipeline.
- `abandonments:recommended` from `config:best-practices`, which flags packages with no release for a year on the dashboard.
- `separateMultipleMajor` for stateful images (databases, Immich, Paperless, n8n, CNPG), so a jump of two majors lands as two hops, each verified and revertible on its own. Vault, Authentik, CNPG, Calico and Nextcloud also step through each minor. Stateless apps take the newest major in one bump: the upgrade-best-practices page recommends one major at a time, and on 2026-10-11 Viktor chose fewer hops for stateless apps to clear the backlog faster (echo 36 to 42 had been six hops).
- One bump per run (`prCommitsPerRunLimit: 1`), because a push to master cancels a running Woodpecker pipeline and with it the previous bump's verify and revert.

Not adopted, on purpose:

- `minimumReleaseAge`. Viktor chose no wait on 2026-10-10 so a CVE fix lands within about 30 minutes of release, with the post-merge rails as the safety net. Also, 98 of the 125 bumps in the dry run carry no release timestamp, and the default `minimumReleaseAgeBehaviour=timestamp-required` would hold those indefinitely.
- `docker:pinDigests`. It doubles the number of commits (a digest refresh for every tag) and each digest change restarts the pod.
- `:configMigration`. It opens a PR that waits for a human merge; Renovate migrates old option names in memory anyway.
- Tests before merge. There is no staging cluster, so the check runs after the merge instead: apply, the stack's verify Job, and an automatic revert with the version added to `renovate/ignored-versions.json` when it fails.

## Build plan

The build runs as a sequence of workflows, one wave at a time, and I review each wave's results before starting the next. Inside a wave, every change that touches a stack is landed one at a time: a push to master cancels any Woodpecker pipeline still running, so two concurrent landings would cancel each other's apply.

Every stack step has the same shape:

1. Claim the stack with `presence`, work in a worktree, and land with `homelab work land`, which waits for CI.
2. Stacks CI does not apply (Vault today) are applied from the main checkout with `homelab tf apply`.
3. A separate verifier agent, which did not make the change, compares the live system against the wave-0 baseline and runs the component's checks. The step passes only on its verdict.
4. On failure, fix forward if the cause is clear. If a user-facing service is down and the fix isn't clear, revert, land the revert, and stop the wave.

```mermaid
flowchart TD
  W0[Wave 0<br/>baseline snapshot] --> W1[Wave 1<br/>GPU key fix, Vault x4,<br/>Prometheus x2]
  W1 --> W2[Wave 2<br/>Trivy Operator]
  W2 --> W3[Wave 3<br/>groundwork, verify Jobs,<br/>adjacent fixes]
  W3 --> W4[Wave 4<br/>Renovate stack + rails,<br/>suspended]
  W4 --> W5[Wave 5<br/>Keel cutover,<br/>DIUN removal]
  W5 --> W6[Wave 6<br/>unsuspend Renovate,<br/>watch first bumps]
  W6 --> W7[Wave 7<br/>supervised upgrades,<br/>Keel retired]
```

| Wave | Steps | Passes when | Status (2026-10-12) |
|---|---|---|---|
| 0 | Baseline: firing alerts, `cluster_healthcheck.sh`, Uptime Kuma down list, image digest per pod, `nvidia.com/gpu` allocatable, scrape `up` by job, rule count, Vault status | snapshot saved for later comparison | done |
| 1 | GPU time-slicing key fix + allocatable alert; Vault 1.19.5 → 1.20.4 → 1.21.4 → 2.1.2; Prometheus 2.55.1, then chart 29.36.1 / v3.15; the Vault doc corrections | GPU checks, Vault checks and Prometheus checks from this doc pass after every hop, and nothing new is firing compared with the baseline | done |
| 2 | Trivy Operator with its Kyverno and scrape prerequisites, alert rules, alert-digest section | VulnerabilityReports appear for running images, `trivy_` metrics are scraped, the test alert routes | done |
| 3 | MySQL exporter, pg-cluster monitor, ClickHouse metrics, ClickHouse and Dolt backups, the shared verify Job runner and every chart/DB/GPU verify script, CI Vault-admin, pin the 7 unpinned charts, adjacent fixes | each verify script passes against today's versions, and each new backup has run once | done |
| 4 | Renovate stack (suspended), Forgejo bot account, Renovate config with package rules and custom managers, Woodpecker rails, liveness alert | a dry run lists the expected pending bumps, and the rails are exercised end to end on one deliberate low-risk bump and one deliberate failing bump that reverts | done |
| 5 | Keel cutover in one change, DIUN and the upgrade-agent files removed, docs rewritten | the plan shows no pod restarts, and every pod runs the same image digest as in the baseline | done (B19 on 2026-10-12) |
| 6 | Unsuspend Renovate | the first bumps land through the rails with green checks, and the backlog shrinks run over run | done |
| 7 | Supervised upgrades of the held components (CNPG operator, Woodpecker, Nextcloud, Forgejo, Kyverno policies, Calico) and the end of Keel | each component's checks pass after every hop, and nothing new is firing | done |

Notes on the status column:

- Wave 4: the rails test used a real bump (homepage v1.10.1 → v1.13.2, `3f0e14c4`) and a deliberately failing one (v1.13.99), which failed at apply and was reverted (`3d0b212c`).
- Wave 5 landed as 18 batches (B00 to B17, 2026-10-10 20:01 to 2026-10-11 07:55) instead of one change, so each batch could be checked for restarts on its own. DIUN, the upgrade agent and the Kyverno `inject-keel-annotations` policy are gone. Keel is parked at 0 pods with its stack kept, because seven first-party apps had Keel as their only deploy path. The workloads that were left on their current strings are listed under "Not migrated yet" below.
- Wave 6: Renovate was unsuspended at 2026-10-11 08:13. By 11:05 four bumps had landed, one per run, each through the rails with a green pipeline and none reverted: chrome-service busybox (`3d7c78dc`), claude-agent-service busybox (`23bd8173`), homepage nginx (`2506f656`) and the gluetun digest (`5901acfb`). Work left from the first runs is in the "Rails and Renovate" group below.
- Wave 7 (2026-10-12, supervised, with Renovate paused through its rails hold): the CNPG operator to 1.30.1 with in-place instance manager updates (no Postgres pod restarted); Woodpecker 3.14.1 to 3.19.0, applied from a workstation; Nextcloud 32.0.14 to 35.0.1 in four hops of about four minutes each, with LVM snapshots and a mysqldump first; Forgejo 11.0.14 to 15.0.9 to 16.0.5; the Kyverno policies moved to the CEL types; Calico 3.30.7 to 3.33.0 in three one-minor hops, each after an etcd snapshot. Keel is retired: the last seven apps it deployed now deploy through `first-party-deploy` (B18) and `stacks/keel` is deleted (B19). Findings from the session: Forgejo 15 replayed archive jobs that 11 had left queued and filled its 50 GB volume with about 25 GB of bundles of this repository (cleared with Forgejo's `delete_repo_archives` task, after which a pod restart reopened the queue); replacing a `force_new` Kyverno generate policy with `synchronize: true` deleted 28 of the 30 `ghcr-credentials` copies for under three minutes until the policy was replaced again with the orphan flag in place; and the newer tigera-operator deletes the `calico-apiserver` namespace and labels `calico-system`, which Terraform no longer fights.

## Not migrated yet (updated 2026-10-12)

Viktor's instruction for waves 4 to 6 was to move everything that could move cleanly to Renovate and record the rest for later. This section started as that record on 2026-10-11. The supervised session on 2026-10-12 (wave 7 in the build plan) cleared most of it; what is below is what remains.

### Held for a supervised session

Each of these is a disabled `packageRules` entry in `renovate.json5` with a `HELD:` description, so Renovate lists the update on the dashboard but does not land it. The runbook (`docs/runbooks/renovate.md`) keeps the same list.

| Component | Stack | Why | What it needs |
|---|---|---|---|
| Every dbaas update | dbaas | the rails run every backup CronJob before a dbaas bump, and the full mysqldump takes longer than the rails snapshot timeout. Viktor asked to leave dbaas for now (2026-10-12) | a shorter pre-bump snapshot for dbaas, then release the rule |
| MySQL majors (8.4 to 9.x and 26.x) | dbaas | the supported in-place jump path is unconfirmed, and innovation releases cannot be downgraded. 8.x patch and minor releases still land | confirm Oracle's supported jumps (open question below) and encode the stepping |
| Postgres majors (pg-cluster and its backup clients) | dbaas, immich | each major needs the `cnpg-postgis-pgvector` image built for it first | settle where that image is built (open question below), then CNPG's declarative in-place upgrade |
| Every vault update | vault | the CI apply fails with "Invalid for_each argument" at `stacks/vault/main.tf:1622` | fix the apply, then release the rule |
| Woodpecker chart and images | woodpecker | the rails run on Woodpecker; a CI apply restarts the agent running that pipeline. 3.19.0 (chart 3.7.5) was applied from a workstation on 2026-10-12 and was still the newest release when checked on 2026-10-15. The rule covers minors and patches as well as majors, since any bump restarts the agent the same way | apply from the main checkout first, then push so the CI apply is a no-op (kept as the standing method) |
| osrm-backend majors and minors | osm_routing | osrm-routed refuses a graph built by a different major.minor | a bump builds the graph first, then moves the serving pods |
| Nextcloud majors | nextcloud | a major runs a one-way `occ upgrade` and can disable apps. 35.0.1 since 2026-10-12, and 35 was still the newest major when checked on 2026-10-15 (no 36 image or beta published); minors and patches go through the rails | the procedure in the comment on `nextcloud_image_tag` (LVM snapshot, mysqldump, watchdog suspended) |
| Forgejo majors | forgejo | Forgejo hosts this repository, the bot and the webhook the rails use, and its migrations are one-way. 17.0.0 since 2026-10-15, upgraded on its release day from 16.0.6 after a migration rehearsal against a copy of the database. Upstream schedules 18.0 for 2027-01-14 and ends 17.0 support on 2027-01-28 | a forgejo dump, an LVM snapshot and a mysqldump, then one major per apply from a workstation |
| Technitium majors | technitium | home DNS, on 15.6.1. On 2026-10-15 no 16.x had been published (15.6.1 of 2026-10-11 is the newest release) | a supervised 15 to 16 upgrade once 16.x ships: a backup of each instance, then tertiary, secondary, primary one at a time |
| NVIDIA driver majors | nvidia | 595.91.07 (production branch, EOL 2027-03) since 2026-10-15, compiled against the held GPU node kernel 6.8.0-117. 610 and 615 are new feature branches and were not taken | a supervised run for the next production or LTS branch |
| Provider majors | root `terragrunt.hcl` | vault 5 and cloudflare 5 change resources used by many stacks; authentik 2026.x gates cluster access; telmate/proxmox (all updates) manages the node VMs | a plan of every consumer stack before each |
| Kubernetes 1.36 and 1.37 | cluster | paused by Viktor on 2026-10-12 until Kyverno 1.20 ships (2026-10-23) | Kyverno 1.20 (Renovate lands chart 3.10 when it is published), then the version chain |

Released on 2026-10-12: MetalLB, the CNPG operator (1.30.1, instance managers updated in place, no Postgres restart), Loki (grafana-community chart), Calico (3.33.0 in three one-minor hops; later minors go through the rails one at a time), Kyverno chart 3.10, the anisette pin, and the Nextcloud and Forgejo rules narrowed to majors.

Released on 2026-10-15: the image pins in `prometheus_chart_values.tpl`. The `prometheus-backup` sidecar moved from alpine 3.21 to 3.24 together with chart 29.37.0 in one restart, at 10:02 UTC. A CI apply for another commit picked the change up before the planned snapshot; the head was recovered from the terminating pod's WAL instead, so the data gap was 6 min 55 s rather than 2 h 10 min. Every chart bump already replaced the prometheus-server pod, because its template carries the `helm.sh/chart` label, so the alpine pin was the only part of that pod Renovate did not drive, and holding it did not avoid any gaps. A rails-applied bump still loses the head block (116 minutes of samples on 2026-10-14). A supervised restart can keep it with a TSDB snapshot that includes the head (`docs/runbooks/prometheus-restart-keep-head.md`). The WAL stays on tmpfs to spare the SSD.

### Keel cutover leftovers

Keel is retired. The seven apps it still deployed (excalidraw, interview-prep-app, k8s-portal, learning, pages-publish, repowise, trading-bot) now deploy through `.woodpecker/first-party-deploy.yml` after each build (B18), each checked rolling to its new tag on 2026-10-12, and `stacks/keel` is deleted (B19). On 2026-10-15 the `ghcr.io/viktorbarzin/keel` package and the ViktorBarzin/keel fork were deleted too (the fork's one change had merged upstream as keel-hq/keel#943); a git bundle of the fork and an OCI archive of the image are kept on the backup host under `/mnt/backup/manual-upgrade-20261015/keel/`. The `keel` state schema is empty and stays, as the schemas of other retired stacks do. The digest-only and floating pins listed here on 2026-10-11 are pinned and owned by Renovate.

| Component | Stack | Why | What it needs |
|---|---|---|---|
| Inert Keel and DIUN metadata | about 40 stacks | 78 workloads keep `keel.sh/*` metadata annotations, and `diun.*` pod-template annotations stay because removing them restarts the workloads | drop template annotations with the next change that rolls each workload; strip the metadata annotations in one pass, or leave them |
| Leftover UpdateRequests | kyverno | deleted on 2026-10-15. All 128 had request type `generate` and named ClusterPolicies the CEL migration replaced (24 `generate-limitrange-by-tier`, 25 `generate-resourcequota-by-tier`, 35 `sync-registry-credentials`, 42 `sync-tls-secret`, 2 `sync-ghcr-credentials`); no ClusterPolicy or namespaced Policy exists any more, and none of the 128 had a status. The 3 `cel-generate` requests for live GeneratingPolicies were left in place | none |
| youtubedl-material | ytdlp | pinned `nightly-2025-03-18`, the running digest; upstream has published nothing newer | none until upstream publishes, or replace the app |
| plotting-book | plotting-book | deployed by its owner's CI and ignored as `CI_SETS_IMAGE` | none unless the owner wants Renovate to drive it |

### Rails and Renovate open items

| Component | Stack | Why | What it needs |
|---|---|---|---|
| Release-note links | renovate | the first real commit (`3f0e14c4`) had no release-note URL although `fetchChangeLogs: branch` and a GitHub token are set. The token is the shared `ghcr_pull_token` (read:packages) on Viktor's account | read the changelog lookup in a debug run; optionally mint a dedicated no-scope token |
| Aborted runs count as success | renovate | run `renovate-29861850` hit ETIMEDOUT on one registry, Renovate aborted the repository (`external-host-error`) and the process still exited 0, so the wrapper recorded a success for a run that processed nothing | have `run-renovate.sh` treat `external-host-error` as a failure |
| RenovateNotSucceeding at unsuspend | monitoring | fires right after an unsuspend until the first run succeeds | add a grace window keyed on `kube_cronjob_spec_suspend` changes, or accept a short firing |
| One-bump-per-run evidence | renovate | "Reached commits limit" is a debug-level line, and the CronJob logs at info. The evidence today is one renovate-bot commit per run, no leftover `renovate/*` branch and one rails pipeline per run | a `logLevelRemap` entry in `config.js`, if the line is wanted in the run log |
| Woodpecker repo timeout | woodpecker (repo 82 settings) | 60 minutes; a rails run for dbaas (verify about 28 minutes plus backups) or descheduler (verify up to 60 minutes) can be cut off, after which later pipelines verify it again | raise the repo timeout to 120 minutes (Woodpecker admin setting) or shorten those two verify scripts |
| Verify-failure path | renovate rails | the live failing-bump test failed at apply, so the verify-failure branch of `renovate-rails finish` is covered by `scripts/renovate-rails.test.sh` only | watch the first real verify failure, or force one in a supervised session |
| Floor does not run CronJobs | verify | a bump whose image runs only in a CronJob is covered by apply plus the alert window | a `verify.sh` with `run_cronjob` for stacks whose CronJob images Renovate moves |
| gluetun socks5 | proxy | Renovate lands digest bumps for this pin (`5901acfb` checked by hand: socks5 on :1080 and HTTP on :8888 both exit in GB). The rails do not check socks5 on later bumps | a `stacks/proxy/verify.sh` that requests ipinfo through :8888 and :1080 and expects GB |
| osrm-backend versions | osm_routing | v26.10.0-debian since 2026-10-15, with the graph in `/data/v26.10.0`; the v26.4.0 graph stays in `/data/v26.4.0` for a rollback. osrm-routed refuses a graph built by a different major.minor, and osrm ships a minor every month, so Renovate holds majors and minors. `stacks/osm_routing/verify.sh` queries a route on both profiles. The `-debian` images have no wget or curl, so `osrm-refresh` downloads the extract in a curl init container | a bump points `osrm_build_image` at the new tag and runs `osrm-refresh` once, then moves `osrm_image` |
| busybox in immich-postgresql init | immich | Renovate plans 1.36 to 1.38, which restarts the Immich database through the rails | accept, or hold busybox for immich until a database window |
| Verify pod preemption | verify | verify pods ran at tier-4-aux and were preempted 3 times while node memory requests were above 93% | a higher priority class for verify Jobs |

### Other findings from the run

The Kyverno policies moved to the CEL types on 2026-10-12 (DeletingPolicy `cleanup-failed-pods` now tests `object.status.phase`). Kyverno 1.19.1 had written no status on that DeletingPolicy an hour after the migration, so its verify check only requires it to exist.

| Component | Stack | Why | What it needs |
|---|---|---|---|
| paperless-ngx OOM | paperless-ngx | OOM-killed at its 8Gi limit during OCR on 2026-10-10 from 01:47 to 02:33 (about 17 KernelOOMKiller alerts, 2 restarts). No restarts in the 24 hours to 2026-10-11 11:25 | a higher limit or lower OCR concurrency |
| Wrong certificate for helm.ngc.nvidia.com | nvidia, woodpecker | from pods on k8s-node2, where `woodpecker-agent-0` runs, some requests got a certificate for `*.development.minervaproject.com`. CI pipeline #2140 failed on it and the nvidia apply was done from the main checkout | find the DNS or egress path on k8s-node2 that answers for that name |
| CoreDNS version | kube-system | not in the ownership table, so neither Renovate nor the rails track it | choose an owner (the Kubernetes version chain or a Renovate custom manager) |
| kured Slack webhook | kured | `notifyUrl` from Vault (`slack_kured_webhook`) is rendered into the DaemonSet args as `--notify-url`, readable by anyone who can read DaemonSets in `kured` | pass it from a Secret instead of an argument, then rotate the webhook |
| Stray-workload false positive | monitoring | `StrayWorkloadDetected` fires since 2026-10-11 07:06 for `dbaas/mysqld-exporter` (added in wave 3); `declared_tier0.json` was not regenerated | run `scripts/gen-tier0-workload-inventory.py` from the main checkout and commit the result |
| Control-plane restarts | cluster | four episodes since 2026-10-10 15:40 (about 16:55, 18:55, 22:25 and 07:18) with leader-election restarts and kube-apiserver restarts; etcd WAL fsync p99 reached 8.2 s (5-minute window) at 07:20, with `sdc` writes at 30 to 90 MB/s in each episode. The writers are not identified | find the `sdc` writers (pve-nfs-data and the k8s-node1 disk are the leads) |
| Trivy image-secret alerts | trivy-operator | 12 images flagged; tripit is a false positive (a public AWS key ID in yt-dlp), the others are not reviewed | review, and silence false positives |
| Trivy coverage and load | trivy-operator | Woodpecker pipeline PVCs and their PVs are still config-audited (about 135 updates per hour); rancher/local-path-provisioner is no longer scanned because its namespace is excluded; about 148 stale ResourceQuota reports remain; Medium and Low findings are never stored; filesystem scan mode not adopted | drop PV/PVC from the audited kinds or label the PVCs; skip helper pods by label; delete the stale reports once; decide on severity scope |
| Trivy CRDs on chart bumps | trivy-operator | Helm does not upgrade CRDs | apply CRDs separately when the release notes change them (runbook) |
| Registry cache space | registry VM | 18.6 GB of Docker Hub layers cached by the first Trivy scan expire through `proxy.ttl` on 2026-10-17 | confirm free space after that date |
| Monday Trivy digest | alert-digest | first real run 2026-10-12 08:00 London; only a dry run checked so far | read the first post |
| Dolt backup history | beads-server | backups keep rows, not Dolt commit history | remotesapi or an NFS mount (restarts Dolt); a tarball before Dolt bumps meanwhile |
| PGPASSWORD in Loki | dbaas | `set -x` printed the backup password into Loki before `cb36cca2` | rotate the password, or accept until the 30-day retention passes |
| dbaas leftovers | dbaas | the `mysql-standalone` NetworkPolicy from the old chart selects no pod; `cluster.yaml` is an unreferenced presslabs manifest; `docs/agents/databases.md` still describes InnoDB Cluster | remove both in Terraform and the repo; rewrite the doc for mysql-standalone |
| Alert texts | monitoring | `CIStackPendingHumanApply` still says CI skips vault; `ImageOwnershipConflict` still suggests `keel.sh/policy=never` | fix with the next monitoring rules change (checking the prometheus-server pod template stays unchanged) |
| DIUN and upgrade-agent leftovers | vault, Docker Hub, claude-agent-service, n8n | Vault `secret/diun` is no longer read; the Docker Hub image `viktorbarzin/diun` stays published; claude-agent-service keeps `WOODPECKER_API_TOKEN` and `SLACK_WEBHOOK_URL` and n8n keeps `CLAUDE_AGENT_API_TOKEN`, whose other consumers were not checked | delete the secret and the image if wanted; check consumers, then drop or re-comment the env |
| osrm-refresh | osm_routing | the 2026-10-01 run failed on "wget: too many redirections" from Geofabrik, three pod attempts within 83 s; the download now retries six times, ten minutes apart | check the 2026-11-01 run |

## Accepted risks

Viktor chose these knowingly during the design interview:

- Majors land unattended for every component, apps included, including Calico, Vault, CNPG, the GPU operator and the other fenced operators. The rails can revert the commit but cannot undo a CRD or schema migration. Recovery from that is the snapshot, restored by hand.
- Vault stays reachable from the internet with only its own auth.
- Database engine majors, including MySQL innovation releases, land unattended in place. There is no restore test beforehand, and no automatic way back: recovery is a manual restore from the pre-upgrade dump. MySQL innovation releases cannot be downgraded.
- The CI Vault role gets admin rights over Vault's mounts and policies, so a compromised CI job could change them.
- There is no versions-behind metric. A stalled pipeline is caught by the Renovate liveness alert. A pin Renovate cannot parse would drift without an alert; the cutover checks that every pin is in a form Renovate reads.

## Open questions

- The Vault CVE list needs checking against HashiCorp's HCSEC posts; some IDs from the research pass look malformed.
- Whether Renovate automerges exactly one branch per run on its own, or needs `branchConcurrentLimit: 1` plus a schedule guard to hold that to one. To confirm against current Renovate docs before building.
- Resolved 2026-10-10: Trivy's scanner image registry default, and the node-collector's exact privilege needs. Against chart 0.37.0 (trivy-operator v0.35.0, trivy-kubernetes v0.9.1): the operator, Trivy server and scan jobs pull from `mirror.gcr.io/aquasec/*`, and the node-collector from `ghcr.io/aquasecurity/node-collector`. The node-collector needs `hostPID` and read-only hostPath mounts, runs as root, is not privileged and drops all capabilities, so only `deny-host-namespaces` needed an exception. Details in `docs/architecture/trivy.md`.
- The Prometheus regex change (`.` matching newline) has not been audited across the 402 rules.
- MySQL 8.4 → latest 9.x: confirm which jumps Oracle supports in place (LTS to innovation, innovation to innovation) and encode any required stepping in Renovate.
- Where the `cnpg-postgis-pgvector` image is built, and how a new PG major's image gets built before Renovate proposes the major.
