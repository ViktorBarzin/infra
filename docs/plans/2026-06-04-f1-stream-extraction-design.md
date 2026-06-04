# f1-stream extraction + productionization — design (2026-06-04)

## Problem

`f1-stream` (FastAPI backend serving a SvelteKit SPA; ~15 pluggable stream
extractors + a Playwright/chrome-service playback verifier) lived **inside**
the infra monorepo at `infra/stacks/f1-stream/files/`. It had:

- no standalone repo — source coupled to the Terraform stack;
- **no real CI** — only a manual `redeploy.sh` doing a local `docker buildx`
  push to DockerHub (`viktorbarzin/f1-stream`) + `kubectl rollout restart`;
- no README, no tests, a loose unpinned `requirements.txt`, no semver tags;
- a stale CI claim in docs ("migrated to GHA, Woodpecker repo id 10") that did
  not match reality (no GHA workflow ever existed for it).

## Goal

Extract the app into its own Forgejo repo `viktor/f1-stream` and productionize
it, mirroring the established owned-app pattern (`tuya_bridge`, `job-hunter`,
`tripit`, `travel-agent`).

## Decisions (with rationale)

- **Registry → Forgejo private** (`forgejo.viktorbarzin.me/viktor/f1-stream`),
  matching the fleet standard. Needs the `registry-credentials` pull secret
  (Kyverno-synced to every namespace) on the deployment.
- **Packaging → Poetry + ruff + mypy** (replaces the loose pip
  `requirements.txt`). Python **package stays `backend`** — imports are
  `from backend.x` and the entrypoint is `uvicorn backend.main:app`; renaming
  would churn every module + the Dockerfile + the staticfiles path. Python
  **3.13 kept** (the live image already runs it; tripit's 3.12 pin is for
  zxing-cpp/pymupdf, which f1-stream lacks).
- **Tests → pragmatic pure-logic only**. The extractors + verifier are
  network/browser-bound; full coverage is brittle. Unit-test the deterministic
  core: `m3u8_rewriter` (incl. the EXT-X tag rewriters), the `proxy` HLS
  parsers, `schedule` parsing/status, the extractor `registry`. 63 tests.
- **CI → single `.woodpecker.yml`**: `lint-and-test` (ruff + mypy + pytest on
  `python:3.13-slim`) → `build-and-push` (buildx → Forgejo, tags `latest` +
  `${CI_COMMIT_SHA:0:8}`) → `deploy` (`kubectl set image` + `rollout status`).
  **Keel stays enrolled** as a redundant net. This is the `tuya_bridge`
  "build drives the rollout" model + a `travel-agent`-style test gate.
  - A Slack-notify step was prototyped but **dropped**: the
    `environment: { from_secret }` form is rejected by this Woodpecker
    version's pipeline-struct decoder (`yaml: did not find expected key`), and
    the canonical owned-app refs (`tuya_bridge`, `job-hunter`) have no Slack
    step. Deploy success is confirmed by `rollout status`.
- **Versioning → first git tag `v2.0.1`** (continuity with the existing image
  lineage; a fresh `v0.1.0` on a production 2.x app would mislead
  monitoring/homepage). Deviates deliberately from the `v0.1.0` precedent of
  tripit/travel-agent.
- **Runtime stays root** (matching the prior working image) to avoid a
  non-root regression on the `/data` NFS write path and the Playwright browser
  cache. Non-root is a possible future hardening.

## Terraform delta (the only infra change)

`infra/stacks/f1-stream/main.tf`:

- image `viktorbarzin/f1-stream:latest` (DockerHub) →
  `forgejo.viktorbarzin.me/viktor/f1-stream:${var.image_tag}` (new
  `var.image_tag`, default `latest`);
- add `image_pull_secrets { name = "registry-credentials" }` to the pod spec;
- delete `files/` (source now lives in the standalone repo) and `redeploy.sh`.

The image field is in the deployment's `ignore_changes` (KEEL_IGNORE_IMAGE), so
the live tag is managed by CI/Keel, not Terraform. Everything else — namespace,
ExternalSecrets (`f1-stream-secrets`, `chrome-service-client-secrets`), NFS data
volume, Anubis PoW policy, `ingress_factory`, homepage + x402 annotations,
Discord + chrome-service env — is unchanged.

## Blast radius

- The `f1-stream` K8s service is the only consumer; no other stack references
  `viktorbarzin/f1-stream` or the `files/` dir (verified: no `path.module` /
  `archive_file` / `null_resource` references the dir).
- Adding `imagePullSecrets` triggers one Recreate rollout that pulls the
  *current* (still-DockerHub, public) image — safe; CI then switches it to the
  Forgejo image.
