---
status: approved
plan: true
---

# Woodpecker starts every private build and picks where it runs

When the account uses its 2,000 private minutes, GitHub refuses every private build until the 1st, and deploys stop. After this change, one Woodpecker step starts each push. It sends the build to GitHub while minutes remain, and to the cluster when they do not.

## In numbers

```numbers
caption: GitHub billing API, Actions runs and repo lists, measured 2026-11-26
rows:
  - {label: Hours with no private builds after the quota ran out, Oct 2026, before: "34 (30 Oct 14:38 to 1 Nov 01:09 UTC)", after: "0"}
  - {label: Repos with active GitHub workflows, before: "55 (26 private, 29 public)", after: "53 started by Woodpecker; infra and cloud-builder stay as they are"}
  - {label: Billing API delay behind finished jobs, before: "under 45 minutes", after: "same; a refused dispatch covers it"}
  - {label: Woodpecker pods per private push, before: "0", after: "1, about 10 to 60 seconds", better: false}
  - {label: Builds in the cluster while minutes remain, before: "0", after: "0"}
```

## The system, with the change on it

```topology
caption: One flow for every push. The cluster builds only when GitHub has no minutes.
direction: LR
groups:
  - {id: gh, label: GitHub}
  - {id: k8s, label: Sofia cluster}
nodes:
  - {id: push, label: Push to master, note: Forgejo mirror to GitHub, group: gh, state: same}
  - {id: gha, label: GitHub Actions build.yml, note: "workflow_dispatch only", group: gh, state: changed, risk: medium}
  - {id: billing, label: Billing usage API, group: gh, state: same}
  - {id: ghcr, label: ghcr.io images, group: gh, state: same}
  - {id: route, label: "Woodpecker step: route", note: in each app repo, group: k8s, state: new, risk: medium}
  - {id: build, label: "infra pipeline: gha-runner", note: "one-shot self-hosted GitHub runner, one at a time", group: k8s, state: new, risk: high}
  - {id: deploy, label: Per-app Woodpecker deploy, group: k8s, state: same}
edges:
  - {from: push, to: route, state: new, label: push webhook}
  - {from: route, to: billing, state: new, label: minutes used}
  - {from: route, to: gha, state: new, label: dispatch while minutes remain}
  - {from: route, to: build, state: new, label: "quota out, or GitHub refused the job"}
  - {from: build, to: gha, state: new, label: "takes the job of runs-on homelab"}
  - {from: gha, to: ghcr, state: same}
  - {from: gha, to: deploy, state: same, label: IMAGE_TAG}
checks:
  - {node: route, text: "A push to infra-map with minutes left starts one GitHub run and no cluster build", status: open}
  - {node: route, text: "The tests replay the saved 30 Oct refusal and start gha-runner", status: open}
  - {node: build, text: "A forced homelab run of infra-map's build.yml pushes its <sha8> tag, and the deploy rolls it", status: open}
  - {node: build, text: "A forced homelab run of cloud's build.yml builds both images in one job", status: open}
  - {node: build, text: "GitHub runs a self-hosted job while hosted jobs are blocked; first seen at the next quota exhaustion", status: open}
  - {node: gha, text: "A direct push no longer starts build.yml in any of the 24 repos", status: open}
left_out:
  - A cron that searches for refused runs. It reacts up to 15 minutes late.
  - A self-hosted GitHub runner. It needs a host that is always on, and the Dell is stored.
  - Builds through the public cloud-builder repo. GitHub's terms limit hosted jobs to their own repo.
```

## Decisions

```decision
- question: What starts a private build?
  options:
    - {name: "A Woodpecker step on every push", chosen: true}
    - {name: "GitHub on push, and a cron that rescues refused runs", note: two flows, and up to 15 minutes late}
  why: One place decides, so a later routing change touches only infra.
- question: Which repos and workflows?
  options:
    - {name: "Every repo, every workflow a branch or tag push starts", chosen: true}
    - {name: Private repos only, note: two flows again}
  why: Viktor wants one flow for all builds now and for every new repo.
- question: Which repos keep their GitHub push triggers?
  options:
    - {name: "infra and cloud-builder", chosen: true}
    - {name: None, note: infra builds the route image and the images that repair the cluster}
  why: Those builds must work while the cluster is down; Cloud already dispatches cloud-builder.
- question: Where do the trigger rules live?
  options:
    - {name: "In .woodpecker/build.yml, one route step per workflow with its branch and path filter", chosen: true}
    - {name: In a comment inside each GitHub workflow, note: a parser on comments breaks easily}
  why: Woodpecker starts the build, so its file holds the trigger; the route logic stays in infra-ci.
- question: How does the route step choose?
  options:
    - {name: "Billing gate, then watch the dispatched run", chosen: true}
    - {name: Billing gate only, note: loses a push when the billing figure lags at the limit}
  why: Under 1,950 minutes it dispatches and waits until the run starts; a refusal goes to the cluster.
- question: Which commits build in the cluster?
  options:
    - {name: Only when GitHub has no minutes, chosen: true}
    - {name: Also when a GitHub build fails, note: deploys a commit that CI rejected}
  why: A real CI failure must stay a failure.
- question: How does the cluster build?
  options:
    - {name: "The repo's own workflow on a one-shot self-hosted GitHub runner", chosen: true}
    - {name: "BuildKit replays the image steps of build.yml", note: "fails on 32 cross-job outputs, 21 computed versions and 13 workflows with no image"}
    - {name: "Both, BuildKit when GitHub blocks self-hosted jobs too", note: most code}
  why: "Viktor chose it: every workflow runs as written. If GitHub also blocks self-hosted jobs, builds wait for the 1st."
- question: Where does the runner run?
  options:
    - {name: "An infra pipeline on a builder agent with one slot", chosen: true}
    - {name: "Inside each app repo's pipeline", note: puts the runner token in 53 repos; no limit on parallel builds}
  why: Only infra holds the runner token, and the sdc disk takes one build at a time.
- question: Which credentials?
  options:
    - {name: Two narrow tokens from Viktor, chosen: true}
    - {name: The github_pat in secret/viktor, note: it has every scope, including delete_repo and admin:org}
  why: A token in the cluster must do only its job.
```

The two tokens, both fine-grained for all repos:

- `github_route_token`: `Actions: read and write`, `Contents: read`, and the account permission `Plan: read`. The app repos get it.
- `github_runner_token`: `Administration: read and write` and `Actions: read`. It registers just-in-time runners. Only the infra repo gets it.

The runner job uses the workflow's own `GITHUB_TOKEN` for ghcr, so no ghcr token goes into the cluster. The runner image is `ghcr.io/viktorbarzin/gha-runner`: GitHub's `actions-runner` with `jq`, `gh` and `python3`. The public infra repo builds it. A Docker-in-Docker sidecar runs privileged, so Woodpecker marks only the infra repo as trusted.

## How one push works

1. The push webhook starts `.woodpecker/build.yml` in the repo. Each route step names one GitHub workflow and keeps its old branch, tag and path filters.
2. A public repo dispatches at once. For a private repo, the route step reads the private minutes for the month.
3. Under 1,950 minutes, it dispatches the workflow with `runner=ubuntu-latest`. It waits up to 3 minutes for a hosted runner to take the job, then exits.
4. At 1,950 or more, or if GitHub refuses the job, it dispatches with `runner=homelab` and starts the infra pipeline `gha-runner` for the repo.
5. `gha-runner` registers a just-in-time runner with the label `homelab`, which takes one job and exits. It repeats until no `homelab` job of the repo waits.
6. Slack gets a message on the first cluster build of a month and on each failed one.

Each job's `runs-on` becomes `${{ inputs.runner || 'ubuntu-latest' }}`. A job on another runner, such as macOS, keeps its own label and waits for the 1st.

## Order of work

```timeline
caption: Every step can be undone. A repo goes back by restoring its push trigger.
steps:
  - {when: 1. Tokens, what: "Viktor creates the two tokens; Vault secret/ci/global; the sync maps each to its repos", rollback: Revoke both tokens}
  - {when: 2. Route and build code, what: "scripts/ci-build/ with tests on saved API responses; ships in infra-ci", rollback: Revert the commit}
  - {when: 3. Runner, what: "The gha-runner image, a woodpecker-builder agent with one slot, and .woodpecker/gha-runner.yml", rollback: "Set the agent's replicas to 0"}
  - {when: 4. First repos, what: "infra-map and cloud move; forced homelab runs of both; read the live tags", rollback: "Restore their push triggers"}
  - {when: 5. Every repo, what: "A codemod moves the other 52 repos; app-template and offinfra-onboard make new repos this way", rollback: "Restore the push triggers with the same codemod"}
  - {when: 6. Docs, what: "ADR-0002 amendment, the infra CLAUDE.md rule, docs/architecture/ci-cd.md", rollback: Revert the commit}
```

## Configuration

```config
- {key: "on.push of each workflow", where: 53 repos, old: "branches, tags, paths", new: "removed; workflow_dispatch with input runner"}
- {key: "runs-on of each ubuntu job", where: the same workflows, old: "ubuntu-latest", new: "${{ inputs.runner || 'ubuntu-latest' }}"}
- {key: ".woodpecker/build.yml", where: the same repos, old: "absent", new: "one route step per workflow, image infra-ci"}
- {key: "github_route_token, github_runner_token", where: "Vault secret/ci/global, ci_repo_secrets in stacks/woodpecker", old: "absent", new: "app repos, and infra only"}
- {key: woodpecker-builder agent, where: stacks/woodpecker, old: "absent", new: "1 replica, WOODPECKER_MAX_WORKFLOWS 1, label builder"}
- {key: "In-cluster build rule", where: "infra CLAUDE.md and ADR-0002", old: "never", new: "only when GitHub has no private minutes"}
```

## Commands

```sh
python3 scripts/ci-build/route.py --check --repo infra-map
python3 scripts/ci-build/route.py --force-homelab --repo infra-map
kubectl -n infra-map get deploy infra-map -o wide
homelab ci watch --repo ViktorBarzin/infra-map
```
