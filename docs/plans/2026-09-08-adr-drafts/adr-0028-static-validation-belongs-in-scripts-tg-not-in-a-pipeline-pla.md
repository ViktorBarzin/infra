# ADR-0028: Static validation belongs in `scripts/tg`, not in a pipeline plan gate

Date: 2026-09-08
Status: Proposed

## Context

`.woodpecker/default.yml` runs `terragrunt apply --non-interactive` per selected
stack. Terraform's own internal plan inside `apply` is the only plan. `terraform
validate`, `terraform fmt`, `terragrunt hclvalidate`, `homelab tf plan` and
`homelab tf validate` all exist, all work, and CI calls none of them. The 292
tests already under `scripts/` are also run by no pipeline, and 5 of them have
been failing for 44 days because a commit added a check to `scripts/tg` without
updating the test's fake repo.

Three incidents in the window are static-analysis shaped, and `validate` catches
all three:

| incident | what `validate` reports | measured |
|---|---|---|
| 2026-08-15 wireguard, a bulk-edit script appended a second `lifecycle` block | Duplicate lifecycle block | 0.06 s, no init |
| 2026-09-01 traefik, a nested `resource` block reached master and queued every stack behind it | Blocks of type resource are not expected here | 1.05 s after an 8.5 s init |
| 2026-07-27 to 2026-08-14 `stacks/learning`, `wait_until_bound` inside a PVC spec | An argument named wait_until_bound is not expected here | under 1 s |

`terraform fmt -check` passes on all three, so `fmt` is not a substitute.

The obvious larger version of this, plan-then-apply with a gate, was costed and
does not pay here. Its plan pass catches zero marginal incidents: four of its
candidate rows are in-place drift, which the gate's own design warns about rather
than blocks; two are config-loader errors that `apply` already rejects before
touching state; and one whole class is already covered, since `DriftStackErrored`
(`drift_error_count > 0`, `for: 2h`) has alerted on unplannable stacks since
2026-08-14, and its own commit message uses the `stacks/learning` case as the
worked example.

The blocking half is worse than neutral. Blocking on a planned destroy or replace
blocks every push to `stacks/monitoring` permanently, because
`null_resource.grafana_admin_only_folder_acl` sets `triggers = { always =
timestamp() }` by design and both instances report "must be replaced" on every
plan. `stacks/monitoring` is the busiest stack in the repo at 194 commits in 90
days and holds all 375 alert definitions. `stacks/infra` has the same shape. The
wider surface is 27 `null_resource` declarations across 8 stacks and 12
`kubernetes_job` resources across 11.

Cost also matters. Plan and apply both do a full init, refresh and graph walk, so
a plan pass roughly doubles Terraform work per stack: 20 to 60 s per changed
stack against real apply durations of 21 to 133 s, at roughly 39 stack-plans a
day. It also doubles PG advisory-lock exposure on 146 of 152 Tier-1 stacks, and
`scripts/tg`'s own header names contended state locks as the leading cause of
infra CI failures.

`scripts/tg` already runs three blocking Python pre-flight checks on
`plan|apply|destroy|refresh`, at 0.41 to 0.48 s for all three, gated on
`$is_tf_op` at lines 132 to 148.

## Decision

Add `terragrunt validate` to that existing pre-flight block, gated on
`error_count` only. One insertion point covers three callers: CI, the
workstation, and the fixer agent.

Do not add a plan pass to `.woodpecker/default.yml`, and do not gate on planned
destroys or replacements.

Pair it with a `PreToolUse` hook in the provisioned hook channel that refuses an
agent's push of Terraform nothing validated. That buys no marginal incidents over
the `scripts/tg` gate, and it buys a shorter loop for the party writing roughly
half the commits at about 25 a day. The hook must allow-with-warning when
`validate` cannot run, or it wedges sessions.

## Alternatives

- **A step in `.woodpecker/default.yml`.** Rejected on placement, not on merit.
  That file matches no alternative in the change-detection regex and no path
  filter, so a change to it re-applies zero stacks: the gate would ship
  unexercised and first run on somebody else's unrelated push. It also would not
  cover the workstation or the fixer agent.
- **A rule in `infra/.claude/CLAUDE.md`.** Documentation is the weakest control
  shape available here. The Kyverno server-dry-run requirement is already in bold
  in that file, and `--dry-run=server` appears twice in 1,847 transcripts. The
  provisioned hook channel can intercept a command; a rule file cannot, and
  `zsh-guard.py`'s own docstring makes that argument.
- **A pre-push git hook.** No pre-push hook exists in either clone, and the
  git-hook channel is not provisioned: emo's `.git/hooks` is empty. Secret
  scanning already sits in exactly that gap.
- **Plan the fan-out stacks the commit did not touch.** Genuinely catches the
  unswept-consumer half of the shared-root bucket, and it needs the plan path
  working first. Today `homelab tf plan` fails in 141 of 158 stack directories,
  because the Vault static role rotates the PG state password every 7 days and
  `scripts/tg` never passes `-reconfigure`. Fix that first, separately.

## Consequences

**Positive**
- Three incidents move from "CI caught it in minutes and one platform queue was
  blocked" to "the author's own shell caught it in seconds".
- One insertion point, three callers, no new pipeline logic, no plan output to
  store, no verb parsing and no allowlist.
- The `.tftest.hcl` suites for the four shared modules become worth writing,
  because there is finally a place that runs them.

**Negative**
- 2 to 5 s added per stack on every local `plan` and `apply`, and about 4 s on a
  median single-stack CI push. Small, and it is a real tax on the fastest
  workflow in the repo.
- `validate` must gate on errors only. `stacks/monitoring` alone emits 144
  provider deprecation warnings, and a warning-sensitive gate would be red from
  the first run.
- A full 152-stack sweep should confirm zero errors before the gate goes live.
  Sampled 11 already-initialised stacks and all were clean, but parallel sweeps
  over a shared `TF_PLUGIN_CACHE_DIR` produced 27 of 152 spurious failures, so
  the sweep needs per-worker plugin directories.
- It does not touch the four largest incident buckets. This is a cheap fix for a
  small, real, recurring class.
