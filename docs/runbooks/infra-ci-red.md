# Infra CI is red (InfraCIRed)

`InfraCIRed` fires when the canonical infra CI stops applying. While it fires, commits on master are not applied to the cluster.

## How it works

```
CronJob infra-ci-status (ns ci-pipeline-health, */10)
  --GET /api/repos/82/pipelines?branch=master&event=push--> woodpecker-server (in-cluster)
  --PUT /metrics/job/infra-ci-status--> Pushgateway --> Prometheus group "Infra CI"
```

- Woodpecker repo 82 is Forgejo `viktor/infra`. Its push pipelines run `.woodpecker/default.yml`, the terragrunt apply of changed stacks. Repo 1, the GitHub mirror, runs the same file, but its apply is a forge-guard no-op and is always green, so the poller does not read it.
- The poller is `stacks/ci-pipeline-health/files/infra_ci_status.py`. It reads the newest master push pipelines and pushes four gauges:

| Metric | Meaning |
|---|---|
| `infra_ci_red_streak` | Newest pipelines in a row that ended `error`, `failure` or `killed`. `running` and `pending` count neither way. |
| `infra_ci_last_success_timestamp_seconds` | When the newest successful pipeline finished. 0 when none is in the last 500. |
| `infra_ci_newest_red_pipeline` | Number of the newest red pipeline, 0 when the streak is 0. |
| `infra_ci_status_last_run_timestamp_seconds` | Heartbeat: the poller read Woodpecker and pushed. |

- `InfraCIRed` (critical, re-pings every 6h): streak >= 2 and no success for 1h, for 5m.
- `InfraCIStatusStale` (warning): no heartbeat for 30m, for 10m, or no series at all. `InfraCIRed` is blind while it fires.
- Tests: `tests/infra-ci-status.test.sh` (the poller, `promtool` on the rule group, shellcheck on the daily sweep).

Why it exists: from 2026-11-26 12:08, every repo-82 pipeline ended `error` at lint time ("Insufficient trust level to use privileged mode", infra#226). A lint error creates no steps, so `default.yml`'s `notify-failure` step never ran, and nothing applied for a day before anyone noticed.

## When it fires

1. Read the newest red pipeline. The alert names its number.

   ```sh
   curl -s https://ci.viktorbarzin.me/api/repos/82/pipelines/<n> | python3 -c 'import json,sys; d=json.loads(sys.stdin.read(), strict=False); print(d["status"], d["errors"]); print([s["name"]+":"+s["state"] for w in d.get("workflows") or [] for s in w.get("children") or []])'
   ```

   GETs need no token. The JSON can hold raw control characters, so parse it with `strict=False`.

2. Match what you see:

| What `.errors` and the steps show | Meaning | Next step |
|---|---|---|
| `.errors` is not empty, no workflows | Lint or config error. Nothing ran. | Fix the `.woodpecker/*.yml` file or the repo setting named in the message. Woodpecker lints every file in `.woodpecker/` on every pipeline. Repo settings are not in Terraform: `docs/architecture/ci-cd.md`, "Routing builds through Woodpecker". |
| `could not load config from forge` or `pipeline definition not found` | The config fetch from Forgejo failed. | Woodpecker's Forgejo login or the network to Forgejo: `docs/agents/known-issues.md` (infra#116) and `docs/runbooks/woodpecker-onboard-forgejo-repo.md`. A pipeline that never fetched its config cannot be restarted; push again. |
| A step failed | A stack apply failed. | Read the step log: `GET /api/repos/82/logs/<n>/<step id>`, where the step id is `.workflows[].children[].id`. The log lists `=== FAILED STACKS`. |
| `killed` | A newer push cancelled it, or it timed out. | Usually clears with the next push. A killed apply can leave its stacks unapplied: plan them. |

3. While CI is red, apply by hand from the main checkout (`homelab tf apply <stack>`) for anything urgent, and commit as usual.

4. Once the cause is fixed, the next master push applies the stacks in its own diff only. Plan the stacks that changed while CI was red, and apply what shows a diff. The alert resolves after the poller sees a success (up to 10 minutes, plus one Pushgateway scrape).

## When InfraCIStatusStale fires

```sh
kubectl -n ci-pipeline-health get jobs -l app=infra-ci-status
kubectl -n ci-pipeline-health logs job/<latest>
```

A failed run prints one line naming the error and pushes nothing. It reads `http://woodpecker-server.woodpecker.svc.cluster.local/api`, so `WoodpeckerDown` is the first thing to check. The Woodpecker token comes from Vault `secret/ci/global` `woodpecker_api_token` through the ExternalSecret `ci-pipeline-health-creds`.

## Who hears about it

Like every alert, it reaches the people who chose it at https://notify.viktorbarzin.me/a/InfraCIRed (`docs/runbooks/notify-pipe.md`). A critical alert that reaches nobody still posts one line to #alerts.
