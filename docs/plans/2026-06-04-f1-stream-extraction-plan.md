# f1-stream extraction + productionization — plan (2026-06-04)

Companion to `2026-06-04-f1-stream-extraction-design.md`.

## Steps

1. **Scaffold** `/home/wizard/code/f1-stream/` — copy `backend/`, `frontend/`,
   `Dockerfile`, `.dockerignore` from `infra/stacks/f1-stream/files/` by name
   (exclude the `.claude/` marker + `redeploy.sh`); add `README.md`,
   `.gitignore`. ✅
2. **Poetry conversion** — `pyproject.toml` (dist `f1-stream` v2.0.1,
   `packages=[{include="backend"}]`, pinned deps), `poetry.lock`, ruff/mypy/
   pytest config (E501 per-file-ignored on the embedded-JS/scraper modules).
   Rewrite the Dockerfile to a Poetry multi-stage build (Poetry 2.1.3 to match
   the lock; python:3.13; keep Chromium libs + `playwright install chromium`;
   keep `backend/` + `frontend/build/` siblings under `/app`). ✅
3. **Tests** — 63 pytest unit tests over the pure-logic core. ✅
4. **CI** — single `.woodpecker.yml` (lint+test → buildx push to Forgejo →
   `kubectl set image` + rollout). ✅
5. **Create + push** — Forgejo repo `viktor/f1-stream` (private), commit, push
   `master`, tag `v2.0.1`. ✅
6. **Enable in Woodpecker** — activate via
   `scripts/woodpecker-register-forgejo-repo.sh` (Woodpecker repo id 166);
   org-level `forgejo_user`/`forgejo_push_token` secrets apply. ✅
7. **Repoint Terraform** — `main.tf` image → Forgejo + `var.image_tag` +
   `image_pull_secrets`; `tg apply`. ✅
8. **Untrack from infra** — `git rm -r stacks/f1-stream/files`; add
   `/f1-stream/` to the monorepo root `.gitignore`. ✅
9. **Docs** — fix the stale "GHA / repo id 10" claim in `.claude/CLAUDE.md` +
   `docs/architecture/ci-cd.md`; update `service-catalog.md`; this design/plan
   pair. ✅
10. **Verify** — pipeline green; pod runs the Forgejo image; `/health` 200;
    ingress reachable through Anubis.

## Verification commands

```bash
# pipeline
curl -s https://ci.viktorbarzin.me/api/repos/166/pipelines/<n> -H "Authorization: Bearer <jwt>"
# running image is the Forgejo one
kubectl get deploy f1-stream -n f1-stream \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get pods -n f1-stream -l app=f1-stream
# health
kubectl exec -n f1-stream deploy/f1-stream -- \
  python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/health').read())"
```

## Rollback

The DockerHub image `viktorbarzin/f1-stream` and its tags still exist. To
revert: `kubectl -n f1-stream set image deployment/f1-stream
f1-stream=viktorbarzin/f1-stream:<tag>` and restore the `main.tf` image string.
The standalone repo + Forgejo image are additive; nothing is destroyed.
