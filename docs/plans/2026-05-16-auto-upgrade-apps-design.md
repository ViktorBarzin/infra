# Auto-Upgrade Apps Design

**Date**: 2026-05-16
**Status**: Approved (brainstorm + grill complete; implementation pending)

> **UPDATE 2026-06-02 — decision #12 / Q1 reversed for OWNED apps.** The
> original "uniform Keel-only, no per-repo `kubectl set image` step" call held
> only for **upstream** images (which we can't build, so Keel poll-and-bump is
> the only option). For **self-hosted apps we build**, CI now ALSO drives the
> rollout: `build-and-push` tags `latest` + `:<sha>`, then a `deploy` step runs
> `kubectl set image deployment/<app> ...:<sha>` + `rollout status`. Rationale
> (memory id=3183, proven on tuya-bridge 2026-05-29): the pipeline is atomic
> and deterministic — no wait for Keel's hourly poll, no risk of Keel resolving
> `:latest` to a stale concrete tag. **Keel stays enrolled in parallel** as a
> redundant net (it finds the just-deployed SHA already running → no-op), so
> upstream apps and owned apps share one mental model. Enabled cluster-wide by
> the `woodpecker-agent` SA being `cluster-admin` (no per-app RBAC). Owned apps
> being rolled out to this pattern 2026-06-02; CronJobs in owned apps use
> `:latest` + `imagePullPolicy: Always` instead of a deploy step.

## Problem

Three constraints in tension across the cluster's ~70 services:

1. **Keep apps at latest.** Most services drift behind upstream; manual bumps don't scale.
2. **Stay Terraform-compatible.** Image refs live in `.tf`; we want declarative source of truth.
3. **Don't let the pull-through cache serve stale `:latest`.** Cache layer must not lie about what `:latest` means today.

The previous `Diun → n8n → Service Upgrade Agent` flow handled (1) via changelog-reviewed PR bumps for third-party. Self-hosted services have inconsistent CI: 1 of 11 fully wired (CI builds + pushes + rolls out), 6 partially wired (build but no rollout trigger), 4 with no CI at all. Self-hosted services typically pull `forgejo.viktorbarzin.me/viktor/<name>:<8-char-sha>` with Terraform tracking each SHA in `var.image_tag`.

The user wants to simplify by retiring the changelog-review agent and moving to a pure "latest, always" model, with the cache freshness concern handled at the cache layer (already done — see Architecture §1).

## Decisions

| # | Decision | Notes |
|---|----------|-------|
| 1 | **Auto-roll for everything** (no PR-bump gate) | Retires the Service Upgrade Agent; Diun's role narrows to notification only |
| 2 | **Actuator: Keel** ([keel.sh](https://keel.sh)) | Annotation-driven Deployment/StatefulSet/DaemonSet auto-update operator |
| 3 | **Tag scheme: `:latest` where it exists, `:major` where it doesn't, glob+`ignore_changes` last resort** | `keel.sh/policy: force` for `:latest` / `:major`; tag string stays in Terraform |
| 4 | **Opt-out-pure (no skip-list)** | Every workload auto-rolls, including Vault, CNPG, operators, CNI, CSI. User accepts recoverability risk |
| 5 | **Phased rollout (9 phases)** | Low-risk → bootstrap. Catch up to latest as we phase in. Each phase soaks ~1 week |
| 6 | **Per-phase: single combined PR** | Switch image refs to floating tag + add to Kyverno mutate allowlist in same commit |
| 7 | **Diun is the audit source for catch-up** | Existing 6h-poll already reports outdated images; export as worklist per phase |
| 8 | **Polling, hourly** (`@every 1h`) | Not webhooks — single mechanism, all registries supported |
| 9 | **Rollback: `kubectl rollout undo` → pin in Terraform → add `keel.sh/policy: never`** | (c) from grill: immediate undo, durable Terraform pin within ≤1h before next Keel poll |
| 10 | **Implementation: Kyverno cluster-wide mutate** | One `ClusterPolicy` injects Keel annotations; phase boundary = `NamespaceSelector` allowlist |
| 11 | **Keel exempt from its own mutate** | One-line `NamespaceSelector` exclusion. Supervisor self-update has uniquely bad failure mode |
| 12 | **Uniform CI model for all self-hosted** | CI builds + pushes `:latest`, Keel polls and rolls. No per-repo `kubectl set image` step. Retires the GHA-migrated SHA-tag flow (memory id=388) |

## Architecture

### 1. Cache freshness — already correct

Pull-through cache at `10.0.20.10` already splits caching by URL at the nginx layer:

- `location ~ /v2/.*/blobs/` → `proxy_cache_valid 200 24h` — blobs cached (content-addressed, immutable)
- `location /v2/` (manifests) → pass through, no cache

Combined with `registry.proxy.ttl: 0` at the docker-registry layer, mutable manifests revalidate against upstream on every pull. **No cache changes needed for this design.** The CLAUDE.md note "Use 8-char git SHA tags — `:latest` causes stale pull-through cache" predates the nginx URL-split fix and should be updated as part of this work.

### 2. Detection — Keel polls upstream

Keel runs as a Deployment in its own namespace. Every annotated workload polls its registry hourly (Keel-managed; configurable per workload). On detection of a new digest under the watched tag:

- `keel.sh/policy: force` (for mutable tags `:latest`, `:16`, `:7`, etc.) → trigger Deployment update (pod template hash changes → restart)
- `keel.sh/policy: minor` / `major` / `glob` (only for images that publish neither `:latest` nor a stable floating tag) → rewrite tag string on the Deployment; requires `lifecycle { ignore_changes = [...image] }`

### 3. Application — kubelet pull through the cache

When Keel triggers restart:

1. kubelet asks the cache (via containerd hosts.toml) for `image:tag` manifest.
2. nginx passes the manifest request through to the docker-registry layer.
3. docker-registry (with `proxy.ttl: 0`) passes through to upstream.
4. Upstream returns current digest.
5. kubelet pulls blobs (mostly cached at nginx layer; new blobs from upstream).
6. New pod runs new image.

### 4. Annotation injection — Kyverno mutate

Single `ClusterPolicy` adds these annotations to every Deployment / StatefulSet / DaemonSet in opted-in namespaces:

```yaml
metadata:
  annotations:
    keel.sh/policy: force
    keel.sh/trigger: poll
    keel.sh/pollSchedule: "@every 1h"
```

Phase = a `match.any[].resources.namespaces` list. Phase advance = append namespaces. Keel namespace is excluded.

### 5. Terraform drift handling

Existing convention (`# KYVERNO_LIFECYCLE_V1` marker) handles `dns_config` injection. We extend with a new marker:

```hcl
lifecycle {
  ignore_changes = [
    spec[0].template[0].spec[0].dns_config,  # KYVERNO_LIFECYCLE_V1
    metadata[0].annotations["keel.sh/policy"],
    metadata[0].annotations["keel.sh/trigger"],
    metadata[0].annotations["keel.sh/pollSchedule"],  # KYVERNO_LIFECYCLE_V2
  ]
}
```

This is added per workload as we phase in. Mechanical, grep-able.

## Phase ordering

| Phase | Set | Rationale |
|-------|-----|-----------|
| 0 | Foundation (Keel install, Kyverno ClusterPolicy with empty allowlist) | Build infra without enrolling anything |
| 1 | Self-hosted (forgejo-hosted: ~11 services) | We own the code; failures are easy to diagnose |
| 2 | Stateless third-party web apps (linkwarden, postiz, affine, etc.) | No migrations |
| 3 | Exporters, sidecars, utilities | Stateless |
| 4 | Stateful-but-tolerant (Grafana, Prometheus, etc.) | Restart-safe state |
| 5 | State-coupled with migrations (Nextcloud, Forgejo, paperless-ngx, mailserver) | Schema-migration risk. **Nextcloud enrolled 2026-06-01** with two safeguards for the migration risk: F1 — `nextcloud-watchdog` CronJob runs `occ upgrade` when occ reports `needsDbUpgrade=true` (recovers an interrupted entrypoint upgrade); F2 — `chart_values.yaml` renders the live (Keel-bumped) image tag with a floor, so a helm re-render never downgrades below live. Scope is `patch` (Kyverno-stamped) == `minor` for Nextcloud (32.0.x only). See `stacks/nextcloud/main.tf`. |
| 6 | Authentik | Auth outage |
| 7 | Operators (cnpg-operator, ESO, kured, descheduler) | Operator skew |
| 8 | Critical infra (Calico, proxmox-csi, nfs-csi, traefik, metallb) | Node-level outage potential (memory id=390: 26h Calico cascade) |
| 9 | Bootstrap (Vault, CNPG PG cluster, mysql-standalone) | Lose recoverability if broken |

Per-phase: combined PR → apply (catch-up rolls happen) → soak 1 week → next phase. If a service breaks repeatedly, apply rollback runbook (decision #9) and proceed; re-enroll later or leave pinned.

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Bad upstream image rolls into prod | High | Service-level outage | Existing alerts (`KubePodCrashLooping`, `KubeletImagePullErrors`, `PodsStuckContainerCreating`); rollback runbook (decision #9) |
| Catch-up rollout overwhelms cache | Medium | ImagePullBackOff cascade (memory id=603) | Rate-limit catch-up to ~5 rollouts/6h via `-target=` per phase; same pacing as retired Service Upgrade Agent (memory id=612) |
| Calico / CSI auto-roll cascades (memory id=390: 26h outage) | Low-Medium | Cluster-level outage | Phase 8 is intentionally late; user opted into the risk; rollback to pinned chart version via Terraform |
| Vault auto-rolls to broken image | Low | Loss of secrets sync; 43 ExternalSecrets stop reconciling | Phase 9 last; Tier 0 SOPS state allows manual recovery |
| CNPG PG cluster auto-rolls to broken image | Low | Tier 1 Terraform state inaccessible; 105 stacks can't apply | Phase 9 last; Tier 0 stack `cnpg` is bootstrap-capable |
| Helm-atomic-trap services (memory id=981) | Medium | `terraform apply` hangs in pending-rollback | Identify `helm_release` services with `atomic = true`; either remove atomic or skip from Keel |
| Keel itself rolls to broken version | Low | Supervisor down; no auto-rolls until manual pin | Decision #11: exempt Keel from mutate |
| Terraform drift after Kyverno injects annotation | High at first | Spurious diffs on every plan | KYVERNO_LIFECYCLE_V2 marker (Architecture §5); applied incrementally per phase |

## What we give up

- **Terraform no longer tracks deployed version.** Image refs in `.tf` say `:latest` or `:16`, but the running digest is whatever Keel pulled. To know what's running: `kubectl describe pod`. This is a deliberate trade — the previous SHA-pinned flow tracked version in TF but required N stack edits per deploy.
- **No changelog review before rollout.** The Service Upgrade Agent's risk classification is gone. We rely on alerts to catch breakage post-deploy, not prevent it.
- **CLAUDE.md SHA-tag rule is reversed for this design.** The "use 8-char git SHA tags" rule predates the nginx URL-split fix. New rule (post-rollout): "use floating tags + Keel annotation" — to be updated in both `infra/.claude/CLAUDE.md` and the repo-root `CLAUDE.md` once Phase 1 is stable.

## Decisions resolved post-grill

### Q1 — Uniform CI model for ALL self-hosted (resolved 2026-05-16)

Every self-hosted service moves to the same shape:

```
CI (GHA or Woodpecker) → build → push :latest (optionally also :<SHA> for traceability) → done
Keel → poll registry → detect new digest → trigger rollout
```

The 10 GHA-migrated repos (memory id=388: Website, k8s-portal, f1-stream, claude-memory-mcp, apple-health-data, audiblez-web, plotting-book, insta2spotify, audiobook-search, council-complaints) drop the `Woodpecker API → kubectl set image` step. Their `.woodpecker/deploy.yml` and `.woodpecker/build-fallback.yml` files become obsolete; remove during Phase 1.

Terraform image refs for all self-hosted: `<registry>/<repo>:latest` (with `${var.image_tag}` defaulting to `"latest"` where the variable exists).

### Q2 — No-CI self-hosted services (resolution: uniform participation)

| Service | Action |
|---------|--------|
| `wealthfolio` | Switch Terraform to upstream `wealthfolio/wealthfolio:latest` (DockerHub). No CI needed. |
| `chrome-service` | Verify whether `:v4` is a deliberate pin. If yes → tag stays, add `keel.sh/policy: never` label. If no → switch to `:latest` or `:major`. Investigate during Phase 1 prep. |
| `beadboard` (used by `beads-server`) | Add minimal Woodpecker CI: build on push → push `:latest`. User-owned. |
| `freedify` | Add minimal Woodpecker CI: build on push → push `:latest`. User-owned. |

## Open questions (still need resolution before Phase 1)

1. **`helm_release atomic = true` services**: count and identify before Phase 1. Either remove `atomic` (preferred — eliminates the memory id=981 trap), or skip from Kyverno mutate via per-namespace exclusion. Survey command: `grep -rn 'atomic.*true' infra/stacks/ infra/modules/`.

## Out of scope

- Cache TTL changes — current config is already correct (nginx URL-split).
- Webhook-based Keel triggers — polling is sufficient for this cadence.
- Replacing Diun — kept for notification visibility into new tags not yet under Keel annotation (during phase rollout).
- Keel approval gate (`keel.sh/approvals: N`) — user wants unattended auto-roll.
- Keel auto-rollback on health-check failure — out of scope for v1; revisit if breakage rate is high.
