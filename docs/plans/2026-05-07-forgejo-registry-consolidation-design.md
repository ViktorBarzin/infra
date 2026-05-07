# Forgejo Registry Consolidation — Design

**Date**: 2026-05-07
**Status**: Approved

## Problem

`registry-private` (the `registry:2` container on the docker-registry
VM at `10.0.20.10`) has hit `distribution#3324` corruption three
times in three weeks (2026-04-13, 2026-04-19, 2026-05-04). Each
incident required manual blob recovery and another round of
hardening to `cleanup-tags.sh` and the GC procedure. The integrity
probe catches it within 15 minutes now, but every hit still costs
~1h of cleanup, and we keep tightening the same loose screw.

Root cause is a known race in `distribution`: tag deletes that race
with concurrent garbage collection produce orphan OCI-index children.
Upstream has not patched it; our mitigations (probe, blob
fix-up script, idempotent cleanup) reduce blast radius but don't
remove the failure mode.

Forgejo (deployed for OAuth and personal repos at
`forgejo.viktorbarzin.me`) ships a built-in OCI registry as part of
the Packages feature, default-on in v11. Using it removes
`distribution`-the-engine from the path entirely, replaces it with
Forgejo's own implementation backed by Forgejo's DB+blob store, and
gets us source hosting + image hosting in one resource.

The PVE host RAM upgrade from 142GB to 272GB (memory id=569) means
the cluster can absorb the resource bump Forgejo needs for the
registry workload (1Gi → 1Gi).

## Decision

Move every image currently on `registry.viktorbarzin.me:5050` to
Forgejo's OCI registry at `forgejo.viktorbarzin.me`. Decommission
`registry-private` after a 14-day dual-push bake.

Pull-through caches for upstream registries (DockerHub, GHCR, Quay,
k8s.gcr, Kyverno) stay on the registry VM permanently — Forgejo
won't serve as a pull-through, so the chicken-and-egg of "Forgejo
pulling its own image through itself" never arises.

## Design

### Registry hostname

Image references become `forgejo.viktorbarzin.me/viktor/<image>:<tag>`.
The `viktor/` prefix is the Forgejo owner namespace; all current
private images ship under that single owner.

### Auth

Two service-account users:

| User | Scope | Vault key | Used by |
|---|---|---|---|
| `cluster-puller` | `read:package` | `secret/viktor/forgejo_pull_token` | cluster-wide `registry-credentials` Secret, monitoring probe |
| `ci-pusher` | `write:package` | `secret/ci/global/forgejo_push_token` | Woodpecker pipelines (synced via `vault-woodpecker-sync` CronJob) |

A third PAT (`secret/viktor/forgejo_cleanup_token`, also belongs to
`ci-pusher`) drives the retention CronJob — kept separate from the
push PAT so a leaked CI token doesn't immediately enable mass deletes.

PATs have no expiry. Rotation policy: regenerate via Forgejo Web UI
and `vault kv patch` if a leak is suspected; ESO/sync downstream is
automatic.

### Cluster pull path

`registry-credentials` is a single Secret in `kyverno` ns, cloned
into every namespace by the existing
`sync-registry-credentials` ClusterPolicy. We extend its
`dockerconfigjson` `auths` map with a fourth entry for
`forgejo.viktorbarzin.me`. **No new Secret, no new ClusterPolicy,
no `imagePullSecrets =` line edits across stacks.**

Containerd `hosts.toml` redirects `forgejo.viktorbarzin.me` → in-cluster
Traefik LB at `10.0.20.200`, the same pattern used for
`registry.viktorbarzin.me` → `10.0.20.10:5050`. Avoids hairpin NAT
through the WAN gateway for in-cluster pulls.

### Push path

Woodpecker pipelines push to BOTH targets during the bake:

```yaml
- name: build-and-push
  image: woodpeckerci/plugin-docker-buildx
  settings:
    repo:
      - registry.viktorbarzin.me/<name>
      - forgejo.viktorbarzin.me/viktor/<name>
    logins:
      - registry: registry.viktorbarzin.me
        username:
          from_secret: registry_user
        password:
          from_secret: registry_password
      - registry: forgejo.viktorbarzin.me
        username:
          from_secret: forgejo_user
        password:
          from_secret: forgejo_push_token
```

The `vault-woodpecker-sync` CronJob (every 6h) propagates
`secret/ci/global` keys to every Woodpecker repo as global secrets.

### Retention

Forgejo's per-package "Cleanup Rules" UI is per-user runtime DB
state, not Terraform-driven. Retention runs as a CronJob in the
`forgejo` namespace, schedule `0 4 * * *`, that:

1. Lists all container packages under the `viktor` owner.
2. Groups by package name.
3. Keeps newest 10 versions + always keeps `latest`.
4. DELETEs the rest via `/api/v1/packages/{owner}/{type}/{name}/{version}`.

First 7 days run with `DRY_RUN=true` — script logs what it would
delete but issues no DELETE calls. After log review, flip the
`forgejo_cleanup_dry_run` local in `cleanup.tf` to false.

### Integrity monitoring

Mirror the existing `registry-integrity-probe` CronJob: walk
`/v2/_catalog`, walk every tag, HEAD every manifest + index child,
push `registry_manifest_integrity_*` metrics. Existing
Prometheus alerts fire on the `instance` label, so they cover both
probes automatically once the alert annotations are made
instance-aware (done in this change).

### Source migration

Projects currently living as plain dirs in the local-only monorepo
become standalone Forgejo repos. Two GitHub-hosted private repos
(`beadboard`, `claude-memory-mcp`) move to Forgejo and are archived
on GitHub.

CI standardises on Woodpecker for everything in scope. The two
projects that used GHA (build + Woodpecker-deploy via GHA-hosted
DockerHub push) keep DockerHub for legacy compatibility but their
canonical image source becomes Forgejo.

### Break-glass for infra-ci

`infra-ci` is the Docker image used by all infra Woodpecker
pipelines, including `default.yml` (terragrunt apply). If Forgejo is
unreachable at the moment we need to apply, `infra-ci` is
unreachable, and we can't apply our way out.

Mitigation: dual-push step also `docker save | gzip` the built
infra-ci image to:

- `/opt/registry/data/private/_breakglass/infra-ci-<sha>.tar.gz` on
  the registry VM disk (Copy 1)
- `/srv/nfs/forgejo-breakglass/` on the NAS (Copy 2)

A `latest` symlink in each location points at the most recent.
Recovery procedure (`docs/runbooks/forgejo-registry-breakglass.md`):
scp tarball → `docker load` → `ctr -n k8s.io images import` → fix
Forgejo via that node.

### Cutover style

**Dual-push bake**: pipelines push to both registries for ≥14 days.
Pods continue pulling from `registry.viktorbarzin.me`. After bake:

1. Per-project PR: flip `image=` lines in Terraform stacks. Pod
   re-pull naturally on next rollout.
2. Phase 4: stop `registry-private` container, remove its
   `auths` entry from the cluster Secret, drop containerd hosts.toml
   entry.

## Why not alternatives

| Option | Rejected because |
|---|---|
| Stay on `registry-private` | Three corruption incidents in three weeks; mitigation cost rising |
| Run a fresh registry container alongside (no Forgejo) | Same upstream, same `distribution#3324` failure mode |
| GHCR / DockerHub for all private images | Public-by-default model + push rate limits; loses owner-owned blob storage |
| Harbor | Heavier than Forgejo registry, would need its own DB + ingress, no source-hosting integration |

## Risks

See plan doc § "Risk register" for the full table. Top three:

1. **Forgejo registry hits the same corruption pattern.** Mitigated
   by 14-day bake + integrity probe within 15 min.
2. **Forgejo down → infra-ci unreachable → can't apply.** Mitigated
   by tarball break-glass on VM + NAS.
3. **Pod re-pulls fail after `image=` flip due to containerd cache
   poisoning.** Mitigated by hosts.toml deployment + per-project
   `kubectl rollout restart` in Phase 3.
