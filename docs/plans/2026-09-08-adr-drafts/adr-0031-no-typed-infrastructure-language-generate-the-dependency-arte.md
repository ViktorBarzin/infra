# ADR-0031: No typed infrastructure language; generate the dependency artefact instead

Date: 2026-09-08
Status: Proposed

## Context

The question asked was whether adopting a typed infrastructure language would
make refactoring safe and make it clear what depends on what. Sixteen lanes
investigated it, three of them dedicated to this question, and the answer is
consistent across all three.

**The type checker already installed is not being called.** `terraform validate`
performs the cross-module interface checks the question describes, across all
106 `ingress_factory` consumers and all 95 `setup_tls_secret` consumers, in
0.09 s of core time and 2.6 to 4.3 s per stack end to end. Measured, it reports
unknown resource arguments, undeclared module variables, references to
undeclared resources, references to nonexistent module outputs, duplicate
`lifecycle` blocks and nested `resource` blocks. CI calls it zero times, along
with `terraform fmt -check`, `terragrunt hclvalidate`, and the 292 tests already
under `scripts/`.

**No configuration language can type a Terraform dependency.** This is
structural. Terraform's JSON syntax expresses every cross-resource reference as
a `${}` string template inside a JSON string, evaluated after parsing, so a
language that generates Terraform emits references as opaque strings its own
type system cannot see through. The one project that tried, `tf-ncl`, has had
that feature unimplemented since 2022. Of the seven candidate languages, CUE and
Nickel merge or gradualise types by design, Jsonnet and Starlark are dynamically
typed on purpose, KCL's last release was 17 months ago, Dhall's was 20 months,
and Pkl has no HCL renderer. No public precedent exists for any of them driving
Terraform at scale.

**Most typed SDKs are gone.** CDKTF was deprecated on 2025-12-10 and archived,
with HashiCorp's own migration advice being to export back to HCL. System
Initiative's repo is archived. Wing has had no release in 19 months. cdk8s emits
YAML with no state, no apply and no drift detection, and cannot express the 232
non-Kubernetes resource blocks here.

**Pulumi is alive and does not pay.** Compiled against the real incidents, it
catches 4 of 42 human-fixed rows: the sablier null dereference (`TS18049`), the
duplicate `lifecycle` block (`TS1117`), the invalid HCL, and the missed
`ExternalSecret` v1beta1 but only with generated `crd2pulumi` classes, since
`apiextensions.CustomResource` takes `apiVersion` and `kind` as bare strings and
leaves the body untyped. Every one of those four is also caught by a control
costing hours: `required_version`, `terraform validate`, and `kubectl apply
--dry-run=client` respectively. It catches neither the Traefik 443 collision nor
the middleware namespace-prefix defect, because both are semantic.

On the repo's largest coupling surface it regresses. 581 `ignore_changes` entries
carry 1,018 field-ownership markers across 147 of 152 stacks. Pulumi declares
`ignoreChanges?: string[]`, and four invented field paths compile clean, where
`terraform validate` rejects the same paths and suggests the correction.

Migration cost, measured: Terragrunt has never been supported by the converter,
so the root generate blocks, the `include` in all 152 stacks and the 231
`dependency` blocks convert to nothing; `path.module` and `path.root` appear 147
times across 69 files in 48 stacks and are documented as preventing conversion;
500 of 1,583 resource blocks sit inside modules, which the state importer skips;
there is no first-party `authentik` provider and no bridge for
`telmate/proxmox`; and Pulumi Cloud's free tier is one user, so it needs a DIY
`postgres://` backend on the CNPG cluster whose restore has never been
performed.

## Decision

Do not adopt a typed configuration language or a typed IaC SDK.

For the type-checking half of the goal, call `terraform validate` (ADR-0028).

For the "know what depends on what" half, generate the artefact from what is
already reachable:

- `terragrunt render-json` emits each stack's fully composed configuration,
  including the generated `cloudflare_provider.tf` with its `vault_kv_secret_v2`
  data source. That is the Vault coupling as data rather than as a grep, and
  `.gitignore` already reserves `stacks/*/terragrunt_rendered.json`.
- A static reach script over the same inputs CI's selector uses runs in 0.15 s
  with no Terraform, no cluster, no state and no lock, and backtested against
  real commits it reproduces the known selector gaps exactly.

If a per-stack dependency catalog is wanted, generate it and have CI assert it
is current. Do not hand-author one.

## Alternatives

- **Pulumi TypeScript.** The only live and credible option, costed above:
  4 of 42 incidents, no exclusive catches, a regression on the largest coupling
  surface, and a migration whose highest-risk step is 500 hand imports against
  live infrastructure where a mismatch is destroy-and-recreate.
- **Typed CRD classes via cdk8s or crd2pulumi.** Wins one acid test, the
  2026-07-09 missed `ExternalSecret`. Server-side dry-run of the same manifest
  catches it in days rather than weeks, with no Node toolchain, no 30,000 to
  50,000 generated lines, and it reads the live CRD rather than a committed
  snapshot.
- **CUE or KCL over the 223 Kubernetes manifest bodies.** The most defensible
  version of the typed idea, because Kubernetes is genuinely where the untyped
  surface is: 7 `validation` blocks in the whole repo against 191
  `kubernetes_manifest` and 32 `kubectl_manifest` resources. Still rejected: its
  one incident is already covered by `DriftStackErrored`, so the gain is
  detection latency rather than detection, against two representations to keep
  in sync and a language nobody here knows.
- **A hand-authored per-stack `provides`/`requires` catalog checked by
  Conftest.** Rejected on this repo's own record: three instances of
  hand-maintained metadata going stale are measured (the module consumer counts
  in `default.yml:236-239` matched no commit at any point, `monitoring.md:443`
  says 162 state schemas against 152 stacks, and `declared_tier0.json` warns in
  its own header that forgetting to regenerate produces a false positive). At
  about 25 commits a day the steady state is stale, and a stale contract either
  blocks a correct change or passes a wrong one.
- **`terragrunt run --all --queue-include-units-reading`.** Terragrunt's own
  selector, present in v0.77.20, and it would give the root-file selector its
  correct answer. Deferred rather than rejected: adopting `run --all` hands
  execution order to a declared graph this study measured as wrong by 3x to 145x
  per edge class, and DAG order over a graph missing most of its edges is
  differently wrong.

## Consequences

**Positive**
- Avoids a months-long migration whose measured yield is 4 of 42 incidents and
  whose highest-risk step is state import against production.
- Keeps HCL, which every existing tool in this estate speaks: the Vault lock in
  `scripts/tg`, the PG state backend, the four generate blocks, the drift cron,
  the Kyverno heredocs.
- Turns the dependency question into a generated artefact that cannot go stale,
  which is what was actually asked for.

**Negative**
- The Kubernetes manifest bodies stay untyped. That is a real gap: 191
  `kubernetes_manifest` and 32 `kubectl_manifest` resources carry schemas
  resolved against the live cluster at plan time or not at all. Server-side
  dry-run narrows it and does not close it.
- `terraform validate` cannot cross the Terraform boundary either. It will never
  catch a middleware reference naming a middleware that does not exist, which is
  why a small static cross-reference check is on the roadmap separately.
- This decision should be revisited if the shared-root bucket grows past three
  data points. The right thing to revisit first is the seeded control-plane
  rehearsal, not a language.
