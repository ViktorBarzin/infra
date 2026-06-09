# f1-stream extraction + productionization — design (2026-06-04)

## Problem

The actively-developed f1-stream codebase (FastAPI backend serving a SvelteKit
SPA; ~19 pluggable stream extractors + a Playwright/chrome-service playback
verifier) lived **inside** the infra monorepo at
`infra/stacks/f1-stream/files/`. It had no standalone repo, no real CI (only a
manual `redeploy.sh` doing a local `docker buildx` push), no tests, a loose
unpinned `requirements.txt`, and no semver.

**Key gotcha (the source-of-truth confusion):** there is ALSO an older
`github.com/ViktorBarzin/f1-stream` (`main`, last commit 2026-03-29, 14
extractors, no verifier) — and the *currently-deployed* image
(`viktorbarzin/f1-stream:<sha>`, Keel-managed) is built from THAT github repo,
not from `files/`. So the `files/` copy was the newer, richer, but
**never-properly-deployed** version. Viktor confirmed (2026-06-05) the
`files/` version is the one to ship; this extraction makes it the canonical
repo AND finally deploys it (changing the live app from the stale March build
to the current code).

## Goal

Extract `files/` into its own Forgejo repo `viktor/f1-stream`, productionize it
(Poetry, ruff, mypy, pragmatic tests, README, semver `v2.0.1`, Woodpecker CI),
point the infra Terraform stack at the Forgejo image, and remove `files/`.

## Decisions

- **Registry → Forgejo private** (`forgejo.viktorbarzin.me/viktor/f1-stream`).
  Deployment gets `image_pull_secrets { registry-credentials }`.
- **Packaging → Poetry + ruff + mypy** (Poetry 2.1.3, lock committed). Python
  **package stays `backend`** (imports + `uvicorn backend.main:app`). **Python
  3.13** kept.
- **Tests → pragmatic pure-logic only**: m3u8_rewriter, the proxy HLS parsers,
  schedule parsing/status, extractor registry. 63 tests; ruff + mypy clean.
- **CI → single `.woodpecker.yml`**: lint+type+test → buildx push to Forgejo
  (tags `latest` + `<short-sha>`) → `kubectl set image` + rollout. Keel stays
  enrolled as a redundant net. (No Slack step — the `environment:{from_secret}`
  form is rejected by this Woodpecker version's decoder.)
- **Dockerfile → no bundled Chromium.** In-cluster the verifier drives the
  shared chrome-service over CDP and never launches a local browser. Bundling
  Chromium broke the in-cluster buildkit build (`playwright install chromium`
  times out fetching ~165MB from the Azure CDN through cluster egress). The
  `playwright` pip package stays for the CDP client.
- **Versioning → first git tag `v2.0.1`** (continuity with the existing image
  lineage), deviating deliberately from the `v0.1.0` precedent.
- **Runtime stays root** (matching the prior working image) to avoid an NFS /
  Chromium-cache regression.

## Terraform delta (only infra change)

`stacks/f1-stream/main.tf`: image → `forgejo.../viktor/f1-stream:${var.image_tag}`
(new `var.image_tag`, default `latest`) + `image_pull_secrets`; remove `files/`
and `redeploy.sh`. Image field stays in `ignore_changes` (KEEL_IGNORE_IMAGE);
the running tag is managed by CI/Keel/`kubectl set image`, not Terraform.
Everything else (Anubis, ingress, ExternalSecrets, NFS, chrome-service +
Discord env) unchanged.

## Operational notes / known rough edges (2026-06-05)

- The Woodpecker repo (id 166) was registered via the JWT-mint script and its
  config-fetch user association is currently broken (`user does not exist
  [uid:0]`) — pipelines error. Until re-enabled via the Woodpecker UI OAuth,
  the image is built+pushed manually from the devvm.
- The infra repo's `origin` (github) and `forgejo` (CI-canonical) remotes are
  diverged; this change is applied via `scripts/tg apply` locally and committed;
  landing it on `forgejo/master` for CI durability depends on the normal
  origin↔forgejo reconciliation.

## Blast radius

The `f1-stream` K8s service is the only consumer; no `.tf` references `files/`.
Switching the live image to the Forgejo build is the intended, user-approved
behavior change (stale March build → current code).
