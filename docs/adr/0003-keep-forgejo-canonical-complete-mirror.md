# Keep Forgejo as the canonical forge; complete the one-way GitHub mirror instead of swapping to GitHub

Status: accepted (extends ADR-0002)

## Context

Repo trees kept diverging between the Forgejo **Canonical repo** (`viktor/<name>`) and its **GitHub mirror**. A 2026-06-15 audit found the cause: an *incomplete rollout* of the Forgejo→GitHub push-mirror, not anything inherent to Forgejo. 14 repos carry **both** remotes and are hand-pushed to each (`push_mirrors = 0` on Forgejo — e.g. `infra`, `finance`, `Website`), so a human forgets one side and the trees drift; the ADR-0002-onboarded repos have a working one-way mirror (`push_mirrors = 1` — e.g. `tripit`, `recruiter-responder`) and never diverge. `infra/CONTEXT.md` already says Forgejo is the only place commits land and the GitHub mirror must never be a second writable remote — practice had simply drifted from the documented model.

The trigger was a proposal to swap Forgejo out for GitHub entirely. The grilling reframed it: the pain (divergence) is a "two writable remotes" problem, and the stated preference is self-hosted-primary with the remote as backup.

## Decision

Do **not** swap to GitHub. Reaffirm and *complete* the model already in `CONTEXT.md`:

- Every first-party repo has exactly **one** push target — its **Canonical repo** on Forgejo. GitHub is a one-way push-mirror (off-site backup + the source GitHub Actions builds from). **No repo is ever dual-pushed.**
- A small, explicit set of **GitHub-first repos** are the exception (canonical lives on GitHub, outside the mirror policy): third-party clones/forks where GitHub is genuinely upstream (`jsoncrack.com`, `snmp_exporter`, `SparkyFitness`, `agent-rules-books`, `Plotting-Your-Dream-Book`) and the deliberately-public first-party `health`. **Added 2026-09-02 (infra#40)**: `realestate-crawler`, whose live repo is the org repo `immovika/realestate-crawler` rather than `ViktorBarzin/*`. A second org member (`ktugan`) contributes there and keeps their own branches, so a force-pushing Forgejo mirror would work against a collaborator. Forgejo `viktor/wrongmove` is the stale side (0 ahead, 60 behind as of 2026-09-02) and is retired rather than reconciled. `Plotting-Your-Dream-Book` (owned by Anca, dev in her org) keeps its GHA build in-place and pushes the image to **its own org's ghcr** (`ghcr.io/passionprojectsanca/book-plotter`, private) via the workflow's built-in `GITHUB_TOKEN` — no Forgejo mirror, no `viktorbarzin`-namespace push, no shared PAT in her repo (2026-06-27, migrated off DockerHub). **Added 2026-09-02 (infra#39)**: `audiblez-web`. The Forgejo repo is
  *empty* — no branches, `empty=true` — while `ViktorBarzin/audiblez-web` is
  active and was pushed the same day. Both are archived on the Forgejo side so
  no mirror can be enabled there: enabling one attempts to **delete GitHub's
  `main`**, and only GitHub's refusal to delete a default branch prevents the
  loss. An empty canonical side with a mirror configured is a data-loss weapon
  pointed at the mirror target, which is the inverse of the usual drift trap.
- A second, smaller exception category: **Forgejo-only repos**, which are
  deliberately *not* mirrored anywhere. Decided 2026-09-02 (infra#39):
  `hmrc-sync`, `portal-assistant`, `travel-agent`. Each is first-party and each
  would need a new GitHub repo created to be mirrored, which ADR-0002 gates on a
  clean gitleaks/PII history scan. Viktor's call was that their contents should
  not leave the house even into a private GitHub repo. The cost is explicit and
  accepted: these three have **no off-site backup**, so a cluster loss loses
  them. Anything mirrored elsewhere survives; these do not.

## The one-remote rule, precisely

A local clone carries exactly one remote, `origin`, pointing at Forgejo. The
GitHub side is reached only by the server-side push-mirror, never by a second
push remote in a working copy — that is what produced the divergence this ADR
exists to end.

Two shapes are allowed and are not violations:

- A **GitHub-first** repo's clone has one remote pointing at GitHub. Same rule,
  different canonical.
- A **fetch-only `upstream`** on a genuine fork. `beadboard` is one: it forks
  `zenchantlive/beadboard` and shares a merge-base with it, so `upstream` is a
  source to pull from rather than a target to push to. A read-only second remote
  cannot cause divergence.

Swept 2026-09-02 across every clone under `~/code`: no repo carries two push
remotes. `finance` and `portal-immich-frame` were the last two and both were
reconciled that day.

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
