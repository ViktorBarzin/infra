# CI/CD architecture

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/architecture/ci-cd.md`.

## CI/CD Architecture — GHA Builds → ghcr + Woodpecker Deploy

**Doctrine (ADR-0002, fleet-wide as of 2026-06-13): ALL image builds + CI
compute run OFF-infra.** Every owned image is built/linted/tested on GitHub
Actions (public repos: free; private: 2000 free min/mo) and pushed to
`ghcr.io/viktorbarzin/<name>`. **No in-cluster image builds or CI test runs
exist anywhere** — the in-cluster Woodpecker buildkit and the fallback-build
pattern were removed (clean cut). Woodpecker is **deploy-only** (plus infra
applies + maintenance crons). Canonical CI/CD reference:
`docs/architecture/ci-cd.md`; decision: `docs/adr/0002-all-image-builds-off-infra-gha-ghcr.md`.
**Watch what you trigger**: after a push that fires a build chain, follow it to
completion (GHA run → Woodpecker deploy → `rollout status`) and fix failures;
verify via live state, not the checkmark.

**The fleet pattern (every owned app):** Forgejo `viktor/<repo>` (canonical)
push-mirrors (`sync_on_commit`) → GitHub `ViktorBarzin/<repo>` → GHA
`.github/workflows/build.yml` (committed on Forgejo, mirrors over): `on: push:
branches:[master]` ONLY (feature branches mirror but build/deploy nothing — the
safety valve). The `build` job: lint/test → `svu` cuts the next `vX.Y.Z` tag to
CANONICAL Forgejo (GHA secret `FORGEJO_GIT_TOKEN` = write:repository PAT) + bakes
`VERSION` → `buildx` `linux/amd64` `provenance:false` (single-manifest, dodges
the orphaned-index-children class) → push `ghcr.io/viktorbarzin/<name>:<sha8>` +
`:latest` → `delete-package-versions` keep-10. The `deploy` job POSTs
`ci.viktorbarzin.me/api/repos/<id>/pipelines` (the GitHub-mirror's Woodpecker
registration, github-forge; GHA secret `WOODPECKER_TOKEN`) with `IMAGE_TAG` +
`IMAGE_NAME` → `.woodpecker/deploy.yml` (event:**manual** ONLY, so the raw
Forgejo→GitHub mirror pushes don't fire a tag-less deploy) runs `kubectl set
image deployment/<app> …` in-cluster (woodpecker-agent SA = cluster-admin, no
kubeconfig). Deployment image is `ignore_changes`/KEEL_IGNORE_IMAGE so the SHA
sticks vs `terragrunt apply`; CronJobs track `:latest` + `imagePullPolicy:
Always`. **Keel stays enrolled** as a redundant net (sees the SHA already
running → no-op). **Never** `set image`/`rollout restart` operator-managed
StatefulSets (memory id=740). Onboarding tool: `scripts/offinfra-onboard` +
`scripts/offinfra-templates/`; mirror + workflow commits via the Forgejo API over
the internal Traefik LB (`curl --resolve forgejo.viktorbarzin.me:443:10.0.20.203`).
Reference impls: tripit (the original pilot), f1-stream, job-hunter, tuya_bridge.

**Migrated apps (issues #13–#27):** f1-stream, job-hunter, tuya_bridge,
beadboard, nextcloud-todos, claude-agent-service, **claude-memory-mcp** (GHA →
ghcr, NOT DockerHub), kms-website, Freedify, instagram-poster, payslip-ingest,
broker-sync (image `wealthfolio-sync`), fire-planner, recruiter-responder,
x402-gateway — plus tripit. Earlier public-repo apps already on GHA (Website,
apple-health-data, audiblez-web, plotting-book, insta2spotify,
audiobook-search) now also land on ghcr.
- **PUBLIC ghcr packages:** beadboard, nextcloud-todos, claude-agent-service,
  claude-memory-mcp, kms-website, freedify, tuya_bridge, x402-gateway,
  android-emulator.
- **PRIVATE ghcr:** f1-stream, job-hunter, instagram-poster, payslip-ingest,
  wealthfolio-sync, fire-planner, recruiter-responder, tripit, infra-cli,
  infra-ci, k8s-portal, excalidraw-library, chesscom-streak. Pulled via the Kyverno-synced `ghcr-credentials` allowlist
  (`stacks/kyverno/modules/kyverno/ghcr-credentials.tf`; NOT cluster-wide; cred
  = Vault `secret/viktor/ghcr_pull_token`, a dedicated classic PAT scoped to
  `read:packages` (UI-minted 2026-06-15; no longer the admin `github_pat`
  alias). GitHub has no token-mint API, so rotation is manual: re-mint →
  `vault kv patch secret/viktor ghcr_pull_token=…` → targeted apply
  `module.kyverno.kubernetes_secret.ghcr_credentials` (reads Vault, dodges the
  git-crypt tls-secret-sync landmine), Kyverno re-syncs the allowlist).

**Infra-owned images (issues #29/#30)** build on GHA workflows IN the infra
repo's own `.github/workflows/` (added to the GitHub lineage via PR; the
github↔forgejo divergence was deliberately NOT reconciled):
`build-android-emulator.yml` → public ghcr;
`build-cli.yml` → DockerHub `viktorbarzin/infra` (kept) + `ghcr.io/viktorbarzin/infra-cli`;
`build-infra-ci.yml` → `ghcr.io/viktorbarzin/infra-ci`; `build-k8s-portal.yml` →
PRIVATE `ghcr.io/viktorbarzin/k8s-portal` (Keel-deployed; the LAST in-cluster
Woodpecker build, migrated 2026-06-13 — completes "no local builds"); `build-excalidraw.yml` →
PRIVATE `ghcr.io/viktorbarzin/excalidraw-library` (Keel-deployed; replaced
manual DockerHub pushes 2026-07-02 — DockerHub `:v4` frozen as rollback). **infra-ci**
is the image the `.woodpecker/default.yml` apply step + `drift-detection.yml` run
in (proven by pipelines 165/166). chatterbox-tts is already built by tripit's GHA → ghcr.
The Woodpecker `build-ci-image.yml` + `build-cli.yml` pipelines were REMOVED;
infra-ci break-glass is a manual `.woodpecker/breakglass-infra-ci.yml` (ghcr
pull-and-save to the registry VM).

**Forgejo container registry: FROZEN + emptied** (issue #32 wiped all `viktor/*`
container packages). Break-glass-only now; nothing pushes. `forgejo-cleanup`
stays DRY_RUN. Pull-through caches on `10.0.20.10` are unchanged. Runbook:
`docs/runbooks/forgejo-registry-breakglass.md`.

**Woodpecker now runs only:** per-app `deploy.yml` (manual, `kubectl set
image`), `default.yml` (terragrunt apply), `renew-tls.yml` (certbot),
maintenance crons (drift-detection, provision-user, registry-config-sync,
pve-nfs-exports-sync, postmortem-todos), and the
manual `breakglass-infra-ci.yml`. **No build/test pipeline on any repo — do not
(re)introduce one.** (`.woodpecker/k8s-portal.yml`, the last in-cluster image
build, was removed 2026-06-13 — k8s-portal now builds on GHA → ghcr, see
Infra-owned images above.)

**Decommissioned (issue #31):** travel_blog (stack destroyed + dir removed), 6
dead builders' pipelines (terminal-lobby, webhook-handler, hmrc-sync,
trading-bot, travel-agent, trip-planner), and all `build-fallback.yml` files
(only Website had one).

**Woodpecker API**: numeric repo IDs (`/api/repos/<id>/pipelines`), NOT
owner/name (those return HTML). The deploy registration for each app is the
**GitHub mirror** repo (github-forge). Infra: Forgejo forge = repo 82, legacy
GitHub forge = repo 1.

**Woodpecker YAML gotchas**:
- Commands with `${VAR}:${VAR}` must be **quoted** — unquoted `:` triggers YAML map parsing when vars are empty
- Use `bitnami/kubectl:latest` (not pinned versions — entrypoint compatibility issues)
- Global secrets must have `manual` in their events list for API-triggered pipelines

**GitHub repo secrets** (per repo): `WOODPECKER_TOKEN` (POST deploy pipeline),
`FORGEJO_GIT_TOKEN` (write:repository PAT for the svu tag push). ghcr push uses
the workflow's built-in `GITHUB_TOKEN` (`packages: write`).
