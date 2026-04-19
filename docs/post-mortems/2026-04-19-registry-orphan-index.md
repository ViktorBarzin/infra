# Post-Mortem: Private Registry Orphan OCI-Index — Repeat Incident

| Field | Value |
|-------|-------|
| **Date** | 2026-04-19 (first occurrence 2026-04-13) |
| **Duration** | ~40 min of blocked CI each time; only detected via pipeline failures |
| **Severity** | SEV2 — all infra CI pipelines using `infra-ci:latest` failed (P366 → P376 all exit 126 "image can't be pulled") |
| **Affected Services** | Every Woodpecker pipeline that starts with `image: registry.viktorbarzin.me:5050/infra-ci:latest` — `default.yml`, `build-cli.yml`, `renew-tls.yml`, `drift-detection.yml`, `provision-user.yml`, `k8s-portal.yml`, `postmortem-todos.yml`, `issue-automation.yml`, `pve-nfs-exports-sync.yml` |
| **Status** | Hot fix green (three commits: `a05d63ee`, `6371e75e`, `c113be4d` — URL fix + rebuild). This doc captures the permanent fix landed in the same branch. |

## Summary

On 2026-04-19 ~09:00 UTC, every infra CI pipeline started failing at the
`clone` step with "image can't be pulled". The image in question — the CI
toolchain image `registry.viktorbarzin.me:5050/infra-ci:latest` — resolved
to an OCI image index whose `linux/amd64` platform manifest
(`sha256:98f718c8…`) and its in-toto attestation
(`sha256:27d5ab83…`) returned **HTTP 404** from the private registry.
The index record itself still existed — it's the children that had been
garbage-collected out from under it.

This is the **second identical incident**: the same failure mode occurred
on 2026-04-13 against a different image. Both times the immediate fix was
to rebuild the image from scratch; both times the root cause was left
unaddressed.

## Impact

- **User-facing**: all CI pipelines failed. No automated Terraform applies,
  no TLS renewal, no drift detection. Manual workflows (Woodpecker UI
  reruns) all failed with the same error.
- **Blast radius**: every pipeline that pulls `infra-ci`. Does NOT affect
  k8s workloads (those pull via containerd, which goes through the
  pull-through proxy on :5000/:5010 — a completely different code path).
- **Duration on 2026-04-19**: from first P366 failure to the hot-fix
  commit `c113be4d` — roughly 40 min. Pipelines that had already been
  triggered queued up until the rebuild restored `:latest`.
- **Data loss**: none. The registry has the index object; the child
  manifests are re-producible by rebuilding the source image.
- **Monitoring gap**: nothing alerted. The only signal was the individual
  pipeline failures from Woodpecker. No Prometheus alert fires on "the
  registry served a 404 for a tag that exists".

## Timeline (UTC, 2026-04-19)

| Time | Event |
|------|-------|
| ~09:00 | P366 (`default.yml` on master) fails with exit 126. |
| 09:00–11:00 | P367, P368, … P376 all fail with the same error. Nobody pages — there's no alert configured. |
| 11:15 | User notices and investigates: `skopeo inspect` reveals the missing platform manifest. |
| 11:20 | Hot fix phase begins: `a05d63ee` fixes a push-URL misalignment, `6371e75e` and `c113be4d` trigger a full rebuild. |
| 11:40 | Rebuild completes; `infra-ci:latest` resolves to a fresh, complete index. Pipelines green from P377 onward. |
| 11:45 | User requests a proper root-cause fix: "this is the second time — what's actually broken?" |
| 12:00 | Investigation begins (this document's work). |

## Root Cause Chain

```
[1] cleanup-tags.sh runs daily at 02:00 on the registry VM
 └─> For each repository, keeps the last 10 tags by mtime, rmtrees the rest.
     This walks `_manifests/tags/<tag>` directly, bypassing the registry API.
         │
         ├─> [2] Subtle on-disk asymmetry: a registry:2 tag rmtree removes
         │    BOTH the `_manifests/tags/<tag>/` dir AND — on 2.8.x — the
         │    per-repo revision-link files under
         │    `<repo>/_manifests/revisions/sha256/<child-digest>/link` for
         │    every child referenced by that tag's index. The raw blob data
         │    under `/var/lib/registry/docker/registry/v2/blobs/sha256/<.>/data`
         │    is NOT touched — GC owns that, and GC only runs Sunday.
         │
         ├─> [3] If ANOTHER tag's index still references one of those same
         │    children (common — successive rebuilds share layers), the child
         │    blob survives. But the revision-link is gone, so the registry
         │    API can no longer map `<repo>/manifests/sha256:<child>` back
         │    to the blob. HEAD → 404, even though the bytes are on disk.
         │    distribution/distribution#3324 is the upstream class of this bug.
         │
         └─> [4] Result: the surviving index (e.g. `infra-ci:5319f03e`) is
              intact on disk, its children's blob data files are intact on
              disk, but HEAD `/v2/infra-ci/manifests/sha256:98f718c8…`
              returns 404. The registry has the bytes, but cannot find them
              through the API because the per-repo link bridge is gone.

[pull] containerd resolves `infra-ci:latest`
         │
         ├─> GET /v2/infra-ci/manifests/latest → 200 OK, returns the index
         │
         └─> GET /v2/infra-ci/manifests/sha256:98f718c8… → 404 Not Found
              └─> containerd fails the pull with "manifest unknown"
                    └─> woodpecker exit 126
```

> **Detection-gotcha** uncovered 2026-04-19 while implementing
> `fix-broken-blobs.sh`: a scan that checks `/blobs/sha256/<child>/data` for
> presence is NOT equivalent to "can the registry serve this child?" The
> authoritative check is whether
> `<repo>/_manifests/revisions/sha256/<child>/link` exists. The script
> was rewritten to check the per-repo link file after the HTTP probe
> caught 38 real orphans the filesystem scan had reported clean.

## Why Existing Remediation Missed It

1. **`fix-broken-blobs.sh` only scans layer links.** The existing cron
   walks `_layers/sha256/` and removes link files whose blob `data` is
   missing. It does NOT inspect `_manifests/revisions/sha256/` to see
   whether an image-index's referenced children still exist. That's
   exactly the class of orphan this incident represents.
2. **`registry:2` image tag was floating.** `docker-compose.yml` pinned
   only to `registry:2`. Whatever Docker Inc. last rebuilt as
   "v2-current" was running, with no version pin. Any regression in
   the upstream walker would silently swap in.
3. **No integrity monitoring.** Prometheus alerted on cache hit rate
   and registry-down, but nothing probes "are the manifests the registry
   advertises actually fetchable?"
4. **CI pipeline didn't verify its own push.** `buildx --push` returns
   success as soon as it uploads. If a child blob upload 0-byted or
   the client disconnected mid-push (distinct from the GC mode but the
   same on-disk symptom), nothing would notice until the next pull.

## Permanent Fix — Three Phases

### Phase 1 — Detection (ship today)

1. **Post-push integrity check** in `.woodpecker/build-ci-image.yml`.
   After `build-and-push`, a new step walks the just-pushed manifest
   (and every child of an image index) and HEADs every referenced blob.
   Any non-200 fails the pipeline immediately, catching broken pushes at
   the source rather than leaking them to consumers.
2. **Prometheus alert `RegistryManifestIntegrityFailure`.** A new
   CronJob (`registry-integrity-probe`, every 15m, in the `monitoring`
   namespace) walks the private registry's catalog, HEADs every tag's
   manifest, follows each image index's children, and pushes
   `registry_manifest_integrity_failures` to Pushgateway. Accompanying
   alerts: `RegistryIntegrityProbeStale`, `RegistryCatalogInaccessible`.
3. **Post-mortem** — this document. Linked from
   `.claude/reference/service-catalog.md` via the new runbook.

### Phase 2 — Prevention

4. **Pin `registry:2` → `registry:2.8.3`** in
   `modules/docker-registry/docker-compose.yml` (all six registry
   services). Removes the floating-tag footgun.
5. **Extend `fix-broken-blobs.sh`** to scan every
   `_manifests/revisions/sha256/<digest>` that is an image index and
   flag children whose blob `data` file is missing. The script prints a
   loud WARNING per orphan; it does not auto-delete the index, because
   deleting a published image is a conscious decision, not an automated
   repair.

### Phase 3 — Recovery tooling

6. **Manual event trigger** on `build-ci-image.yml`. Rebuilds no longer
   need a cosmetic Dockerfile edit — POST to the Woodpecker API or
   click "Run manually" in the UI.
7. **Runbook** `docs/runbooks/registry-rebuild-image.md` — exact
   command sequence for the next time this happens, plus fallback paths.

## Out of Scope

- **Pull-through caches.** The DockerHub / GHCR mirrors on
  `:5000` / `:5010` are healthy (74.5% cache hit rate, no 404s). The
  orphan problem is private-registry-only. No changes to nginx or
  containerd `hosts.toml`.
- **Registry HA / replication.** Single-VM SPOF is a known
  architectural choice. Harbor or a replicated registry would solve
  more than this incident requires, at multi-day cost. Synology offsite
  snapshots already give RPO < 1 day.
- **Disabling `cleanup-tags.sh`.** Keeping storage bounded is still
  necessary; the fix is detection + rebuild, not "stop cleaning up".

## Lessons

- **Repeat incidents deserve root-cause work, not a third hot-fix.** The
  2026-04-13 incident was closed when CI turned green. Without a probe
  and without a scan for orphan indexes, the next incident was
  inevitable — and it happened six days later against a different image.
- **"No alert fired, so it wasn't detected" is a monitoring gap, not an
  outage feature.** The registry was serving 404s for 2+ hours before
  anyone noticed, because our only signal was "pipeline failures" and
  our eyes were elsewhere. The new probe closes that gap.
- **CI pipelines should verify their own output.** The `buildx --push`
  "success" exit code is not a guarantee of pulled-back integrity — as
  this incident proves. A 30-second post-push HEAD walk is cheap
  insurance.

## Related

- **Prior incident (same failure mode, different image)**: memory `709`
  / `710` — 2026-04-13.
- **Runbook**: `docs/runbooks/registry-rebuild-image.md` (new).
- **Hot-fix commits**: `a05d63ee`, `6371e75e`, `c113be4d`.
- **Upstream bug class**: `distribution/distribution#3324`.
