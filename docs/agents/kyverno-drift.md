# Kyverno drift suppression and lifecycle markers

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Rewritten on 2026-10-11 when Keel was retired: the Keel markers are history now, and Terraform owns every third-party image version, with Renovate bumping it (`docs/architecture/automated-upgrades.md`).

## Kyverno Drift Suppression (`# KYVERNO_LIFECYCLE_V1`)

Kyverno's admission webhook mutates every pod with a `dns_config { option { name = "ndots"; value = "2" } }` block (fixes NxDomain search-domain floods — see `k8s-ndots-search-domain-nxdomain-flood` skill). Terraform does not manage that field, so without suppression every pod-owning resource shows perpetual `spec[0].template[0].spec[0].dns_config` drift.

**Rule**: every `kubernetes_deployment`, `kubernetes_stateful_set`, `kubernetes_daemon_set`, `kubernetes_cron_job_v1`, **and `kubernetes_job`** MUST include the following `lifecycle` block, tagged with the `# KYVERNO_LIFECYCLE_V1` marker so every site is greppable:

```hcl
# kubernetes_deployment / kubernetes_stateful_set / kubernetes_daemon_set / kubernetes_job
lifecycle {
  ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
}

# kubernetes_cron_job_v1 (extra job_template nesting)
lifecycle {
  ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
}
```

**`kubernetes_job` matters more than the others, not less.** A Job's pod
template is immutable, so Terraform cannot update the injected `ndots` option in
place the way it does on a Deployment — it plans a **replace**, which deletes and
re-runs the Job. For the one-shot `db_init` / `migrations` / `pg_db_init` Jobs
this repo uses, that means database initialisation and Alembic migrations
re-execute on **every apply** that touches the stack, and the stack never stops
showing drift. Five Jobs were missing the line until **2026-08-14** (tts,
technitium, claude-memory, trading-bot ×2); `kubernetes_job` had been absent from
this rule's resource list, which is how they were overlooked.

**Why not a shared module?** Terraform's `ignore_changes` meta-argument only accepts static attribute paths. It rejects module outputs, locals, variables, and any expression. A DRY module is therefore impossible — the canonical pattern IS the snippet + marker. When `kubernetes_manifest` resources get Kyverno `generate.kyverno.io/*` annotations mutated, a sibling convention `# KYVERNO_MANIFEST_V1` will be introduced (Phase B).

**Audit**: `rg "KYVERNO_LIFECYCLE_V1" stacks/ | wc -l` — should grow (never shrink). Add the marker to every new pod-owning resource. The `_template/main.tf.example` stub shows the canonical form.

### Other `ignore_changes` markers

The canonical block for a new pod-owning resource is the `KYVERNO_LIFECYCLE_V1` line above, plus the Reloader line when Reloader watches the workload:

```hcl
lifecycle {
  ignore_changes = [
    spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
  ]
}
```

New workloads need no Keel lines: nothing stamps `keel.sh/*` annotations since the `inject-keel-annotations` policy was deleted (2026-10-10).

**Marker legend** (grep each to audit coverage):

| Marker | Ignores | Why |
|---|---|---|
| `# KYVERNO_LIFECYCLE_V1` | `dns_config` | Kyverno injects pod DNS `ndots` config |
| `# METALLB_LIFECYCLE_V1` | `metallb.io/ip-allocated-from-pool` (on **LoadBalancer Services**) | MetalLB's controller writes this onto the live Service once it allocates an IP; without the ignore every apply strips it and MetalLB re-adds it |
| `# RELOADER_LIFECYCLE_V1` | `reloader.stakater.com/last-reloaded-from` (pod template) | Stakater Reloader stamps this on the pod template when a watched Secret or ConfigMap rotates. Terraform manages a pod template's `annotations` map **even when the resource declares no `annotations` block** — it manages it as empty — so the stamp plans as a removal on **any** TF-managed workload Reloader watches, declared map or not, and Reloader re-adds it. Same provider behaviour as `metadata.labels` in the Kyverno row above. The declared-map test that `1fb7455d` asserts is disproved by its own contents: 4 of its 13 deployments declare no template annotations map and drifted anyway, as does `job-hunter`, the original precedent the convention is copied from |
| `# LEGACY_TEMPLATE_ANNOTATIONS` | `keel.sh/update-time` (pod template) | Left by Keel's rollouts. Removing the ignore strips the stamp, which is a pod-template change and restarts the workload, so it stays until a change that rolls the workload anyway |
| `# CI_SETS_IMAGE` | `container[N].image` / `init_container[N].image` | A first-party image that the app's own CI sets with `kubectl set image` (`docs/architecture/ci-cd.md`). Without the ignore, `apply` puts the Terraform tag back |
| `# FIRST_PARTY_IMAGE` | `container[N].image` | A first-party image built by hand and pushed as `:latest`, with no deploy pipeline. Renovate skips first-party images |
| `# FLOATING_TAG_DEFERRED`, `# DIGEST_PIN_DEFERRED`, `# IMAGE_SWAP_DEFERRED` | `container[N].image` | Third-party images that the Keel cutover could not pin without a pod restart; listed in `docs/architecture/automated-upgrades.md` ("Pins Renovate cannot bump yet"). Each goes once its pin lands |

**LoadBalancer Services** are the one non-pod-owning resource class in this
legend. Every `kubernetes_service` with `type = "LoadBalancer"` needs the
`METALLB_LIFECYCLE_V1` line — all 15 live LB Services carry the annotation, so
the rule is universal rather than per-service. Swept across the fleet on
**2026-08-14** (previously only `dbaas`'s `postgresql_lb` had it; traefik's
Service is Helm-owned and so out of Terraform's reach).

**Reloader** needs the line on any workload Reloader *watches*, not only the
ones it has already stamped, and **not only the ones whose pod template declares
an `annotations` map.** Both narrowings are wrong, and the second one cost a
second pass: the first sweep on **2026-09-16** covered 41 resources over 38
files in 32 stacks using the declared-map test, then a follow-up added the
remaining 38 resources over 36 files in 31 stacks once that test was disproved
(see the legend row). Together they take `rg "RELOADER_LIFECYCLE_V1" stacks/`
from 56 to **94**, which is the full TF-managed watched set.

The reason to cover the watched set rather than the drifting set: the live
cluster had 28 workloads carrying the annotation against 94 watched, and the
stamp appears on the next secret rotation, which for the Vault static database
roles is weekly. Fixing only what is drifting means coming back every week, and
the history shows exactly that — the count was 13 on 2026-09-03 and 28 two weeks
later. Audit against the watched set (any workload with a
`reloader.stakater.com/*` annotation other than `last-reloaded-from`), never
against today's drift report.

**Multi-container caveat**: an image ignore covers one container index. Add one `container[N].image` line for **every** container index that needs it, plus `init_container[N].image` for init containers. Read the index off the live pod (`kubectl -n <ns> get <kind>/<name> -o json`), not off the HCL's first container; claude-agent-service's CI-set images, for example, are `init_container[2]` and `[3]`.

### Who owns an image version

Terraform declares every image, and the declared string is what runs. Third-party versions change through a commit: Renovate's, or a person's. An image ignore is only right where something other than Terraform sets the image on purpose: the app's own CI (`# CI_SETS_IMAGE`), or one of the deferred cases above. A Terraform-tracked image that some other controller also rewrites makes the two undo each other on every apply; the image-flipflop detector (`stacks/monitoring/modules/monitoring/image_flipflop.tf`, alert `ImageOwnershipConflict`) reports that pattern.

### Retired Keel markers

From 2026-05 to 2026-10, Keel rolled enrolled workloads onto new tags, and the Kyverno `inject-keel-annotations` policy stamped `keel.sh/policy|trigger|pollSchedule` on almost every Deployment, StatefulSet and DaemonSet. Terraform tolerated that with three markers:

| Marker | Ignored |
|---|---|
| `# KYVERNO_LIFECYCLE_V2` | `keel.sh/policy`, `/trigger`, `/pollSchedule` on workload metadata |
| `# KEEL_IGNORE_IMAGE` | each container's image, which Keel rewrote |
| `# KEEL_LIFECYCLE_V1` | `keel.sh/match-tag`, `keel.sh/update-time` (pod template), `kubernetes.io/change-cause`, `deployment.kubernetes.io/revision` |

The Keel cutover (batches B00 to B17, 2026-10-10 to 2026-10-11) removed them stack by stack, renaming the `keel.sh/update-time` line to `# LEGACY_TEMPLATE_ANNOTATIONS`. They remain only in the stacks it deferred: the seven first-party apps that Keel deployed and that have no deploy step yet (excalidraw, interview-prep-app, k8s-portal, learning, pages-publish, repowise, trading-bot), anisette and llama-cpp (digest-only pins), and nextcloud (held for a supervised session). Those lines are inert. Many workloads also keep inert `kubernetes.io/change-cause` and `deployment.kubernetes.io/revision` ignores from the same block.

Background on the policy, the `keel.sh/match-tag` image swap of 2026-06-01 and the "nothing Keel bumps is tracked by Terraform" rule of 2026-08-15 is in git history (this file before 2026-10-11), `docs/post-mortems/2026-06-01-keel-match-tag-image-swap.md` and `docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md`.

**Audit**: `rg "METALLB_LIFECYCLE_V1" stacks/` should equal the number of TF-managed LoadBalancer Services (`kubectl get svc -A --field-selector spec.type=LoadBalancer` minus the Helm-owned traefik one). `rg "RELOADER_LIFECYCLE_V1" stacks/` should equal the number of TF-managed workloads Reloader watches (**94** as of 2026-09-16). `rg "KYVERNO_LIFECYCLE_V2|KEEL_IGNORE_IMAGE|KEEL_LIFECYCLE_V1" stacks/` should list only the deferred stacks named above, and shrink to nothing.
