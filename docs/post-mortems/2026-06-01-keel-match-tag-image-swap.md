# Post-Mortem: Keel `match-tag` cross-assigned the blog's container images (site down ~6 days)

| Field | Value |
|-------|-------|
| **Date** | 2026-06-01 |
| **Duration** | 2026-05-26 19:47 UTC → 2026-06-01 ~16:00 UTC (~6 days) |
| **Severity** | SEV3 — `viktorbarzin.me` (public blog) fully down; user-facing, but a personal blog with no SLA |
| **Affected** | `website/blog` Deployment (acute outage). Latent: 194 enrolled workloads carried the same stale annotation; 16 were multi-image swap-risk |
| **Status** | Fixed — images un-swapped, `keel.sh/match-tag` stripped fleet-wide, `inject-keel-annotations` policy hardened to strip it on admission |

## Summary

Reported by the operator as "blog is crashlooping." The `website/blog` pod was
`1/2 CrashLoopBackOff`. The two container images had been **swapped**: the
container named `nginx-exporter` was running the nginx blog image
(`viktorbarzin/blog:cfd39d6f`) and receiving the exporter's
`-nginx.scrape-uri` arg — nginx's entrypoint rejected `-n` (`illegal option`)
and crashed; while the container named `blog` was running the exporter image
(`nginx/nginx-prometheus-exporter:1.5.1`), listening on `:9113` instead of
serving the site on `:80`. **Nothing served `:80`, so the blog was fully down**
(Anubis → `blog:80` → connection refused), not merely a crashing sidecar.

The swap happened **2026-05-26 19:47 UTC** (rollout revisions 28–35, all stamped
`keel automated update, version latest -> 1.5.1`) and went unnoticed for ~6 days.

## Root cause (chain)

1. The `inject-keel-annotations` Kyverno policy stamps Keel control annotations
   on every workload in `keel.sh/enrolled=true` namespaces. Before 2026-05-26
   the default was `keel.sh/policy: force` + `keel.sh/match-tag: "true"`.
2. The `blog` Deployment runs **two containers with two different images that
   both float on tag `latest`**: `viktorbarzin/blog:latest` and
   `nginx/nginx-prometheus-exporter` (→ `:latest`).
3. On 2026-05-26 `nginx/nginx-prometheus-exporter` published semver `1.5.1`.
   Under `force + match-tag`, Keel rewrote the deployment and **cross-assigned
   the two images** — the exact class of failure the same-day incident
   documented (uptime-kuma `:2→:1`, n8n `:1.80.5→:0.1.2`, etc.). The blog was a
   casualty of that incident but was **not on the cleanup list**.
4. Same day, the policy default was switched `force → patch` and `match-tag` was
   dropped from the patch — but **Kyverno's add-only `patchStrategicMerge`
   cannot remove an annotation that's no longer listed**. So ~194 pre-migration
   workloads (the blog included) kept a stale `keel.sh/match-tag=true`.
5. Because the blog's images are in Terraform `ignore_changes` (Keel/Woodpecker
   own them) and the keel annotations are policy-managed (not in the stack), a
   `terraform apply` would not have corrected either field — the broken state
   was invisible to the normal apply/drift loop.

## Why hard to spot

- **No crash on most swaps.** A swap only hard-crashes when a container's args
  are rejected by the wrong image. The blog crashed because nginx got
  `-nginx.scrape-uri`. The sibling `travel_blog` has `match-tag` too but its
  exporter sidecar is commented out (single container — nothing to cross-wire),
  so it was fine. `changedetection` shows crossed images but both boot without
  conflicting args, so it ran 2/2 for days — silently mis-wired, no alert.
- **No external monitor caught it.** The Anubis challenge page returns 200
  without reaching the backend, so a naive front-door check looks healthy.
- The acute symptom (`CrashLoopBackOff`) was only visible via `kubectl`, and the
  blog has no SLA, so nothing paged.

## Fix (applied + committed 2026-06-01)

1. **Un-swapped the blog images** via `kubectl set image` (the same path
   Woodpecker uses for this TF-ignored image): `blog=viktorbarzin/blog:cfd39d6f`,
   `nginx-exporter=nginx/nginx-prometheus-exporter:1.5.1`. Pod is 2/2; site
   serves 200 internally and externally (`/net-diag.sh` via the Anubis-bypass
   carve-out returned the real 40 KB script).
2. **Removed the orphaned annotation** from the blog (`kubectl annotate …
   keel.sh/match-tag-`).
3. **Hardened the policy** (`stacks/kyverno/modules/kyverno/keel-annotations.tf`):
   added `keel.sh/match-tag = null` to the `patchStrategicMerge`, so the
   annotation is stripped on admission for every enrolled workload and can never
   be re-added.
4. **Swept the fleet.** `mutateExistingOnPolicyUpdate` did *not* regenerate
   UpdateRequests for a removal-only change (Kyverno re-mutates existing
   resources for add/set, not deletions), so the 194 pre-existing workloads were
   swept once with `kubectl annotate <kind>/<name> -n <ns> keel.sh/match-tag-`.
   Annotation-only ⇒ no pod restarts (verified: vault/CSI/monitoring pod ages
   unchanged). Remaining `match-tag=true`: 0.

## Lessons

- **Add-only mutation can't undo itself.** Dropping a key from a Kyverno
  `patchStrategicMerge` does not remove it from already-mutated resources — you
  must set it to `null` *and* sweep existing ones. The 2026-05-26 migration did
  neither, leaving 194 landmines.
- **Multi-image pods + a shared floating tag + `force`/`match-tag` = swap risk.**
  Keep third-party sidecars on explicit pinned tags, not `latest`, so they never
  share a tag with the app image.
- **State that Terraform `ignore_changes` is invisible to drift detection.**
  Image fields and policy-managed annotations won't show up in `plan`; they need
  their own verification (a synthetic backend probe, not just the front door).

## Audit result (completed 2026-06-01)

All 16 multi-image swap-risk workloads were checked. **Only two were actually
swapped:**

- `website/blog` — acute crash (fixed, un-swapped).
- `changedetection/changedetection` — *silent* swap: it ran 2/2 for days
  because pod containers share a network namespace (each process still bound its
  own port), but the app was running **without its `/datastore` PVC, without
  `PLAYWRIGHT_DRIVER_URL`/`BASE_URL`, and at a 128Mi cap** — config was ephemeral
  and one restart from total loss. Un-swapped; `/datastore` (watch config back to
  Feb 2026) re-mounted; app confirmed serving `200` with watches loaded.

The other 14 are NOT swapped: `insta2spotify` and `priority-pass` (the other
custom app+helper pairs) verified correctly mapped; the rest are upstream Helm
charts (grafana, prometheus, loki, alloy, vault, the CSI controllers/nodes,
mysql) with fixed image→container mappings, all healthy. `match-tag` is now
stripped from all of them, so none can swap again.

## Recommendation (not yet actioned)

- An **external monitor that hits the bare blog backend** (bypassing Anubis)
  would have caught this: the Anubis challenge page returns `200` without
  reaching the backend, so the front-door monitor stayed green for 6 days.
