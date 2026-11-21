---
status: accepted
date: 2026-06-12
---

# All owned images build off-infra on GitHub Actions and live on ghcr.io

In-cluster Woodpecker buildkit builds repeatedly hurt the homelab: registry-push load OOMKilled Forgejo (2026-06-09), buildkit→Forgejo pushes ride a flaky hairpin, build IO lands on the shared sdc HDD, and the Forgejo registry PVC sat at its 50Gi ceiling with retention stuck in DRY_RUN. We decided every owned image is built by GitHub Actions and hosted on ghcr.io, extending the tripit pilot (2026-06-09) to the whole fleet: Forgejo stays the canonical git host, a one-way push-mirror feeds a GitHub mirror, and the mirror's workflow builds, pushes, then POSTs Woodpecker's API to deploy. The Forgejo container registry is decommissioned as a build target — one manual cleanup pass keeps a last-known-good tag per Service, after which nothing pushes to it.

## Considered options

- **GHA builds pushing back into the Forgejo registry** — keeps images home and the pull path unchanged, but keeps the exact failure mode that motivated the move (Forgejo OOM under blob-push load), keeps the PVC growth, and keeps the circular dependency where the images needed to repair the cluster live inside the cluster. Rejected.
- **Per-repo in-cluster fallback builds** (the old `build-fallback.yml` pattern) — rejected in favour of a clean cut: a GitHub outage pauses image builds (running workloads are unaffected), and existing fallback files are deleted. The hedge against ghcr's "currently free" private storage ever being enforced is the visibility split (public images are permanently free) plus re-creating fallbacks if that day comes.
- **Paid builders (Docker Build Cloud, Depot)** — solve a multi-arch/persistent-cache problem this fleet doesn't have (everything is linux/amd64). Rejected.

## Consequences

- DR improves: images survive homelab loss, so a dead cluster can pull everything it needs to come back — the same doctrine that keeps the monorepo on GitHub ("Forgejo dies with the cluster").
- Private ghcr pulls bypass the registry VM's pull-through cache (it can't authenticate), so cold-node pulls of private images depend on GitHub availability; public images cache normally.
- Visibility is decided per repo: public = generic tooling that passes a gitleaks/PII history scan; private = personal, financial, or legally-gray domains. A failed scan means the repo stays private — canonical history is never rewritten for publication. For interpreted languages repo visibility ≈ image visibility (the image ships the source).
- Only private-repo builds consume GitHub free-plan minutes (~12 builders, well under the 2,000/mo free tier; usage is reviewed after rollout wave 2 before considering Pro).
  - Update 2026-09-24: September's private usage reached 90% of the 2,000 by the 24th. The response kept the Free plan and trimmed the workflows instead; see "GitHub Actions minutes" in `docs/architecture/ci-cd.md`.
- Woodpecker becomes deploy-only; its agents never build. The Kyverno-synced `registry-credentials` stays (Forgejo git + frozen last-known-good images); a cluster-wide Kyverno-synced `ghcr-credentials` joins it.
- Builders with no live consumer (terminal-lobby, webhook-handler, hmrc-sync, trading-bot, travel-agent, trip-planner) are decommissioned rather than migrated; travel_blog is decommissioned outright (service + CI). Any revival adopts this ADR's pattern.
- Workflows build single-manifest images (`provenance: false`, linux/amd64 only) so registry retention never faces the orphaned-index-children failure class that broke Forgejo's cleanup.

## Amendment 2026-11-21: builds may run on an Opportunistic worker's host runner

October 2026 used all 2,000 free minutes for private repos (tv 1,775). The London Dell becomes an Opportunistic worker (ADR-0045), and a self-hosted GitHub Actions runner runs on its host as a systemd service, for a list of repos that burn minutes (tv and tripit first).

- This does not reopen in-cluster builds. The runner runs on a tainted Physical node that takes only opt-in work, with the kubelet reserving CPU and RAM. The original reasons (Forgejo OOM, sdc IO, registry PVC) do not apply: images still push to ghcr.io, and nothing writes to Sofia storage.
- Workflows pick the London runner when it is online and fall back to GitHub-hosted runners when it is not. Builds never wait for the Dell.
- The runner's token and work directories live on the node's State volume, so they decrypt only when the node reaches Tang (ADR-0045).
