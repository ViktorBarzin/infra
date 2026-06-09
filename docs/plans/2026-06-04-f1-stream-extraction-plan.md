# f1-stream extraction + productionization — plan (2026-06-04)

Companion to `2026-06-04-f1-stream-extraction-design.md`.

## Steps

1. Scaffold `/home/wizard/code/f1-stream/` from `infra/stacks/f1-stream/files/`
   (backend/, frontend/, Dockerfile by name; add README, .gitignore). ✅
2. Poetry conversion (pyproject v2.0.1, `packages=[{include="backend"}]`, lock,
   ruff/mypy/pytest config; E501 per-file-ignored on the JS/scraper modules). ✅
3. 63 pytest unit tests over the pure-logic core; ruff + mypy clean. ✅
4. Dockerfile: Poetry multi-stage, **no bundled Chromium** (CDP-only). ✅
5. `.woodpecker.yml`: lint+test → buildx push to Forgejo → kubectl set image. ✅
6. Create Forgejo repo `viktor/f1-stream` (private), push `master`, tag
   `v2.0.1`. ✅
7. Build + push the image to the Forgejo registry (manual from devvm, since the
   Woodpecker repo's config-fetch user is broken):
   `forgejo.viktorbarzin.me/viktor/f1-stream:24857a82` + `:latest`. ✅
8. Repoint `stacks/f1-stream/main.tf` (Forgejo image + `var.image_tag` +
   `image_pull_secrets`); `tg apply`. ✅
9. `kubectl set image deployment/f1-stream f1-stream=…:24857a82` + rollout. ▶
10. Remove `stacks/f1-stream/files/`; add `/f1-stream/` to the monorepo root
    `.gitignore`. ✅ (infra side)
11. Verify: pod on the Forgejo image, `/health` 200, ingress through Anubis. ▶

## Follow-ups (need Viktor / coordination)

- **Re-enable `viktor/f1-stream` in the Woodpecker UI** (proper OAuth) so CI
  builds run on push (the API-registered repo has a broken config-fetch user).
- **Land this infra commit on `forgejo/master`** (CI-canonical) once the
  origin↔forgejo divergence is reconciled, so a future `forgejo` apply doesn't
  revert `imagePullSecrets`.

## Rollback

DockerHub `viktorbarzin/f1-stream` tags still exist:
`kubectl -n f1-stream set image deployment/f1-stream
f1-stream=viktorbarzin/f1-stream:06276544` + restore the `main.tf` image
string. The standalone repo + Forgejo image are additive.
