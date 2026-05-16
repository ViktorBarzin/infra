# Auto-Upgrade Apps Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the cluster from a mix of pinned-SHA / pinned-semver / ad-hoc `:latest` references to a Keel-driven auto-update model where every workload tracks `:latest` (or a chosen `:major` floating tag) and rolls automatically when upstream advances.

**Architecture:** Kyverno cluster-wide `ClusterPolicy` mutates Deployments / StatefulSets / DaemonSets in opted-in namespaces with Keel annotations (`keel.sh/policy: force`, `keel.sh/trigger: poll`, `keel.sh/pollSchedule: @every 1h`). Keel polls registries, triggers rollout on new digest. kubelet pulls fresh manifest via the nginx URL-split cache (manifests passthrough, blobs cached). Phase advance = expand the `NamespaceSelector` allowlist.

**Tech Stack:** Keel, Kyverno, Terraform / Terragrunt, Helm, Diun (notification only), nginx, docker/distribution

**Design doc:** `docs/plans/2026-05-16-auto-upgrade-apps-design.md`

**Key context:**
- Cache is already correctly configured (nginx URL-split + `proxy.ttl: 0`). No cache changes needed.
- Per-stack `lifecycle.ignore_changes` is already required for the existing `dns_config` Kyverno mutation (KYVERNO_LIFECYCLE_V1 convention). This plan extends it with a V2 marker for Keel annotations.
- Service Upgrade Agent (Diun → n8n → claude bumps tfvars) is retired by this design. n8n workflow + supporting scripts are removed once Phase 9 completes.
- CLAUDE.md "use 8-char git SHA tags" rule is reversed by this design (see Open Q1 in design doc).

---

## Phase 0 — Foundation

### Task 0.1: Resolve remaining open question

Q1 and Q2 from the design doc are resolved (uniform `:latest` + Keel model for all self-hosted; per-service plan for no-CI services).

Remaining open question:

**Helm-atomic services.** Survey:
```bash
grep -rn 'atomic.*true' /home/wizard/code/infra/stacks/ /home/wizard/code/infra/modules/
```

For each match: either remove `atomic = true` (preferred) or add the namespace to a Kyverno exclusion list. Document inline before Phase 1 proceeds.

---

### Task 0.2: Create the Keel stack

**Files:**
- Create: `stacks/keel/terragrunt.hcl`
- Create: `stacks/keel/main.tf`
- Create: `stacks/keel/variables.tf`
- Create: `stacks/keel/modules/keel/main.tf`

**Step 1:** Add `keel` to `terragrunt.hcl` `locals.tier0_stacks` — **NO**. Keel is Tier 1 (depends on Kyverno + Keel image registry access). Keep it in Tier 1.

**Step 2:** Deploy via Helm chart `keel-hq/keel` (verify current version via context7 before pinning).

Key Helm values:
- `polling.enabled: true`
- `helmProvider.enabled: false` (we use annotations, not Helm hooks)
- `notifications.slack.enabled: true` with channel `#deployments` (verify channel exists)
- Registry credentials: mount Forgejo PAT from Vault via ExternalSecret (`secret/viktor/forgejo_pull_token`).

**Step 3:** Verify Keel can authenticate to all five registries (Docker Hub, ghcr, quay, k8s.io, kyverno via the local cache; Forgejo direct).

**Acceptance:**
- `kubectl -n keel get pod` shows Keel Ready.
- `kubectl -n keel logs deploy/keel | grep registry` shows successful manifest queries.

---

### Task 0.3: Author the Kyverno ClusterPolicy

**Files:**
- Create: `stacks/kyverno/modules/kyverno/keel-annotations.tf` (or extend `security-policies.tf`)

ClusterPolicy `inject-keel-annotations`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-keel-annotations
spec:
  background: true
  rules:
    - name: add-keel-annotation
      match:
        any:
          - resources:
              kinds: [Deployment, StatefulSet, DaemonSet]
              namespaces: []  # populated per phase
      exclude:
        any:
          - resources:
              namespaces: ["keel"]  # decision #11
          - resources:
              # Workloads can opt out by setting this label
              selector:
                matchLabels:
                  keel.sh/policy: never
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              +(keel.sh/policy): force
              +(keel.sh/trigger): poll
              +(keel.sh/pollSchedule): "@every 1h"
```

- `+()` syntax adds only if not present (preserves per-workload overrides).
- `exclude.selector.matchLabels[keel.sh/policy=never]` is the per-workload escape hatch (used during rollback per decision #9).

**Step 2:** Initially deploy with `namespaces: []` — policy exists but matches nothing.

**Acceptance:**
- `kubectl get clusterpolicy inject-keel-annotations` shows Ready.
- `kubectl get deploy -A -o yaml | grep keel.sh/policy` shows no matches yet (empty allowlist).

---

### Task 0.4: Define the KYVERNO_LIFECYCLE_V2 marker convention

**Files:**
- Modify: `AGENTS.md` — add the V2 snippet to the "Kyverno Drift Suppression" section
- Modify: `.claude/CLAUDE.md` — reference the V2 marker

Snippet to copy-paste:

```hcl
lifecycle {
  ignore_changes = [
    spec[0].template[0].spec[0].dns_config,            # KYVERNO_LIFECYCLE_V1
    metadata[0].annotations["keel.sh/policy"],
    metadata[0].annotations["keel.sh/trigger"],
    metadata[0].annotations["keel.sh/pollSchedule"],   # KYVERNO_LIFECYCLE_V2
  ]
}
```

Backfill order: per-phase, only on workloads about to be enrolled. Not a mass sweep.

---

## Phase 1 — Self-hosted (uniform model)

**Set:** all self-hosted services. Three sub-categories:

- **Woodpecker-build-only (6):** `claude-agent-service`, `fire-planner`, `job-hunter`, `payslip-ingest`, `recruiter-responder`, `claude-memory-mcp`.
- **GHA-migrated (10, per memory id=388):** Website, k8s-portal, f1-stream, claude-memory-mcp, apple-health-data, audiblez-web, plotting-book, insta2spotify, audiobook-search, council-complaints. (Note: claude-memory-mcp appears in both lists — verify.)
- **No-CI (4, per design Q2):** `wealthfolio` (→ upstream), `chrome-service` (verify pin intent), `beadboard` (add CI), `freedify` (add CI).
- **Already-uniform (1):** `kms-website` — already pushes `:latest` AND SHA; just needs Keel annotation.

### Task 1.1: Audit current image refs

```bash
grep -rE 'image\s*=\s*"(forgejo\.viktorbarzin\.me|viktorbarzin)' /home/wizard/code/infra/stacks/ | sort
```

Tabulate per service: current tag, CI type (GHA / Woodpecker / none), action needed.

### Task 1.2: Per-service uniform conversion

For each Woodpecker-build-only service:
1. Edit Terraform: `local.image_tag` / `var.image_tag` → `"latest"`.
2. Add the KYVERNO_LIFECYCLE_V2 snippet (annotations ignore_changes).
3. Verify `.woodpecker.yml` pushes `:latest` on every build (most do via `auto_tag: true`).

For each GHA-migrated service:
1. Edit Terraform: switch `image_tag` from SHA reference to `"latest"`.
2. Add the KYVERNO_LIFECYCLE_V2 snippet.
3. Edit `.github/workflows/build-and-deploy.yml`: push `:latest` (in addition to `:<8-char-sha>` for traceability). Remove the Woodpecker API POST step.
4. Delete `.woodpecker/deploy.yml` and `.woodpecker/build-fallback.yml` from each repo (no longer needed).
5. Remove the Woodpecker repo config for these repos from Terraform if applicable.

For each no-CI service:
- `wealthfolio`: change Terraform image to `wealthfolio/wealthfolio:latest` (upstream DockerHub). Validate the image starts cleanly.
- `chrome-service`: check git blame on the `:v4` pin. If deliberate → label `keel.sh/policy: never`. If accidental → bump to upstream `:latest`.
- `beadboard`, `freedify`: write a minimal `.woodpecker.yml` (single build step pushing to Forgejo `:latest`). Trigger an initial build to populate `:latest`.

For `kms-website`: only add the Keel annotation; CI changes optional.

### Task 1.3: Add Phase 1 namespaces to Kyverno allowlist

Edit `stacks/kyverno/modules/kyverno/keel-annotations.tf`:

```yaml
namespaces:
  - claude-agent-service
  - fire-planner
  - job-hunter
  - payslip-ingest
  - recruiter-responder
  - claude-memory-mcp
  - kms-website
  # GHA-migrated set:
  - website  # or whatever the namespace is named per repo
  - k8s-portal
  - f1-stream
  - apple-health-data
  - audiblez-web
  - plotting-book
  - insta2spotify
  - audiobook-search
  - council-complaints
  # No-CI set:
  - beads-server
  - chrome-service
  - freedify
  - wealthfolio
```

Verify each namespace name from `kubectl get ns` before locking in (some may differ from the repo name).

Apply. Watch `kubectl get deploy -n <ns> -o yaml | grep keel.sh` confirm annotations injected. Watch Keel logs for first poll cycle picking up the workloads.

### Task 1.4: Soak

1 week. Monitor:
- Slack `#deployments` for Keel rollout notifications.
- `KubePodCrashLooping` alerts.
- Manual `kubectl rollout status` on each service after a Keel-triggered rollout.

If any service breaks repeatedly: apply rollback runbook (decision #9), record the service in a "pin list" with reason, proceed.

**Acceptance:**
- All 7 services running latest digests within 24h of Phase 1 apply.
- No CrashLooping persisting >1h.
- No more than 2 services pinned-out during the soak week.

---

## Phase 2 — Stateless third-party web apps

**Set:** linkwarden, postiz, affine, isponsorblocktv, audiobookshelf, freshrss, tandoor, immich (verify it qualifies — has external DB so app-restart is safe), excalidraw, hackmd, send, jsoncrack, sparkyfitness, etc. (~15-20 services — full list from `kubectl get deploy -A` filtered against the phase-1 set + skip-bucket).

### Task 2.1: Audit current tags via Diun

```bash
# Diun's REST API or UI exports a "new tags available" report
# Use as the per-service decision source
```

For each service, pick floating tag:
- `:latest` if upstream publishes it and it's stable.
- `:<major>` (e.g. `:2`, `:v3`) if `:latest` is unreliable.
- `glob` + `ignore_changes` as last resort.

### Task 2.2: Catch-up PR

Single combined PR:
- Per-stack: switch image tag from pinned semver to chosen floating tag (Diun-informed).
- Per-stack: add KYVERNO_LIFECYCLE_V2 snippet.
- Append Phase 2 namespaces to Kyverno allowlist.

Apply with `-target=` per stack to pace rollouts (≤5 per hour to avoid cache burst — memory id=603).

### Task 2.3: Soak — 1 week, same monitoring as Phase 1.

---

## Phases 3–9 — same template

For each phase, repeat:

1. Define the set (precise namespace list).
2. Audit current tags (Diun + grep).
3. Pick floating tag per service.
4. Combined PR: image-ref change + lifecycle snippet + Kyverno allowlist update.
5. Apply paced (≤5/hr).
6. Soak 1 week. Pin-out any service that breaks repeatedly.

Set definitions per phase: see design doc Phase Ordering table.

**Special-handling phases:**

- **Phase 7 (Operators).** Restart of an operator can confuse its managed CRD reconciles. Use `imagePullPolicy: Always` + readiness check before declaring stable. Investigate cnpg-operator and ESO restart behavior in advance.
- **Phase 8 (Critical infra).** Calico/CSI DaemonSet rollouts impact each node briefly. Verify `updateStrategy.rollingUpdate.maxUnavailable: 1` on every DaemonSet before enrollment. Memory id=390 (26h Calico-cascade outage) is the cautionary tale.
- **Phase 9 (Bootstrap).** Vault, CNPG, mysql-standalone. Coordinate with backup window. Take a fresh snapshot of `/srv/nfs/<db>-backup/` before applying the phase enrollment.

---

## Cleanup tasks (after Phase 9 stable)

### Task C.1: Retire Service Upgrade Agent

**Files:**
- Modify: `stacks/n8n/` — remove the Service Upgrade Agent workflow
- Delete: any supporting scripts (`infra/scripts/service-upgrade-*.sh` if they exist)
- Modify: `stacks/diun/` — disable webhook notification to n8n (keep Slack notification for visibility)

### Task C.2: Update CLAUDE.md files

- Reverse the "use 8-char git SHA tags" rule in `infra/.claude/CLAUDE.md` "Docker images" line.
- Reverse same in root `/CLAUDE.md` if duplicated.
- Add a new section documenting the Keel model + KYVERNO_LIFECYCLE_V2 snippet.
- Update memory via `mcp__claude_memory__memory_update` on entries 388, 612, 604 (CI/CD architecture, Service Upgrade Agent retirement, cache TTL clarification).

### Task C.3: Add a runbook

**Files:**
- Create: `docs/runbooks/keel-rollback.md`

Document the rollback flow (decision #9): `kubectl rollout undo` → Terraform pin → annotation `keel.sh/policy: never`.

### Task C.4: Tidy Diun

Drop image-pin overrides for MySQL, PostgreSQL, Redis from Diun config (no longer needed since they're Keel-managed; the previous skip was for the retired changelog-agent path).

---

## Rollback (whole project)

If the auto-roll experiment goes badly cluster-wide (multiple cascading failures, repeated outages), revert:

1. Set Kyverno ClusterPolicy `inject-keel-annotations` to empty `namespaces: []`.
2. Existing annotations remain on workloads, but Keel continues to act on them — so also disable Keel: scale `keel` Deployment to 0.
3. Pin every workload's Terraform image_tag back to its current running digest (use `kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.template.spec.containers[0].image}{"\n"}{end}'`).
4. Document failure modes in `post-mortems/2026-XX-XX-keel-rollback.md`.
5. Reconsider opt-in approach for next iteration.

---

## Success criteria

- All ~70 services running latest within 8 weeks of Phase 0 completion.
- Zero unrolled-back outages caused by Keel.
- ≤5 services on the "pin list" (i.e. ≥93% auto-roll success rate).
- `terragrunt plan` shows no spurious diffs from Kyverno-injected annotations (KYVERNO_LIFECYCLE_V2 working as intended).
- Service Upgrade Agent + supporting infra retired.
