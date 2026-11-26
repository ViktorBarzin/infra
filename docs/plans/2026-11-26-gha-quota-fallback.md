---
status: draft
plan: true
---

# Build private repos in Woodpecker when GitHub Actions minutes run out

When the account uses its 2,000 private minutes, GitHub refuses every private build until the 1st, and deploys stop. After this change, Woodpecker builds and deploys those commits by itself, and it does nothing while minutes remain.

## In numbers

```numbers
caption: GitHub billing API and Actions runs, measured 2026-11-26
rows:
  - {label: Hours with no private builds after the quota ran out, Oct 2026, before: "34 (30 Oct 14:38 to 1 Nov 01:09 UTC)", after: "about 0.5, the cron interval plus billing lag"}
  - {label: Billing API delay behind finished jobs, before: "under 45 minutes", after: "same; the gate allows for it"}
  - {label: GitHub API calls per day while minutes remain, before: "0", after: "96, one billing call each 15 minutes", better: false}
  - {label: Builds in the cluster while minutes remain, before: "0", after: "0"}
```

## The system, with the change on it

```topology
caption: The normal path stays on GitHub. The fallback path runs only after GitHub refuses a build for billing.
direction: LR
groups:
  - {id: gh, label: GitHub}
  - {id: k8s, label: Sofia cluster}
nodes:
  - {id: gha, label: GitHub Actions build.yml, note: unchanged primary path, group: gh, state: same}
  - {id: billing, label: Billing usage API, group: gh, state: same}
  - {id: ghcr, label: ghcr.io images, group: gh, state: same}
  - {id: cron, label: "Woodpecker cron gha-fallback", note: every 15 minutes, group: k8s, state: new, risk: low}
  - {id: build, label: BuildKit rootless step, note: one build at a time, group: k8s, state: new, risk: medium}
  - {id: deploy, label: Per-app Woodpecker deploy, group: k8s, state: same}
  - {id: sdc, label: sdc spindle with etcd, scope: out}
edges:
  - {from: gha, to: ghcr, state: same, label: normal push}
  - {from: cron, to: billing, state: new, label: private minutes used}
  - {from: cron, to: build, state: new, label: refused commits only}
  - {from: build, to: ghcr, state: new, label: same tags as GitHub}
  - {from: build, to: deploy, state: new, label: IMAGE_TAG}
  - {from: build, to: sdc}
checks:
  - {node: cron, text: "A run under the quota prints the minutes used and exits in under 10 seconds", status: open}
  - {node: build, text: "A forced run builds infra-map's master, pushes ghcr.io/viktorbarzin/infra-map:<sha8>, and the deploy rolls it", status: open}
  - {node: build, text: "A forced run builds cloud's two targets from one build.yml", status: open}
  - {node: cron, text: "The tests replay the saved 30 Oct refusal and build only the refused commit", status: open}
left_out:
  - A self-hosted GitHub runner. It needs a host that is always on, and the Dell is stored.
  - Builds through the public cloud-builder repo. GitHub's terms limit hosted jobs to their own repo.
```

## Decisions

```decision
- question: Where do the fallback builds run?
  options:
    - {name: Woodpecker in the cluster, chosen: true}
    - {name: The devvm, note: needs a new daemon and puts credentials on the shared box; same sdc disk}
    - {name: The London Dell, note: it is off and stored}
  why: Deploys need the cluster anyway, and the disk risk is the same as on the devvm.
- question: How does the fallback find out that it must act?
  options:
    - {name: "Gate on the billing API, then look for refused runs", chosen: true}
    - {name: Scan every private repo's runs each few minutes, note: hundreds of API calls a day for nothing}
    - {name: A push pipeline in every app repo, note: edits each repo and fires on every push}
  why: One call answers "minutes remain" on almost every run.
- question: Which commits does it build?
  options:
    - {name: Only master runs that GitHub refused for billing, chosen: true}
    - {name: Any master commit with no image on ghcr, note: can deploy a commit that CI rejected}
  why: A real CI failure must stay a failure.
- question: Where do the image settings come from?
  options:
    - {name: "The repo's own build.yml at that commit", chosen: true}
    - {name: A list of apps in infra, note: drifts from the workflows}
  why: The docker/build-push-action steps already hold context, file, target, build args and tags.
- question: Which builder?
  options:
    - {name: BuildKit rootless, chosen: true}
    - {name: Kaniko, note: archived by Google in 2025; weaker on BuildKit-only Dockerfile features}
    - {name: Privileged Docker, note: root on the node for every build}
  why: It is the engine that GitHub's buildx uses, and it runs without privileged mode.
- question: Which credentials?
  options:
    - {name: Two narrow tokens from Viktor, chosen: true}
    - {name: The github_pat in secret/viktor, note: it has every scope, including delete_repo and admin:org}
  why: A token in the cluster must do only this job.
```

The two tokens:

- A classic token with only `write:packages`. ghcr takes only classic tokens for a push.
- A fine-grained token for all repos, with `Actions: read`, `Contents: read` and the account permission `Plan: read`.

The fallback clones from Forgejo with the existing `forgejo_repo_token`. It sends Slack a message when it first builds in a month and when a fallback build fails. The 2026-07-02 rule allows failure-only alerts. The first message reports a degraded state, so it counts as one.

## How one run works

1. Read the private minutes for the month from the billing API. Count only private repos, as the 2026-09-24 method does.
2. If the use is under 1,950 minutes, stop. The 50-minute margin covers the billing delay.
3. For each private repo with a `build.yml`, read the newest master run. Keep the run only if it has 0 steps and an annotation that names the spending limit.
4. Skip the commit if ghcr already has its `<sha8>` tag.
5. Clone the commit from Forgejo. Build each `docker/build-push-action` step of `build.yml`, then push the same tags.
6. Find the repo's Woodpecker id by name and start its deploy with `IMAGE_TAG`.

## Order of work

```timeline
caption: Every step can be undone. Deleting the cron stops the fallback at once.
steps:
  - {when: 1. Tokens, what: "Viktor creates the two tokens; they go to Vault secret/ci/gha-fallback and sync to Woodpecker", rollback: Revoke both tokens on GitHub}
  - {when: 2. Script and tests, what: "scripts/gha-fallback.py with tests on saved API responses; it ships in the infra-ci image", rollback: Revert the commit}
  - {when: 3. Pipeline, what: ".woodpecker/gha-fallback.yml and the cron, registered through the Woodpecker API", rollback: Delete the cron}
  - {when: 4. Proof, what: "A --check run, then forced runs for infra-map and cloud; read the live image tags", rollback: Redeploy the previous tag}
  - {when: 5. Docs, what: "ADR-0002 amendment, the infra CLAUDE.md rule, docs/architecture/ci-cd.md", rollback: Revert the commit}
```

## Configuration

```config
- {key: "Vault secret/ci/gha-fallback", where: Vault, old: "absent", new: "ghcr_push_token, github_read_token"}
- {key: "Woodpecker cron gha-fallback", where: "repo 1, ViktorBarzin/infra", old: "absent", new: "*/15 * * * *"}
- {key: "In-cluster build rule", where: "infra CLAUDE.md and ADR-0002", old: "never", new: "only the billing fallback"}
```

## Commands

```sh
homelab ci watch --repo ViktorBarzin/infra
python3 scripts/gha-fallback.py --check
python3 scripts/gha-fallback.py --force infra-map
kubectl -n infra-map get deploy infra-map -o wide
```
