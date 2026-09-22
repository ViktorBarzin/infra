# Kyverno drift suppression and Keel image ownership

Moved verbatim from the repo's agent instruction files (`AGENTS.md`, `.claude/CLAUDE.md`) on 2026-09-22, when the two merged into one root `AGENTS.md`. Related as-built docs: `docs/plans/2026-05-16-auto-upgrade-apps-design.md`.

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

### `# KYVERNO_LIFECYCLE_V2` — Keel auto-update annotations

When a namespace is labeled `keel.sh/enrolled=true`, the `inject-keel-annotations` ClusterPolicy (`stacks/kyverno/modules/kyverno/keel-annotations.tf`) injects these annotations on every Deployment / StatefulSet / DaemonSet:

```
keel.sh/policy: patch
keel.sh/trigger: poll
keel.sh/pollSchedule: "@every 1h"
```

**`keel.sh/match-tag` is NO LONGER injected — it is actively STRIPPED.** It was the pre-2026-05-26 default (`force + match-tag`), proven unreliable: under `force` it let Keel rewrite tag strings and cross-assign images between containers in multi-image pods. The `blog` deployment was a casualty — its `nginx` ⇄ `nginx-exporter` images got swapped and the site was down 2026-05-26 → 2026-06-01. The policy now sets the annotation to `null` (strips on admission); the 194 pre-existing workloads still carrying it were swept once via `kubectl annotate … keel.sh/match-tag-` on 2026-06-01. The `ignore_changes` line for it (below) is retained as a harmless no-op. See `docs/post-mortems/2026-06-01-keel-match-tag-image-swap.md`.

**Three stacks re-declare it deliberately, and need it** — `k8s-portal`, `interview-prep-app`, `pages-publish`. For a **single-container** workload tracking its own `:latest`, `match-tag` is what makes Keel poll the tag's DIGEST ("watch tag digest job") instead of scanning for new tags ("watch repository tags job", logged with `digest=` empty). A repo that only publishes `:latest` + a commit SHA never grows a new *tag*, so without it `force + poll` registers a watcher that can never fire and the app silently stops auto-deploying — `pages-publish` sat on a stale digest across ~3 poll windows on 2026-08-17 before anyone noticed. The 2026-06-01 swap hazard needs a multi-image pod sharing a floating tag; one container has no sibling image to swap with. A TF-declared value survives admission (checked with `kubectl annotate --dry-run=server`), because the strip lands on CREATE and Terraform owns the field afterwards. **Do not add `match-tag` to `ignore_changes` on these three** — if a recreate loses it, an apply must restore it and the nightly drift report must be able to see it gone, since silent loss means silent no-deploys.

To suppress the resulting Terraform drift, **enrolled workloads** must carry the complete `ignore_changes` block below. This is the canonical form — it folds together every marker (see the legend after it):

```hcl
lifecycle {
  ignore_changes = [
    spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    metadata[0].annotations["keel.sh/policy"],
    metadata[0].annotations["keel.sh/trigger"],
    metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    metadata[0].annotations["keel.sh/match-tag"],
    spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
    metadata[0].annotations["kubernetes.io/change-cause"],
    metadata[0].annotations["deployment.kubernetes.io/revision"],
    spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
  ]
}
```

**Marker legend** (the names are historical; grep each to audit coverage):

| Marker | Ignores | Why |
|---|---|---|
| `# KYVERNO_LIFECYCLE_V1` | `dns_config` | Kyverno injects pod DNS `ndots` config |
| `# KYVERNO_LIFECYCLE_V2` | `keel.sh/policy`, `/trigger`, `/pollSchedule` | Kyverno-injected Keel control annotations |
| `# KEEL_IGNORE_IMAGE` | `container[N].image` (one line **per container index**, incl. `init_container[N]`) | Keel rewrites the image tag on `policy=patch`; without this, `apply` reverts the bump (a **downgrade**) |
| `# KEEL_LIFECYCLE_V1` | `keel.sh/match-tag`, `keel.sh/update-time` (pod template), `kubernetes.io/change-cause`, `deployment.kubernetes.io/revision` | every Keel digest-update restamps these; without ignoring them `apply` strips them → forces a rollout → Keel re-stamps → fight loop |
| `# METALLB_LIFECYCLE_V1` | `metallb.io/ip-allocated-from-pool` (on **LoadBalancer Services**) | MetalLB's controller writes this onto the live Service once it allocates an IP; without the ignore every apply strips it and MetalLB re-adds it |
| `# RELOADER_LIFECYCLE_V1` | `reloader.stakater.com/last-reloaded-from` (pod template) | Stakater Reloader stamps this on the pod template when a watched Secret or ConfigMap rotates. Terraform manages a pod template's `annotations` map **even when the resource declares no `annotations` block** — it manages it as empty — so the stamp plans as a removal on **any** TF-managed workload Reloader watches, declared map or not, and Reloader re-adds it. Same provider behaviour as `metadata.labels` in the Kyverno row above. The declared-map test that `1fb7455d` asserts is disproved by its own contents: 4 of its 13 deployments declare no template annotations map and drifted anyway, as does `job-hunter`, the original precedent the convention is copied from |

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

**Multi-container caveat**: `container[0].image` only covers the first container. Add one `container[N].image` line for **every** container index, plus `init_container[N].image` for init containers — otherwise the un-ignored container's image still drifts/downgrades.

The `KEEL_LIFECYCLE_V1` + per-container `KEEL_IGNORE_IMAGE` lines were swept across all enrolled workloads on **2026-05-28** (previously only `llama-cpp` had them; the rest fought on every apply). New enrolled workloads must include the full block. Workloads in un-enrolled namespaces don't receive the annotations and don't need the block.

Per-workload opt-out: add the label `keel.sh/policy: never` on the Deployment metadata (not pod template); the policy's `exclude` clause respects it, no annotation gets injected, no `ignore_changes` needed.

**Audit**: `rg "KYVERNO_LIFECYCLE_V2" stacks/` — count should equal the number of enrolled workloads. `rg "KEEL_LIFECYCLE_V1" stacks/` should match it (every enrolled workload also carries the V1 lines). `rg "METALLB_LIFECYCLE_V1" stacks/` should equal the number of TF-managed LoadBalancer Services (`kubectl get svc -A --field-selector spec.type=LoadBalancer` minus the Helm-owned traefik one). `rg "RELOADER_LIFECYCLE_V1" stacks/` should equal the number of TF-managed workloads Reloader watches — **94** as of 2026-09-16.

### The invariant: nothing auto-upgraded is tracked by Terraform

**If Keel may bump a workload's image, Terraform must not track that image.**
(Viktor, 2026-08-15.) The two owners are mutually exclusive, and exactly one of
these must hold for every pod-owning resource:

- **Keel owns the version** — the workload carries `keel.sh/policy` set to
  anything other than `never`, and **every** container index that Keel can reach
  has a `KEEL_IGNORE_IMAGE` entry. Terraform still declares the image, but only
  as the value used when the resource is first created.
- **Terraform owns the version** — the workload is opted out with
  `keel.sh/policy: never`, and Terraform tracks the image normally. Use this
  where a pin is load-bearing (mysql-standalone, redis-v2, forgejo,
  node-local-dns, chrome-service and the rest of the ~29 currently on `never`).

Anything in between means the two fight on every apply. That is not only drift
noise: on 2026-08-15 four workloads were found where Terraform was reverting a
Keel upgrade to an **older** release each time it ran (hermes-agent and
claude-agent-service curl 8.11.1→8.11.0, learn git-sync v4.7.1→v4.7.0,
postiz/temporal auto-setup 1.28.4→1.28.1).

Two traps when adding the ignore:

- **The container index is not always 0.** Read it off the live pod
  (`kubectl -n <ns> get <kind>/<name> -o json`), not off the HCL's first
  container. hermes-agent and claude-agent-service drift on `container[1]`, the
  curl `vault-token-refresher` sidecar; android-emulator's drifting image lives
  in the `gate` Deployment, not the main one.
- **`keel.sh/policy` can be a label as well as an annotation.** node-local-dns
  carries it as a *label* valued `never`; ignoring only the annotation left
  Terraform stripping the opt-out.

**Audit the invariant** with `scripts/audit-keel-image-ownership.py`, which
walks every pod-owning resource, resolves its live workload, and reports any
Keel-enrolled workload whose image Terraform still tracks. It should print zero
gaps; it did across all 160 TF-managed enrolled workloads on 2026-08-15. Note it
skips commented-out `resource` blocks and is heredoc-aware — a naive brace match
mis-parses the stacks that embed shell scripts.

**Design context**: `docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md`.
