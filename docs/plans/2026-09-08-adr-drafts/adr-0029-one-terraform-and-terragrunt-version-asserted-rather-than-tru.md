# ADR-0029: One Terraform and Terragrunt version, asserted rather than trusted

Date: 2026-09-08
Status: Proposed

## Context

Three places plan or apply this repo and they run different toolchains, verified
2026-09-08:

| where | Terraform | Terragrunt |
|---|---|---|
| `ci/Dockerfile:9` (CI) | 1.15.4 | 0.99.4 |
| `claude-agent-service/Dockerfile:13` (the fixer agent) | **1.5.7** | 0.99.4 |
| the devvm workstation | 1.15.4 | **0.77.20** |

`required_version` appears twice in the whole repo and both occurrences are
commented out.

The skew has already caused an incident. On 2026-09-02, every plan of 91
consumer stacks failed because `modules/kubernetes/ingress_factory`'s sablier
validation dereferences a null: 1.5.7 evaluates `var.sablier.strategy` even when
`var.sablier == null`, while 1.15.4 short-circuits correctly. Only the fixer
agent hit it, so the one automated repairer in the estate lost the ability to
plan almost any stack in the repo. The module got a `try()` workaround and the
fix commit records the remainder plainly: "Not fixed here: the version skew
itself." Six separate candidate submissions across this study's lanes describe
this one open defect, which is a reasonable signal that it is worth closing.

The direction of travel is not arbitrary. `ci/Dockerfile` lines 4 to 8 record
that the older 1.5.7 pin paired with `hashicorp/kubernetes` 3.x produced the
"Missing Resource Identity After Update" failures of issue #68, which is why CI
moved to 1.15.4 and why the root generate block carries a `>= 3.2.1` provider
floor.

There is a related and separable problem worth naming rather than bundling.
`.terraform.lock.hcl` is gitignored, so each environment keeps whatever it last
resolved. Measured: 15 of 155 local lockfiles pin `hashicorp/kubernetes` inside
the 3.0.x to 3.1.x range that the root floor exists to forbid, and 81 of 155
pin `goauthentik/authentik` 2024.12.1 against a root constraint of `~> 2025.8`,
which makes `terraform init -reconfigure` fail locally in those 81 directories.
CI is immune, because a fresh clone has no lockfile.

## Decision

Do both halves.

1. **Align the images.** Move `claude-agent-service/Dockerfile` to the same
   Terraform version CI runs, and bring the devvm's Terragrunt up to CI's
   0.99.4 through `playbooks/devvm.yml` rather than by hand.
2. **Assert it.** Add `required_version` to the root `generate "k8s_providers"`
   block, so a mismatched binary fails at `init` with "Unsupported Terraform
   Core version" instead of presenting as a null dereference 91 stacks deep.

Use a range, not an exact pin, so a patch bump in one image does not wedge the
others: `>= 1.15.0, < 2.0.0` is the shape that matches the recorded reasoning.

Do not commit lockfiles as part of this change. That is a separate decision with
its own churn, and this repo has a receipt for why generated tracked files hurt:
70 generated `providers.tf` files were untracked because they left the shared
checkout dirty and blocked merges.

## Alternatives

- **Pin only the fixer agent's image.** Fixes the one recorded incident and
  leaves the class open. The failure would recur silently the next time any of
  the three environments moves, and nothing would name it.
- **Add `required_version` only, and leave the images skewed.** Turns a silent
  wrong answer into a loud refusal, which is a genuine improvement, but it means
  the fixer agent cannot plan at all until the image is rebuilt. Worse than doing
  both, in the same amount of work.
- **`required_version` per module rather than at the root.** Narrower blast
  radius and it would have caught the actual incident, since `ingress_factory` is
  where the defect lived. Rejected because the root block is the only place that
  reaches all 152 stacks, and the failure it prevents is environment-wide rather
  than module-specific.
- **Commit the lockfiles.** Makes the provider set a repo artefact and removes
  the stale-floor mechanism entirely, which is a real benefit. Deferred: the
  churn objection is measured, and this ADR is about the skew that actually broke
  something.

## Consequences

**Positive**
- Removes a live defect. The fixer agent can plan the repo again, which matters
  because it is the estate's only automated repairer.
- A future skew names itself at `init` in every environment rather than
  surfacing as a module-level type error in one.
- One line in the root generate block, and one line in each Dockerfile.

**Negative**
- The root generate block is the highest-blast-radius file in the repo: a change
  there alters all 152 stacks and CI re-applies 31, leaving 121 to pick it up on
  their next own-path commit or from the nightly drift run. That gap is
  documented separately and is not made worse by this change, but it is the
  reason to land this on a quiet day.
- A version range needs an owner. Left alone for a year it becomes the same
  stale-floor problem one level up.
- It does not address the 81 local lockfiles pinning a rejected authentik
  provider, so `terraform init -reconfigure` keeps failing in those directories
  until someone runs `-upgrade`. Worth a one-line note in the runbook.
