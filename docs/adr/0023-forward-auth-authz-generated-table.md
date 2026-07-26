# ADR-0023: Forward-auth authorization via a generated host→groups table, not per-app Applications

Date: 2026-07-26
Status: Accepted

## Context

`auth = "required"` fronts ~100 ingresses. They **all** share one Authentik
`forward_domain` proxy provider → one Application ("Domain wide catch all") → one
expression policy (`admin-services-restriction`). That policy gated only ~17
admin-only hosts to `Home Server Admins` and returned `True` ("allow any
authenticated user") for everything else — so ~80 apps were reachable by any
logged-in identity, including a self-enrolled proxy/guest user. We want per-app,
default-deny, group-scoped access ("who logs in where"), extending the model
infra#82 already gave the OIDC apps.

Authentik's docs are explicit: *"domain-level forward auth cannot enforce
different application-level authorization rules for each protected application."*
So there are two ways to get per-app authorization:

- **(A) Per-app Applications** — migrate every forward-auth host to its own
  `forward_single` proxy provider + Application + native group binding. The
  Authentik-native model; unifies forward-auth with the OIDC apps; per-app UI
  tiles/logs; native "Application without binding" audit.
- **(B) A generated host→groups table** in the single existing expression policy,
  default-deny; the table is materialised from `allowed_groups` declared on each
  ingress.

Constraints that shaped the choice:

- The `authentik` stack is **critical-path and CI-auto-applies on push** (a broken
  apply is itself an outage risk).
- A greedy `forward_domain` catch-all and per-app `forward_single` providers
  **cannot cleanly coexist on one outpost** — proven live: the `Public` app needed
  its own dedicated outpost + middleware. So (A) forces either a big-bang cutover
  or a second outpost + per-host middleware migration.
- The embedded outpost is on the hot path of every forward-auth request (2
  replicas, tuned).
- Terraform-only mutations; commit = audit trail; reuse-before-building.

## Decision

Adopt **(B): a generated, default-deny host→groups table in the single catch-all
expression policy.** The table's rows are declared on the ingress
(`ingress_factory(allowed_groups = [...])`, default `["Home Server Admins"]`),
stamped as an annotation, and rendered into the policy by the authentik stack
reading the live Ingress inventory (`kubernetes_resources` data source) at apply
time. Access is **group membership only** — the former per-identity `chrome` list
becomes a `Chrome Users` group and the `proxy_only` attribute path is deleted.

Per-app Applications (A) is **rejected for now** but kept reversible: because the
source of truth is a mechanism-independent host→groups declaration, a future swap
to per-app providers changes only the generator, not the declarations.

## Consequences

**Positive**
- Delivers the full goal (default-deny, per-host group allow-lists) by changing
  **one small, unit-testable policy** — no new Authentik objects, the proven auth
  transport untouched, rollback is one revert.
- No ~250-object migration on the critical auto-applying stack; no UUID-pinning
  churn (the finicky `authentik` provider surface stays tiny).
- "Who logs in where" is answerable from group membership alone; the invite system
  (grants one group) is the only way access is conferred.

**Negative / accepted**
- **Not Authentik-native per-app:** no per-app tiles or per-app authorization logs
  in the Authentik UI (all forward-auth events read "Domain wide catch all"). This
  is observability, not access-decision robustness.
- **Single blast radius:** one policy governs all forward-auth apps. Mitigated by
  generating the *data* (not hand-editing) and unit-testing the small, stable
  policy skeleton with Authentik's `PolicyEngine`.
- **Apply-lag:** a newly-added gated app is denied until the authentik stack is
  applied (fails safe — deny, never open).
- A custom audit (ingress `allowed_groups` → real groups; wall-off probe) replaces
  the native "Application without binding" audit that (A) would have given for free.

## Reversibility

Deleting the generated `HOST_GROUPS` and restoring the `return True` default
reverts to the prior behavior. Migrating to (A) later is a generator swap over the
same ingress-declared source of truth.
