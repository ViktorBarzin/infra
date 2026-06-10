# 2026-06-10 — forgejo retention orphaned OCI index children (kms-website)

## Impact

- `viktor/kms-website:latest` and `:dfc83fb` unpullable (index children
  HTTP 404). No runtime impact — the deployed tag `:a794d1a` was intact
  and `imagePullPolicy: IfNotPresent` kept running pods unaffected.
- `RegistryManifestIntegrityFailure` firing from ~08:30 EEST;
  `forgejo-integrity-probe` reported 4 failures across 60 indexes.

## Root cause

The `forgejo-cleanup` retention CronJob (live since 2026-06-09, first
deleting run 2026-06-10 04:00) computes its keep-set over package
**versions**: newest `KEEP_LAST_N=10` + tag `latest` + `*cache*` tags.
Forgejo's container registry stores multi-arch / buildx-attestation
**index children as separate untagged sha256 versions**. For images not
rebuilt recently, those children sort *older* than the newest-10 window
and were deleted while their parent index (a kept tag) survived →
orphaned indexes, children 404.

The 2026-06-09 go-live verification ("0 running images on the delete
set") checked running **pods** against the delete list — it could not
see index→child references, so the corruption class passed review.

Detection worked as designed: `forgejo-integrity-probe` (15-min catalog
walk + manifest HEAD) caught it the same morning. Two probe-run quirks
slowed diagnosis: runs occasionally die at startup (`apk add` during
transient DNS blips at cron ticks, `set -eu`), so the alert's
active-since (08:29:52) lagged the 04:00 corruption.

## Fix applied (2026-06-10)

1. `forgejo_cleanup_dry_run = true` (stacks/forgejo/cleanup.tf, applied)
   — retention logs but deletes nothing until the keep-set is
   container-aware.
2. `:latest` re-pointed at the intact `:a794d1a` index (registry
   manifest PUT — `a794d1a` is also the newest commit of the repo, so
   content is correct).
3. Corrupt, obsolete `:dfc83fb` package version deleted.
4. Probe re-run: **0 failures across 22 repos / 63 tags / 59 indexes**.

## Follow-up (required before re-enabling deletes)

Pick one:
- (a) keep-set expansion: for every kept tagged version, resolve the
  manifest via the registry API; if it is an index, add all child
  digests to the keep set;
- (b) never delete untagged sha256 versions (simpler, but untagged
  garbage accumulates and the PVC pressure that motivated retention
  returns — registry PVC sits at its 50Gi ceiling on the HDD,
  see beads code-oflt);
- (c) replace the custom script with Forgejo's native per-owner package
  cleanup rules, which are container-aware.

Also worth probing beyond `TAGS_PER_REPO=5`: older tags of any
multi-arch image may already be orphaned (only newest-5 per repo are
verified). Harmless until someone pulls an old tag.

## Lessons

- "No running pod uses it" is not a safe deletion predicate for OCI
  artifacts — reference graphs (index → child manifests) must be
  resolved at the registry level.
- A `set -eu` probe whose first statement is a network package install
  conflates "registry broken" with "apk blip"; pre-bake the image or
  tolerate install retries.
