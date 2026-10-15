# Renovate

Renovate keeps third-party versions in this repo current: `helm_release` chart versions, image pins in `.tf` files, Helm values files, and pins annotated with a `# renovate:` comment. It runs as a CronJob in the `renovate` namespace (`stacks/renovate`), pushes one bump per run straight to `master` as the `renovate-bot` Forgejo account, and the Woodpecker pipeline applies it.

Design: `docs/plans/2026-10-09-software-currency-design.md` ("Phase 3"). Decision: ADR-0030.

## Where things are

| What | Where |
|---|---|
| Repo config (managers, package rules, holds) | `renovate.json5` at the repo root |
| Per-version ignore list (the rails append to it on a revert) | `renovate/ignored-versions.json`, pulled in as `local>viktor/infra//renovate/ignored-versions` |
| Runtime config (platform, token source, one commit per run) | `stacks/renovate/files/config.js` |
| Wrapper (Woodpecker-busy guard, rails-hold cool-down, optional stop after the first automerge, Pushgateway metrics) | `stacks/renovate/files/run-renovate.sh` |
| Kill switch | `variable "suspended"` in `stacks/renovate/main.tf`, default `false` since 2026-10-11 (set `true` to stop runs) |
| Bot token | Vault `secret/renovate`, property `forgejo_token`, delivered by the `renovate-env` ExternalSecret |
| GitHub token (release notes, API rate limit) | Vault `secret/viktor`, property `ghcr_pull_token` (classic PAT, `read:packages` scope only) |
| Cache (repo clone, lookup cache) | PVC `renovate/renovate-cache`, `proxmox-lvm`, 5Gi with autoresize to 20Gi, no backup (rebuilt by the next run) |

## How a run works

1. The wrapper asks Woodpecker for the last 10 pipelines of repo 82 (`viktor/infra`). If any is `running`, `pending` or `blocked`, it records exit code 75 and stops, because a push now would cancel that pipeline. It also stops with 75 when the rails held a bump in the last 2 hours (`renovate_rails_hold_timestamp_seconds` in Pushgateway; `RAILS_HOLD_COOLDOWN` overrides the 7200 s), so a blocked gate does not receive the same bump on every run. The CronJob fires every 6 hours (at :17 past 00, 06, 12 and 18; every 10 minutes from 2026-10-11 until the upgrade backlog cleared on 2026-10-15). Two more checks then decide whether a run goes ahead (both added 2026-10-11, after outages on the shared Proxmox host):
   - Gap between bumps: the newest Renovate pipeline must have finished at least `RENOVATE_MIN_GAP` seconds ago (default 1200), so the cluster settles after one upgrade before the next starts. In practice one bump lands about every 30 to 40 minutes.
   - Calm gate: etcd WAL fsync p99 over 10 minutes must be at most `CALM_MAX_FSYNC` seconds (default 0.5), and `EtcdWalFsyncSlow` / `EtcdBackendCommitSlow` must not be firing (queried from `PROMETHEUS_URL`, default `http://prometheus-server.monitoring`). It fails closed: if Prometheus does not answer, the run is skipped. On 2026-10-11 the p99 reached 7.8 s while other workloads overloaded the host; applies time out in that state, and the rails could revert a good bump only because the cluster was slow.
   Each check records exit code 75 and prints its reason in the Job log.
2. Renovate clones the repo, looks up every dependency, and sorts the pending updates (vulnerability, priority, then pin, digest, patch, minor, major, then title).
3. It commits the first update to `renovate/<stack>-<dep>` and fast-forwards `master` to it (`automergeType: branch`, `ignoreTests: true`). `prCommitsPerRunLimit: 1` stops every later branch in the same run, including the one Renovate's own post-automerge restart would otherwise land.
4. After the automerge Renovate logs `Restarting repository job after automerge result` and runs the repository job again. That second pass lands nothing (the commit limit is reached) and writes the Dependency Dashboard issue and the repository cache. It overlaps with the pipeline the push just started, so the pod runs at the `renovate` PriorityClass: the `tier-3-edge` value, so Woodpecker step pods cannot preempt it, and `preemptionPolicy: Never`, so it never evicts another pod. On 2026-10-11, at `tier-4-aux`, the step pods preempted it in two of three runs, and from `4b808e14` until the PriorityClass change the wrapper stopped Renovate at that log line, which also kept the dashboard from refreshing. That stop is still available with `RENOVATE_STOP_AFTER_AUTOMERGE=1` (SIGTERM to the process group, SIGKILL after `RENOVATE_STOP_GRACE`, default 20 s).
5. The wrapper pushes `renovate_last_run_timestamp_seconds`, `renovate_last_run_exit_code`, `renovate_last_run_duration_seconds`, and on exit 0 `renovate_last_success_timestamp_seconds` to Pushgateway (`job="renovate"`, `instance="infra"`).

Commit subjects read `<stack>: bump <dep> <old> -> <new>`. The body lists each pin and ends with `Renovate-Dep: <datasource> <package> <version>` trailers, which the rails use to write an ignore entry.

## Rails

The infra pipeline (`.woodpecker/default.yml`, apply step) runs `scripts/renovate-rails` around its usual apply loop. It acts on commits whose git author is `renovate-bot@viktorbarzin.me`, plus every commit of a push made by the `renovate-bot` account. For any other push it finds nothing to do and returns within a second.

```mermaid
flowchart TD
  P[push to master] --> D[detect changed stacks]
  D --> R{Renovate commits not yet<br/>verified or reverted?}
  R -->|no| A[apply as before]
  R -->|yes| G{gate clear?<br/>waits up to 10 min}
  G -->|no| H[revert, no ignore entry<br/>Slack: held]
  G -->|yes| S[run the stack's backup CronJobs<br/>+ etcd snapshot for a chart bump]
  S -->|failed| H
  S --> B[baseline: verify --baseline<br/>which checks already fail]
  B --> A2[apply]
  A2 --> V[scripts/verify/run per stack]
  V -->|pass, or only checks<br/>that failed in the baseline| M[move marker]
  V -->|a check that passed in the baseline fails,<br/>or apply failed| F[revert + ignore entry,<br/>apply reverted tree]
  F --> W{previous version's new pods<br/>healthy for 2 min?}
  W -->|yes| FS[Slack names the snapshot]
  W -->|no: restarts or crash loop| RF[roll forward: bump back,<br/>ignore entry removed,<br/>apply, Slack: human needed]
  FS --> M
  RF --> M
  H --> M
```

| Stage | Command | What it does |
|---|---|---|
| prepare | `renovate-rails prepare`, after stack detection | Finds Renovate commits on master after the marker, minus ones a later commit reverted. Runs the gate, the snapshot, then a baseline `scripts/verify/run --baseline <stack>` (a few seconds per stack, in parallel), and adds each commit's stack to the apply lists. |
| apply | the existing platform and app loops | Unchanged, except that a failed apply of a stack the rails are verifying no longer fails the step; the rails handle it. |
| finish | `renovate-rails finish`, before the state push | Runs `scripts/verify/run --since <time before apply> <stack>` for each stack. On a failed apply, or a verify failure the baseline did not already show, it reverts the commit, applies the reverted tree, checks that the previous version runs (rolling forward if it does not), posts to Slack and writes Pushgateway metrics. |
| push | the existing state push | Pushes the revert commit with any state commits. |
| exit | `renovate-rails exit` | Turns the pipeline red when a bump was reverted or could not be handled. |

The gate is the same opt-in allowlist the other unattended upgraders use. `renovate-rails` reads `UPGRADE_GATE_ALERTS` from `stacks/k8s-version-upgrade/scripts/upgrade-step.sh` (firing alerts with severity critical) and `alertFilterRegexp` from `stacks/kured/main.tf` (any firing alert), so there is one list to edit. It queries Prometheus directly, so an Alertmanager silence does not open it. If Prometheus does not answer, the gate counts as blocked. If the chain's list cannot be parsed, every firing critical blocks, as in the chain itself.

The snapshot runs, once, every unsuspended CronJob whose name ends in `-backup` in the stack's namespaces: `VERIFY_NAMESPACES` in its `verify.sh`, else the namespaces `scripts/verify/stack-namespaces` reads from the stack source (the same list the verify runner checks), else the stack name. Until 2026-10-14 the rails skipped the source step, so `servarr` resolved to `servarr` alone and the `aiostreams` backups never ran. `cnpg` also runs `dbaas/postgresql-backup`, and any Helm chart bump also runs `default/backup-etcd`, because a chart may change CRDs. The Jobs are named `rails-<cronjob>-<sha>-<n>` and kept for 24 hours. The Slack message and the revert commit name each Job and the NFS path it wrote to. No data is restored automatically.

A failed bump becomes one commit by `Woodpecker CI <ci@viktorbarzin.me>`: `Revert "<stack>: bump ..."`, with that exact version added to `renovate/ignored-versions.json`. For a digest-only pin the entry disables digest updates for the package instead (`matchUpdateTypes: ["digest"]`), and stays until someone removes it. The revert is pushed without `[CI SKIP]`, so the pipeline it starts applies the reverted tree a second time; that run is a no-op when the rollback apply in the rails already succeeded, and the retry when it did not.

Which failures count. Before the apply, the rails run each stack's checks once with `--baseline`: quick, no alert window, no rollout or ingress waits. The checks that fail there were failing before the bump. After the apply, a failed verify reverts the bump only when a check fails that passed in the baseline. When every failed check also failed in the baseline, the bump counts as verified and the log names the pre-existing failures. Of the 27 reverts between 2026-10-10 and 2026-10-14, 22 were not caused by the bump; at least 9 of those were checks already failing before it (Kyverno webhook panics, a crash-looping immichframe, `resume` not running since July). The comparison uses check names, which name the workload or route (`floor: rollout immich/Deployment/immich-frame`, `floor: ingress aiostreams/aiostreams`). If the baseline produced no result, or the failed verify names no check, every failure counts, as before. `RAILS_BASELINE=0` in the pipeline environment turns the baseline off.

Rollback check and roll forward. After applying the reverted tree, the rails watch the stack's namespaces for 2 minutes (`RAILS_ROLLBACK_WATCH`). A pod created after the rollback apply started that restarts twice, or waits in `CrashLoopBackOff`, an image-pull error or a config error, means the previous version does not run. That happens when the bump changed state the old version cannot read: a database migration, a data format, a CRD. The rails then roll forward: a CI commit `Roll forward "<subject>"` re-applies the bump and removes its ignore entry, the stack is applied again, and the Slack message says both versions failed and a human needs to look (outcome 4). On 2026-10-14 AIOStreams v2.36.0 applied migrations 43 to 46, a verify probe caught it mid-startup, and the revert to v2.35.9 crash-looped for 20 hours on "Database is at migration 46 but this build only knows up to 42"; linkwarden's revert hit the same class on 2026-10-11 (Prisma P3009). A broken rollback costs the terraform rollout wait (up to 10 minutes for a Deployment that never becomes ready) plus the watch. The pods the failed bump created are older than the rollback, so their restarts do not count while they terminate.

A held bump (gate blocked, or the snapshot failed) is reverted the same way but without an ignore entry, so Renovate offers it again after the 2-hour cool-down. The pipeline stays green.

Cancellation: a push to master cancels the running pipeline, so a human push can stop the rails between apply and verify. The marker covers that. ConfigMap `woodpecker/renovate-rails`, key `last_handled`, holds the newest master commit up to which every Renovate commit was verified or reverted. The next pipeline, whoever pushed it, starts from the marker, finds the unverified Renovate commit, applies its stack again (a no-op if it was applied) and verifies it. The marker only moves forward along master, so a restarted older pipeline cannot move it back. If it is missing or not an ancestor of the commit being built, the rails fall back to the pipeline's diff base.

Metrics (Pushgateway, `job="renovate-rails"`): `renovate_rails_last_run_timestamp_seconds`, `renovate_rails_last_outcome` (0 verified, 1 reverted, 2 held, 3 not fully handled, 4 reverted and rolled forward), `renovate_rails_last_revert_timestamp_seconds` (outcomes 1 and 4), `renovate_rails_roll_forward_timestamp_seconds`, `renovate_rails_hold_timestamp_seconds`.

Working with the rails:

- Read what a run did: `homelab logs query '{namespace="woodpecker"} |= "[rails]"' --since 2h`.
- Retry a reverted version: delete its entry from `renovate/ignored-versions.json` and land that change.
- After a roll forward (Slack ":rotating_light:", outcome 4): the stack runs the bumped version that failed its checks. Read the newly failing checks in the revert commit's `Why:` line and fix forward. Do not pin the old version again unless you restore the data the bump migrated (the snapshot named in the message).
- See or move the marker: `kubectl -n woodpecker get cm renovate-rails -o yaml`. Deleting it makes the next pipeline consider only its own diff.
- Unit tests: `bash scripts/renovate-rails.test.sh` (temporary git repos, no cluster access) and `bash scripts/run-renovate.test.sh` for the CronJob wrapper (fake `renovate` and Pushgateway, needs `node`).

## Start, stop, run by hand

Unsuspend or suspend: change the `suspended` default in `stacks/renovate/main.tf` and land it. CI applies the stack.

Dry run from the CronJob template (pushes nothing; the `dryrun` instance label keeps it out of the liveness alert):

```sh
kubectl -n renovate create job renovate-dryrun --from=cronjob/renovate --dry-run=client -o json \
  | python3 -c 'import json,sys; j=json.load(sys.stdin); c=j["spec"]["template"]["spec"]["containers"][0]; c["args"]=c["args"]+["--dry-run=full"]; c["env"]=[e for e in c["env"] if e["name"]!="RENOVATE_INSTANCE"]+[{"name":"RENOVATE_INSTANCE","value":"dryrun"}]; print(json.dumps(j))' \
  | kubectl create -f -
kubectl -n renovate logs -f job/renovate-dryrun
kubectl -n renovate delete job renovate-dryrun
```

What a healthy dry run shows: `Processing N branches`, one `DRY-RUN: Would commit files to branch renovate/...` per branch, and no `WARN`/`ERROR` lines. Remove the `dryrun` group from Pushgateway afterwards: `curl -X DELETE http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/renovate/instance/dryrun` (from inside the cluster).

A real run outside the schedule (lands one bump, only when the CronJob is unsuspended): `kubectl -n renovate create job renovate-manual --from=cronjob/renovate`.

## Holding a component

Two ways, both in the repo:

- A version that failed: add one rule to `renovate/ignored-versions.json` (the rails do this on a revert). The next upstream release is tried automatically.

  ```json
  { "matchDatasources": ["helm"], "matchPackageNames": ["traefik"], "matchNewValue": "41.8.0", "enabled": false }
  ```

- A component that waits for a supervised session: a `HELD:` package rule in `renovate.json5` with `enabled: false` and a description saying why. Held today (2026-10-12): every update in `stacks/dbaas`, Woodpecker (every update; apply from a workstation before the push), osrm-backend majors and minors, and the majors of Nextcloud, Forgejo, Technitium, the NVIDIA driver, MySQL (9.x and 26.x) and Postgres. n8n was released on 2026-10-13: its 2.43.4 migration had failed because the database was already on a 2.x schema (Keel had upgraded it before the 1.80.5 pin was restored) with `user.roleSlug` renamed back to `role` by hand; renaming the column back let 2.43.4 migrate cleanly. The image pins in `prometheus_chart_values.tpl` were released on 2026-10-15: every chart bump already restarts prometheus-server (the pod template carries the `helm.sh/chart` label), so the rails take the head-block gap for those anyway, and a supervised restart can keep the head with `docs/runbooks/prometheus-restart-keep-head.md`. Provider holds: vault 5, cloudflare 5, authentik 2026.x and every telmate/proxmox update. `stacks/vault` was released on 2026-10-15, once its plan worked with a pending chart change. Remove the rule to release the component.

Single versions the rails or a person reverted live in `renovate/ignored-versions.json`, one entry per package and version with the reason. Delete an entry to let Renovate offer that version again. The list is empty since 2026-10-13: the three entries from 2026-10-12 (llama-swap v264, reactive-resume v6.0.2, navidrome 0.64.2) were landed by hand once their causes were fixed (a full registry cache disk, a missing `DATABASE_URL`, and the 0.64 artwork worker's memory peak). It was emptied again on 2026-10-15: prometheus 29.37.0 (pipeline #2456) failed only because rules read health `unknown` before their first 60s evaluation, and external-dns 1.23.0 (pipeline #2502) failed closed because technitium became a chart stack without a `verify.sh`. Both checks were fixed and Renovate offers the versions again.

A batch landed with a trailing `[ci skip]` commit is still inside the next pipeline's rails range: the rails verify every Renovate-authored commit between the marker and HEAD, so another session's push can verify, and revert, bumps that were applied by hand. On 2026-10-12 that reverted the Python 3.14 helper bumps of nvidia, llama-cpp and kyverno as collateral of the llama-swap failure; they were re-landed.

A verify that fails for a reason outside the bump still reverts it, and the ignore entry the rails add matches the package name in every stack, not only the one that failed. On 2026-10-13 Kyverno webhook panics from the `inject-ndots` policy failed the kyverno verify twice; the rails reverted that stack's Python bumps and the `python` `3.15-alpine` ignore blocked the bump in every stack naming the image `python`. Read the failing check in the pipeline log before trusting an entry in `renovate/ignored-versions.json`.

gpu-operator chart bumps cannot pass the rails alone: the driver DaemonSet is OnDelete with auto-upgrade off, so the ClusterPolicy stays notReady until the driver pod is deleted, which takes the GPU away for about 10 minutes. Land them by hand with that restart (see the comment above the chart pin in `stacks/nvidia/modules/nvidia/main.tf`).

Not managed by Renovate at all: `modules/docker-registry/**` (synced to the registry VM by its own pipeline, outside the rails), `.woodpecker/**` (CI images), our own images (`viktorbarzin/*`, `ghcr.io/viktorbarzin/*`, `forgejo.viktorbarzin.me/*`), and `:latest` or untagged refs.

Shared-module image pins live in the callers, not in the module default: the anubis tag is pinned in each of its eight stacks, so Renovate bumps one stack per commit. A pin left inside `modules/**` lands in a Tuesday 00:00-03:59 window, and the rails verify every stack that uses the module.

Terraform providers are exact pins in root `terragrunt.hcl`, one `# renovate:` annotation each. Renovate lands at most one a week (Wednesday 00:00-03:59, subject `providers: bump ...`). CI re-applies the 32 platform stacks; the rails do not verify that commit, so a failed apply turns the pipeline red without a revert. Majors of vault, cloudflare and authentik and every telmate/proxmox update are held. `scripts/tg` runs `terragrunt init -upgrade` when a workstation lockfile predates a pin.

## Alert

`RenovateNotSucceeding` fires when `instance="infra"` has not pushed a success timestamp for 13 hours (two 6-hourly runs, so one skipped run stays quiet; it was 2 hours while the CronJob ran every 10 minutes), unless the CronJob is suspended (`kube_cronjob_spec_suspend`). Check, in order:

1. `renovate_last_run_exit_code{job="renovate",instance="infra"}`: 75 means every recent run found Woodpecker busy; 1 means Renovate logged an ERROR.
2. `kubectl -n renovate get jobs` and `kubectl -n renovate logs job/<latest>`.
3. A token problem shows as HTTP 401 against `forgejo.viktorbarzin.me`. Mint a new PAT for `renovate-bot` (scopes `write:repository`, `read:user`, `write:issue`, `read:organization`) and write it to `secret/renovate` `forgejo_token`; ESO refreshes the Secret within an hour.

## Bot account

Created through the Forgejo admin API on 2026-10-10, outside Terraform (the `infra-agent` bot is managed the same way):

- user `renovate-bot` (id 8), full name "Renovate", email `renovate-bot@viktorbarzin.me`, private visibility
- write collaborator on `viktor/infra`
- on the `master` branch protection push whitelist, next to `ebarzin`, `infra-agent`, `viktor`
- PAT `renovate-infra` with `write:repository`, `read:user`, `write:issue`, `read:organization`; the token and the account password are in `secret/renovate`

## When a fast-forward loses a race

If another push lands on master while Renovate is running, its fast-forward is rejected ("rejected (fetch first)") and Renovate opens a pull request for that branch instead. On later runs it rebases the branch and merges the PR through the Forgejo API. That needs `renovate-bot` on master's merge whitelist (added 2026-10-11 after PR #113 sat unmergeable and every run spent its one-commit budget rebasing it). If a Renovate PR is ever stuck again, merge it with the fast-forward-only style so master stays linear and the rails still see a renovate-bot commit.

## Known limits

- Docker Hub: about 240 Docker lookups per run. Renovate authenticates as the registry cache's Docker Hub account (`secret/registry-cache`, `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` in the `renovate-env` ExternalSecret), because anonymous manifest reads share the home IP's 100 per hour: two cold-cache dry runs used that up on 2026-10-11 and the second aborted with 429. The cache PVC keeps repeat lookups down. Requests to Docker Hub are capped at 2 at a time and 5 per second (`config.js` hostRule): an image used in several stacks is looked up once per stack, and the parallel token requests got 429 "too many failed login attempts" for `library/nginx` and `actualbudget/actual-server` even with valid credentials.
- Renovate bumps its own image at most once a week (Mondays 00:00-03:59 UTC).
- The Woodpecker guard keeps Renovate from cancelling other pipelines. A human or agent push can still cancel a Renovate pipeline; the next pipeline then verifies that bump (see "Rails").
- The infra repo's Woodpecker timeout is 60 minutes. A rails run takes the gate wait (up to 10 minutes), the snapshot, the baseline (seconds), the apply and the verify (about 10 minutes for most stacks, 28 for `dbaas`, up to an hour for `descheduler`). A bump to `dbaas` or `descheduler` can therefore run past the timeout; the next pipeline then verifies it again from the marker. Raising the repo timeout in Woodpecker's settings would remove that loop.
- Pins under `modules/` and in `.woodpecker/*.yml` are outside Renovate (see "Holding a component").
