# Spec: Authentik invite-gated, group-scoped access

Design doc: https://plans.viktorbarzin.me/2026-07-26-authentik-invite-scoped-access-design.html
Source: `infra/docs/plans/2026-07-26-authentik-invite-scoped-access-design.md`

## Problem Statement

As the homelab owner I want to invite people to specific services with a simple,
self-service signup — and be confident they can reach ONLY what I intend. Today:

1. **Access leaks.** Any account I create (e.g. a proxy-only guest) can see and
   log into apps I never granted — **Kubernetes**, **Kubernetes Dashboard**,
   **TripIt** — because authentik applications default to *"allow any
   authenticated user"* when they have no access policy.
2. **Signup is fragile.** The current invite signup (Google social login + a
   Postgres session-cache "bridge") is hard to reason about and broke repeatedly,
   because an invite can't survive the Google OAuth round-trip.

I want: send someone a normal service link → they sign up with an invite code →
they land with exactly the access that code grants, and nothing more.

## Solution

A unified, invite-gated, **group-scoped** access model:

- **One invite code → one authentik group.** Every application is **default-deny**
  and lists which groups may enter. "Who can access what" = group membership.
- **Signup:** the shared link is the service itself (e.g. `proxy.viktorbarzin.me`).
  No session → authentik login with a **"Sign up"** option. Sign-up authenticates
  via **OIDC (Google) or a WebAuthn passkey**, and only *then* asks for the invite
  code. Because the code is entered **after** auth it never crosses the OAuth
  round-trip — the fragile bridge is deleted. The code resolves to a group; the
  new user is created in that group and returned to the service.
- **Codes are minted on demand** via `homelab invite create --group <g> [--uses N]
  [--expires D]`.
- The **four open apps are closed**, and a **default-deny audit** prevents
  regressions.

## User Stories

1. As the owner, I want to share a plain service link (e.g. `proxy.viktorbarzin.me`) and have new users able to sign up from there, so that I don't hand out special one-time URLs.
2. As an invited user with no account, when I open the link I want to be redirected to authentik with a clear "Sign up" option, so that I can create an account.
3. As an invited user, I want to authenticate with Google or a passkey, so that I don't manage a password.
4. As an invited user, I want to enter my invite code *after* signing in, so that signup completes reliably and the invite is never lost mid-flow.
5. As an invited user with a valid code, I want to be dropped into exactly the group it grants and returned to the service, so that I land where I was going.
6. As an invited user with an invalid/expired/already-used code, I want a clear error and NO account created, so that I know to ask for a fresh code.
7. As the owner, I want to mint a code for a specific group via `homelab invite create --group "Proxy Users"`, so that I control exactly what the invitee can access.
8. As the owner, I want to set uses and expiry (default single-use, 7-day), so that codes don't linger.
9. As the owner, I want `homelab invite list` and `homelab invite revoke <code>`, so that I can see and kill outstanding invites.
10. As the owner, I want every app to admit only explicit groups (default-deny), so that a new signup cannot reach anything I did not grant.
11. As the owner, I want Kubernetes and the K8s Dashboard restricted to my `kubernetes-*` groups + `Home Server Admins`, so that a guest cannot obtain a cluster OIDC token.
12. As the owner, I want TripIt restricted to a new `TripIt Users` group, so that only people I share travel with can see it.
13. As the owner, I want the `Public` app to stay anonymous, so that the intentional public app is unaffected.
14. As the owner, I want an audit that flags any authentik app with no access binding, so that default-deny cannot silently regress when a new app is added.
15. As an existing user (admin/family), I want my current access unchanged by this rollout, so that nothing I use breaks.
16. As the owner, I want the old `google-proxy-enrollment` bridge (capture/validate/assign policies) removed once the new flow works, so that the fragile machinery is gone.
17. As the owner, I want a guest who needs several apps handled by ONE group bound to that bundle, so that "one code → one group" still holds.
18. As an invited user, I want passkey signup to complete with no external redirect, so that the flow is fast and self-contained.
19. As the owner, I want the invite code to be short and typeable (not a long UUID), so that I can share it in a message.
20. As the owner, I want minting to reuse authentik's native Invitation object, so that the uses/expiry lifecycle is handled by authentik, not re-implemented.
21. As a returning invited user who is signed out, I want to sign IN (not sign up) with my Google/passkey, so that I re-enter without a code.
22. As the owner, I want the "Sign up" entry on the main login page, so that any service link funnels new users into signup.
23. As the owner, I want the existing `Proxy Users` account(s) to keep working through the migration, so that the just-fixed proxy access is not regressed.
24. As an operator, I want the CLI to fail clearly if the target group does not exist, so that I don't mint a code that grants nothing.

## Implementation Decisions

- **Access model:** one invite code → one authentik group. Every `Application`
  carries an explicit group/policy binding (default-deny). No binding is a defect
  the audit flags. `Public` (anonymous binding) is the sole intentional exception.
- **Signup identity:** OIDC (Google) + WebAuthn passkeys. No email/password.
- **Flow ordering (the key simplification):** authenticate FIRST (Google return
  or passkey registration), THEN prompt for the invite code inside the live
  enrollment flow. The invite is validated in the same flow plan as the user
  write, so the `capture-proxy-invite` / `validate-proxy-invite` session-cache
  bridge is no longer needed and is removed.
- **Invite object:** reuse authentik's native `Invitation` (via API). `fixed_data`
  carries `{ code, target_group }`. A short (~8-char, ~32-symbol alphabet) code is
  stored in `fixed_data.code`. The enrollment prompt validates the typed code
  against open invitations (match code, check single_use/expiry), resolves
  `target_group`, and consumes the invite.
- **Group assignment:** a policy bound to the enrollment **login** stage adds the
  new user (`request.context["pending_user"]`) to `target_group` — the write stage
  runs before the user exists, so assignment happens at login (same pattern as the
  now-superseded `assign-proxy-group`).
- **Minting CLI:** a `homelab invite` subcommand (Go, `infra/cli`) calling the
  authentik API. `create --group <name> [--uses N=1] [--expires D=7d] [--label
  <who>]` → prints the code + service link. `list`, `revoke <code>`. Authentik API
  token read from Vault (`secret/authentik/tf_api_token`).
- **App bindings (Terraform, `stacks/authentik`):** add group `PolicyBinding`s to
  the **Kubernetes** and **Kubernetes Dashboard** applications
  (`kubernetes-admins` / `kubernetes-power-users` / `kubernetes-namespace-owners`
  + `Home Server Admins`); create a **`TripIt Users`** group and bind it to the
  **TripIt** application; leave `Public` anonymous.
- **Default-deny audit:** a `homelab` read command + a scheduled check that lists
  any `Application` with zero policy/group bindings and alerts on regression —
  same spirit as `check-ingress-auth-comments.py` and the
  `AuthentikWallingOffPublicPath` blackbox probe.
- **Login page:** add a "Sign up" link to the enrollment flow.
- **Removal (after cutover):** delete the `google-proxy-enrollment` flow +
  `capture-proxy-invite` / `validate-proxy-invite` / `assign-proxy-group` policies.

## Testing Decisions

Good tests exercise **external behavior**, not internals. Seams, highest and
fewest first:

1. **`homelab invite` pure logic** (code generation, code validation, Invitation
   marshalling) — Go unit tests in `infra/cli`. Prior art: the pure-logic Go/py
   unit tests already in the repo (`stacks/proxy/files/broker/*_test.py`,
   `stacks/nvidia/modules/nvidia/watchdog_test.py`) and any existing `infra/cli`
   tests. The API-calling paths are thin wrappers, tested via the pure layer.
2. **Authentik access policies** — evaluated with authentik's own `PolicyEngine`
   against a user + a request context, at BOTH evaluation points (authorize step:
   no `host`; per-request: `host` set). This is the exact seam used to root-cause
   the OAuth-authorize bug this session. Assertions: a group member → grant on
   their app(s) + deny elsewhere; a proxy-only guest → proxy grant + Kubernetes/
   TripIt deny; an app with no binding → surfaced by the audit.
3. **Terraform bindings** — `scripts/tg plan/apply` + a PolicyEngine assertion
   post-apply. Not unit-tested (config).

The **signup flow E2E (Google login) cannot be automated** — Google blocks
automated browsers, including the headful stealth cluster browser (verified
2026-07-26). E2E is a manual human Google/passkey signup; agent verification uses
the PolicyEngine seam + crafted-session forward-auth checks against
`/outpost.goauthentik.io/auth/traefik`.

## Out of Scope

- Re-architecting the proxy (done: neko + GPU + coturn).
- Non-authentik auth paths (native app logins, API bearer tokens, Anubis-fronted content).
- A full re-review of *every* existing app's group (this closes the 4 open apps + establishes the model; a broader per-app gate audit is a follow-up).
- Moving existing users between groups (existing memberships are audited, not rewritten).
- A self-service invite web UI (CLI only).

## Further Notes

- **WebAuthn-first signup risk:** confirm authentik's `authenticator_webauthn`
  enroll stage can register a passkey for a not-yet-created user in-flow (may need
  `user_write` to run first, then bind the passkey).
- **Short-code entropy:** 8 chars over a 32-symbol alphabet ≈ 10¹²; enforce
  uniqueness at mint time.
- **Rollout order (no lock-outs):** audit existing memberships → **close the 4
  open apps (safe, independent first increment)** → build the new flow + CLI →
  cut over + delete the bridge → add the default-deny audit.
