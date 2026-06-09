# Workstation Membership v2 — Authentik-group-driven, email-identified

**Status:** designed 2026-06-09, awaiting implementation. **Supersedes the *membership* model** of `2026-06-07-multi-user-workstation-design.md` (which used `roster.yaml` as the source of truth). Everything else in v1 stands unchanged — config inheritance (managed `claudeMd` + `~/.claude` symlinks), the per-user git-crypt-locked clone, the generic OIDC kubeconfig, swap, the `o-rx` admin-tree hardening, the emo cutover. This doc changes **only how workstation membership is defined and reconciled.**

## Problem

In v1 a workstation user is defined across three places with three identifiers (`os_user` / `authentik_user` / `k8s_user`, plus `email`): a git `roster.yaml`, a separate Authentik group, and Vault `k8s_users`. It's confusing and multi-place. Goal: **one definition, in Authentik, keyed by email; group membership grants the workstation.**

## Key principle: workstation access ≠ cluster authorization

These are independent axes and must not be conflated:

- **Workstation access** — "may you have an account on the devvm, reachable via t3?" A yes/no. Everyone who qualifies gets the *identical* non-admin setup (constrained account + locked `~/code` clone + generic kubeconfig + inherited config). The only distinction is **admin (wizard, the host owner — unlocked tree + sudo) vs non-admin (everyone else, identical).** No power-user/namespace-owner distinction exists at the workstation layer — it would not change a single provisioned file.
- **Cluster authorization** — "what may you do via `kubectl`?" That is RBAC, already group-driven (`kubernetes-admins/power-users/namespace-owners` + Vault `k8s_users`) and applied at `kubectl` time by the user's own OIDC identity. The workstation neither knows nor cares. **Untouched by this design.**

Collapsing the (redundant) workstation tiers is what makes the v2 small.

## Model

- **`T3 Users` Authentik group is the single control for workstation access.** It does both halves: (1) the Authentik edge gate admits its members to `t3.viktorbarzin.me`; (2) the provisioner creates a devvm account + `t3-serve` instance + locked clone/config/kubeconfig for each member. Either half alone is useless; together = "you have a workstation." Both already exist from the 2026-06-08 work — this design changes how *membership* is sourced.
- **A workstation user is fully defined by their Authentik account:** `email` (the one identity — OIDC subject, dispatch key, RBAC subject) + `T3 Users` membership + an optional `os_user` **attribute** (only to pin a legacy Linux name like `emo`; otherwise the os_user is derived from the email). Nothing in git or Vault defines workstation membership.
- **The provisioner reconciles from the Authentik API** (lists `T3 Users` members + their `os_user` attribute) → provisions the identical non-admin workstation for each member ≠ wizard. `roster.yaml` **retires** as the membership source. wizard is special-cased as the admin/owner (keeps his unlocked tree + sudo; never gets a locked clone).
- **`k8s_users`, cluster RBAC, Vault per-user isolation, Woodpecker/Cloudflared/dashboard — all untouched.** A workstation user's `kubectl` powers are whatever their existing cluster identity grants.

## Components

1. **Authentik** (`stacks/authentik`)
   - `T3 Users` group — already created + already wired into the edge policy (`admin-services-restriction.tf`, the `t3.viktorbarzin.me` branch). **Change:** drop the HCL `users = [...]` from the group resource so membership is managed *in Authentik* (UI/API), not in Terraform. Dropping the arg leaves current members intact (Terraform stops managing the list, doesn't clear it).
   - Optional per-user `os_user` **attribute** (Authentik user custom attribute) for legacy/override names.
   - A **read-only API token** scoped to read group membership, stored in Vault (`secret/authentik` → a new `t3_provision_token` field), dropped to a root-readable file (`/etc/t3-serve/authentik-token`, mode 0600 root) by `setup-devvm.sh` so the hourly root provisioner can call the API. (Root has no Vault token; this mirrors how other root-side secrets are staged.)

2. **Engine** (`scripts/workstation/roster_engine.py`, pure, pytest) — new functions:
   - `derive_os_user(email, os_user_attr) -> str` — `os_user_attr` if set, else `sanitize(local_part(email))`.
   - `desired_accounts(members, existing_ports) -> DesiredState` — given the Authentik member list (each `{email, os_user_attr?}`), produce the same `DesiredState` shape v1 derives from the roster (accounts, sticky ports, ttyd-map, dispatch). Keying: the ttyd-map/dispatch key is the **email local-part** (what `t3-dispatch` matches from `X-authentik-username`, e.g. `emil.barzin`); `os_user` is the derived/override Linux name (e.g. `emo`); `email` is the identity for RBAC/Vault. So a member resolves to a `local-part=os_user` map line — exactly the shape of today's `/etc/ttyd-user-map`. Reuses the existing additive-only + sticky-port logic.

3. **Provisioner** (`t3-provision-users.sh`) — replace the `roster.yaml` read with an Authentik API query (members of `T3 Users` + their `os_user` attribute) → feed the engine → apply (account, locked clone, kubeconfig, ttyd-map/dispatch, `t3-serve@`). **Best-effort:** if the token/API is unavailable, log a warning and make no membership changes (existing accounts untouched) — same posture as v1's k8s_users validation. wizard special-cased.

4. **Migration / retirement** — `roster.yaml` deleted; the provisioner no longer reads it.

## Data flow

```
Admin: create/locate Authentik user (email) → add to "T3 Users" group [+ optional os_user attr]
                                   │
        hourly t3-provision-users (root) ── reads /etc/t3-serve/authentik-token
                                   │         GET Authentik API: members of "T3 Users" (+ os_user attr)
                                   ▼
        roster_engine.desired_accounts(members) → desired state (email-keyed)
                                   ▼
   for each member ≠ wizard: ensure account (os_user derived/override), locked ~/code clone,
        generic kubeconfig; regenerate /etc/ttyd-user-map + dispatch.json; enable t3-serve@<os_user>
                                   ▼
   Authentik edge gate already admits "T3 Users" → member logs into t3.viktorbarzin.me → their instance
```

Remove from `T3 Users` → next reconcile: the member drops out of the regenerated map/dispatch (dispatcher 403s) — the **reversible cut**. Destructive `userdel` stays a separate, gated step (per the offboarding runbook).

## os_user derivation

`os_user = attributes.os_user` if present, else `sanitize(email.split("@")[0])` where `sanitize` = lowercase, replace each run of `[^a-z0-9_-]` with `_`, strip leading/trailing `_`, truncate to 32 chars (Linux username limit). Example: `emil.barzin@gmail.com → emil_barzin`. **Collisions** (two emails → same os_user) are resolved by setting an explicit `os_user` attribute; the engine flags a collision rather than silently merging. **Legacy:** emo's existing account is kept by setting his Authentik `os_user` attribute to `emo`.

## Error handling

- Authentik token/API unavailable → warn, skip membership reconcile, leave existing accounts untouched (never break on a transient API failure).
- A member with a colliding/underivable os_user and no override attribute → skip that member + warn (do not guess).
- Additive-only for existing accounts (never strip groups, replace `~/code`, or rewrite secrets). Removed members → reversible cut now; `userdel` only via the explicit gated offboarding path.
- wizard is never reconciled from the group (special-cased), so a mistaken group edit can't touch the admin/owner account.

## apiserver-OIDC caveat (does NOT affect this design)

The generic kubeconfig's auth method (OIDC via kubelogin vs the dashboard's SA-token pattern) hinges on the contested question of whether the apiserver accepts Authentik OIDC tokens (a 2026-06-04 memory says it rejects them; the `kubernetes`-audience `AuthenticationConfiguration` this session's RBAC work bound against suggests otherwise). This affects only how `kubectl` authenticates — **not** workstation membership. To be verified during implementation with a live OIDC login; if OIDC is rejected, the kubeconfig falls back to per-user SA-tokens (the existing dashboard mechanism), with no change to this membership model.

## Testing

- **Unit (pytest, extends `test_roster_engine.py`):** `derive_os_user` (sanitization, attribute override, collision detection); `desired_accounts` (member list → desired state; the additive-only invariant; offboard diff for a removed member). Pure, no host/API I/O.
- **Smoke (live):** add a throwaway Authentik user to `T3 Users` → run the provisioner → confirm the account + `t3-serve` instance + locked clone appear and login routes correctly; remove from the group → confirm the reversible cut (dispatcher 403s, account retained).

## Out of scope

- Cluster RBAC re-architecture — `k8s_users` and the 5 consumers stay as-is.
- Making Authentik the SSoT for the *cluster* (a separate, larger future epic).
- Workstation tier-groups (not needed — the workstation is admin-vs-non-admin only).
- Multiple admins (wizard is the sole special-cased admin; add a `T3 Admins` group only if a second admin is ever needed).

## Migration plan (summary; full steps in the implementation plan)

1. Drop the HCL `users` from the `T3 Users` group (members stay; now Authentik-managed); apply `stacks/authentik`.
2. Set emo's Authentik `os_user` attribute to `emo` (legacy pin); wizard needs none (special-cased).
3. Ship the engine functions + tests; switch the provisioner to the Authentik-API source; stage the read-only token via `setup-devvm.sh`.
4. Verify a reconcile reproduces the current accounts (wizard/emo/ancamilea) exactly.
5. Delete `roster.yaml` + its references; update `service-catalog.md` + `multi-tenancy.md`.
