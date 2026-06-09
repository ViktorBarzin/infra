# Forgejo Registry Consolidation — Plan

**Date**: 2026-05-07
**Status**: Approved — execution in progress (Phase 0)
**Design**: `2026-05-07-forgejo-registry-consolidation-design.md`

This is the implementation roadmap for migrating off `registry-private`
onto Forgejo's OCI registry. See the design doc for problem
statement and rationale. Execution spans 5 phases over ≥3 weeks.

## Phase 0 — Prepare Forgejo (1 PR, no cutover risk)

| Task | File / artifact |
|---|---|
| Bump Forgejo memory request+limit 384Mi → 1Gi | `infra/stacks/forgejo/main.tf` |
| Add `FORGEJO__packages__ENABLED=true` and `FORGEJO__packages__CHUNKED_UPLOAD_PATH=/data/tmp/package-upload` env vars (defensive — already default in v11) | `infra/stacks/forgejo/main.tf` |
| Bump Forgejo PVC 5Gi → 15Gi, auto-resize cap 20Gi → 50Gi | `infra/stacks/forgejo/main.tf` |
| Bump ingress `max_body_size = "5g"` (wired into ingress_factory as a Buffering middleware) | `infra/stacks/forgejo/main.tf`, `infra/modules/kubernetes/ingress_factory/main.tf` |
| Create `cluster-puller` (read:package), `ci-pusher` (write:package), and a third `cleanup` PAT on `ci-pusher`; store PATs in Vault | runbook: `docs/runbooks/forgejo-registry-setup.md` |
| Extend `registry-credentials` Secret with 4th `auths` entry for `forgejo.viktorbarzin.me` | `infra/stacks/kyverno/modules/kyverno/registry-credentials.tf` |
| Add containerd `hosts.toml` entry redirecting `forgejo.viktorbarzin.me` → in-cluster Traefik LB `10.0.20.200` | `infra/stacks/infra/main.tf` cloud-init + new `infra/scripts/setup-forgejo-containerd-mirror.sh` for existing nodes |
| Forgejo retention CronJob (`0 4 * * *`, dry-run for first 7 days) | new `infra/stacks/forgejo/cleanup.tf` + `infra/stacks/forgejo/files/cleanup.sh` |
| Forgejo integrity probe CronJob (`*/15 * * * *`) | `infra/stacks/monitoring/modules/monitoring/main.tf` |
| Make existing alerts instance-aware so they cover both registries | `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` |

**Smoke test (must pass before declaring Phase 0 done):**

- `docker login forgejo.viktorbarzin.me` succeeds.
- Push a hello-world image to `forgejo.viktorbarzin.me/viktor/smoketest:1` succeeds.
- `crictl pull forgejo.viktorbarzin.me/viktor/smoketest:1` from a k8s
  node succeeds, using the auto-synced `registry-credentials` Secret.
- A fresh namespace gets the cloned Secret with 4 `auths` entries.
- Delete the smoketest package via API.
- Forgejo integrity probe completes once and pushes metrics.

## Phase 1 — Source migration (parallel-safe, no production impact)

For each project the recipe is identical:

1. `git init` + push to `forgejo.viktorbarzin.me/viktor/<name>` —
   register in Woodpecker via OAuth.
2. Add `.woodpecker.yml` based on `payslip-ingest/.woodpecker.yml`.
   Push step uses `woodpeckerci/plugin-docker-buildx` with TWO
   `repo:` entries (dual-push).
3. Confirm first build pushes to BOTH registries.

Projects (bake clock starts at "all dual-push"):

| Project | Action |
|---|---|
| `claude-agent-service` | Extract from monorepo to Forgejo. New `.woodpecker.yml`. |
| `fire-planner` | Extract from monorepo to Forgejo. New `.woodpecker.yml`. |
| `wealthfolio-sync` | Extract from monorepo to Forgejo. New `.woodpecker.yml`. |
| `hmrc-sync` | Extract from monorepo to Forgejo. New `.woodpecker.yml`. |
| `freedify` | Push from monorepo to Forgejo. New `.woodpecker.yml`. (Upstream is gone.) |
| `payslip-ingest` | Already on Forgejo. Add second `repo:` entry to `.woodpecker.yml`. |
| `job-hunter` | Already on Forgejo. Add second `repo:` entry. |
| `beadboard` | Push to Forgejo. New `.woodpecker.yml`. Disable GHA workflow. **Don't archive GitHub yet** (deferred to Phase 3). |
| `claude-memory-mcp` | Push to Forgejo. New `.woodpecker.yml`. |
| `infra-ci` | Edit `.woodpecker/build-ci-image.yml` to dual-push. ALSO `docker save | gzip` to `/opt/registry/data/private/_breakglass/` on VM AND `/srv/nfs/forgejo-breakglass/` on NAS. Pin a `latest` symlink. |

Break-glass runbook (`docs/runbooks/forgejo-registry-breakglass.md`)
documents the recovery path.

## Phase 2 — Bake (≥14 days)

- No `image=` lines change. Pods still pull from
  `registry.viktorbarzin.me`.
- **Daily smoke check**: pull a recent image from Forgejo as
  `cluster-puller`, verify integrity (HEAD on manifest + each blob).
- **Bake exit criteria**:
  - Zero `RegistryManifestIntegrityFailure` alerts on Forgejo.
  - Zero `ContainerNearOOM` for the forgejo pod.
  - Retention CronJob has run ≥14 times successfully.
  - At least one full Sunday GC cycle has elapsed.
  - Switch retention CronJob to `DRY_RUN=false` on day 7, observe
    until day 14.

## Phase 3 — Cutover (one PR per project, single session)

Order = lowest blast radius first. Each step:
`image=` flip → `kubectl rollout restart` → verify pull from Forgejo.

1. `payslip-ingest` (`infra/stacks/payslip-ingest/main.tf`)
2. `job-hunter` (`infra/stacks/job-hunter/main.tf`)
3. `claude-agent-service` (`infra/stacks/claude-agent-service/main.tf`)
4. `fire-planner` (`infra/stacks/fire-planner/main.tf`)
5. `wealthfolio-sync` (`infra/stacks/wealthfolio/main.tf`)
6. `freedify` (`infra/stacks/freedify/factory/main.tf`)
7. `chrome-service` (`infra/stacks/chrome-service/main.tf`)
8. `beads-server` / `beadboard` (`infra/stacks/beads-server/main.tf`).
   Then `gh repo archive ViktorBarzin/beadboard`.
9. `infra-ci` — flip `image:` references in 4 `.woodpecker/*.yml`
   files in the infra repo. Verify next push to master applies cleanly.
10. `claude-memory-mcp` — update `CLAUDE.md` install instruction from
    `claude plugins install github:ViktorBarzin/claude-memory-mcp` to
    `claude plugins install https://forgejo.viktorbarzin.me/viktor/claude-memory-mcp.git`.
    `gh repo archive ViktorBarzin/claude-memory-mcp`.

## Phase 4 — Decommission

| Step | File / location |
|---|---|
| Stop `registry-private` container on VM (10.0.20.10): edit `/opt/registry/docker-compose.yml`, comment out service, `docker compose up -d --remove-orphans`. (Manual SSH — cloud-init won't redeploy on TF apply per memory id=1078.) | live VM |
| Update cloud-init template to match the new compose file | `infra/stacks/infra/main.tf:288` |
| Delete `auths` entries for `registry.viktorbarzin.me` / `:5050` / `10.0.20.10:5050` from the dockerconfigjson | `infra/stacks/kyverno/modules/kyverno/registry-credentials.tf` |
| Drop `registry.viktorbarzin.me` and `10.0.20.10:5050` `hosts.toml` entries on each node + cloud-init template | `infra/stacks/infra/main.tf` cloud-init + ad-hoc script |
| After 1 week of no incidents, delete `/opt/registry/data/private/` blob storage on the VM (~2.6GB freed) | manual SSH |

## Phase 5 — Docs

In the same commit as the Phase 4 closing:

| Doc | Update |
|---|---|
| `docs/runbooks/registry-vm.md` | Note `registry-private` is gone; pull-through caches and break-glass tarballs only |
| `docs/runbooks/registry-rebuild-image.md` | Replaced by NEW `forgejo-registry-rebuild-image.md` |
| `docs/runbooks/forgejo-registry-rebuild-image.md` (NEW) | Forgejo PVC restore procedure |
| `docs/runbooks/forgejo-registry-breakglass.md` (NEW) | infra-ci tarball recovery |
| `docs/architecture/ci-cd.md` | Image registry section flips to Forgejo |
| `docs/architecture/monitoring.md` | Integrity probe target updated |
| `infra/.claude/CLAUDE.md` | Registry references updated |
| `CLAUDE.md` (monorepo root) | claude-memory-mcp install URL updated |
| `infra/.claude/reference/service-catalog.md` | Cross-reference checked |

## Critical files modified

| File | Phase | What |
|---|---|---|
| `infra/stacks/forgejo/main.tf` | 0 | Memory bump, packages env vars, PVC bump, ingress max_body_size |
| `infra/stacks/forgejo/cleanup.tf` (NEW) | 0 | Retention CronJob |
| `infra/stacks/forgejo/files/cleanup.sh` (NEW) | 0 | Retention script (mounted via ConfigMap) |
| `infra/modules/kubernetes/ingress_factory/main.tf` | 0 | Wire `max_body_size` into a Traefik Buffering middleware |
| `infra/stacks/kyverno/modules/kyverno/registry-credentials.tf` | 0 | Add 4th `auths` entry |
| `infra/stacks/infra/main.tf` | 0 + 4 | Containerd hosts.toml block (add Forgejo, later remove registry-private); compose template update |
| `infra/scripts/setup-forgejo-containerd-mirror.sh` (NEW) | 0 | One-shot rollout for existing nodes |
| `infra/stacks/monitoring/modules/monitoring/main.tf` | 0 | Forgejo integrity probe CronJob |
| `infra/stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` | 0 | Make alerts instance-aware |
| `infra/stacks/monitoring/main.tf` | 0 | Plumb `forgejo_pull_token` into module |
| `infra/.woodpecker/build-ci-image.yml` | 1 | Dual-push to add Forgejo target + tarball break-glass |
| `<each-project>/.woodpecker.yml` | 1 | Dual-push (NEW for fire-planner, wealthfolio-sync, hmrc-sync, freedify, beadboard, claude-memory-mcp; EDIT for payslip-ingest, job-hunter, claude-agent-service) |
| `infra/.woodpecker/{default,drift-detection,build-cli}.yml` | 3 | Flip `image:` to Forgejo for infra-ci |
| `infra/stacks/{beads-server,chrome-service,claude-agent-service,fire-planner,freedify/factory,job-hunter,payslip-ingest,wealthfolio}/main.tf` | 3 | Flip `image =` to Forgejo |

## Verification

- **Push** (Phase 0/1): `docker push forgejo.viktorbarzin.me/viktor/<name>` visible in Forgejo Web UI under viktor/.
- **Pull** (Phase 0): `crictl pull forgejo.viktorbarzin.me/viktor/smoketest:1` succeeds with auto-synced Secret.
- **Dual-push** (Phase 1): every Woodpecker pipeline run pushes to BOTH endpoints — confirmed via HEAD checks on `<reg>:<sha>` for both.
- **Bake** (Phase 2): existing daily Forgejo `/api/healthz` external monitor stays green; integrity probe stays green; no `ContainerNearOOM` for forgejo pod.
- **Cutover** (Phase 3): `kubectl rollout status deploy/<svc> -n <ns>` succeeds. `kubectl describe pod` shows the image was pulled from `forgejo.viktorbarzin.me`.
- **Decommission** (Phase 4): `docker ps` on registry VM no longer shows `registry-private`. Brand-new namespace gets the Secret with only the Forgejo `auths` entry. Pull still works.
