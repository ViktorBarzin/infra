# Keep Forgejo as the canonical forge; complete the one-way GitHub mirror instead of swapping to GitHub

Status: accepted (extends ADR-0002)

## Context

Repo trees kept diverging between the Forgejo **Canonical repo** (`viktor/<name>`) and its **GitHub mirror**. A 2026-06-15 audit found the cause: an *incomplete rollout* of the Forgejo→GitHub push-mirror, not anything inherent to Forgejo. 14 repos carry **both** remotes and are hand-pushed to each (`push_mirrors = 0` on Forgejo — e.g. `infra`, `finance`, `Website`), so a human forgets one side and the trees drift; the ADR-0002-onboarded repos have a working one-way mirror (`push_mirrors = 1` — e.g. `tripit`, `recruiter-responder`) and never diverge. `infra/CONTEXT.md` already says Forgejo is the only place commits land and the GitHub mirror must never be a second writable remote — practice had simply drifted from the documented model.

The trigger was a proposal to swap Forgejo out for GitHub entirely. The grilling reframed it: the pain (divergence) is a "two writable remotes" problem, and the stated preference is self-hosted-primary with the remote as backup.

## Decision

Do **not** swap to GitHub. Reaffirm and *complete* the model already in `CONTEXT.md`:

- Every first-party repo has exactly **one** push target — its **Canonical repo** on Forgejo. GitHub is a one-way push-mirror (off-site backup + the source GitHub Actions builds from). **No repo is ever dual-pushed.**
- A small, explicit set of **GitHub-first repos** are the exception (canonical lives on GitHub, outside the mirror policy): third-party clones/forks where GitHub is genuinely upstream (`jsoncrack.com`, `snmp_exporter`, `SparkyFitness`, `agent-rules-books`, `Plotting-Your-Dream-Book`) and the deliberately-public first-party `health`.
- `infra` is reconciled into the standard model: its GitHub-only `.github/workflows/build-*.yml` are brought onto Forgejo-canonical (inert on Forgejo, active on the mirror), then the mirror is enabled — ending the deliberate divergence while keeping Woodpecker on the Forgejo forge.
- Enforcement is **structural**: reconciled clones keep only the Forgejo remote, so there is no GitHub remote to habitually push to; the execution rule is "push to the canonical forge only, never the mirror."

## Considered options

- **Swap to GitHub (retire Forgejo).** Rejected: takes on a hard WAN dependency for *all* git ops — including `infra`, the repo you use to *recover* from outages — plus git-crypt secrets on GitHub as primary, a Woodpecker forge migration (WP authenticates against and watches Forgejo), and GitHub private-repo CI-minute/size limits. All to fix a problem that is actually an incomplete mirror, not Forgejo's existence. Contradicts the self-hosted-primary preference.
- **GitHub canonical, Forgejo demoted to a DR pull-mirror.** Rejected for the same WAN-dependency and forge-migration cost; unnecessary once the real cause is understood.

## Consequences

- Divergence becomes structurally impossible — one push target per repo.
- Forgejo stays load-bearing (canonical git + the Woodpecker forge), so every cost of the swap is avoided.
- The GitHub-limits worry is neutralized: private code lives on Forgejo (unlimited, self-hosted); GitHub holds mirrors for CI + backup. (GitHub Free has unlimited private repos anyway; the real limits are GHA minutes and ~1 GB repo size — `travel_blog` at 1.4 GB is why it never went to GHA.)
- One-time remediation is required and carries a data-loss footgun: the Forgejo→GitHub mirror **force-overwrites** GitHub, so for each currently-diverged repo, any GitHub-only commits must be merged into Forgejo **before** the mirror is enabled, or they are lost. Scope: the 14 dual-push repos + the `infra` reconciliation; all other repos are already single-remote and non-diverging.
