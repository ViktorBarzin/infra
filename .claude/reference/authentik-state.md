# Authentik Current State

> Snapshot of applications, groups, users, and flows. Use `authentik` skill for management tasks.

## Applications (10)
| Application | Provider Type | Auth Flow |
|-------------|--------------|-----------|
| Cloudflare Access | OAuth2/OIDC | explicit consent |
| Domain wide catch all | Proxy (forward auth) | implicit consent |
| Forgejo | OAuth2/OIDC | explicit consent |
| Grafana | OAuth2/OIDC | implicit consent |
| Headscale | OAuth2/OIDC | explicit consent |
| Immich | OAuth2/OIDC | explicit consent |
| Kubernetes | OAuth2/OIDC (public) | implicit consent |
| linkwarden | OAuth2/OIDC | explicit consent |
| Matrix | OAuth2/OIDC | implicit consent |
| wrongmove | OAuth2/OIDC | implicit consent |

## Groups (9)
| Group | Parent | Superuser | Purpose |
|-------|--------|-----------|---------|
| Allow Login Users | -- | No | Parent group for login-permitted users |
| authentik Admins | -- | Yes | Full admin access |
| Headscale Users | Allow Login Users | No | VPN access |
| Home Server Admins | Allow Login Users | No | Server admin access |
| Wrongmove Users | Allow Login Users | No | Real-estate app access |
| kubernetes-admins | -- | No | K8s cluster-admin RBAC |
| kubernetes-power-users | -- | No | K8s power-user RBAC |
| kubernetes-namespace-owners | -- | No | K8s namespace-owner RBAC |
| Task Submitters | -- | No | Task submission access |

## Users (8 real)
| Username | Name | Type | Groups |
|----------|------|------|--------|
| akadmin | authentik Default Admin | internal | authentik Admins, Home Server Admins, Headscale Users |
| vbarzin@gmail.com | Viktor Barzin | internal | authentik Admins, Home Server Admins, Wrongmove Users, Headscale Users |
| emil.barzin@gmail.com | Emil Barzin | internal | Home Server Admins, Headscale Users |
| ancaelena98@gmail.com | Anca Milea | external | Wrongmove Users, Headscale Users |
| vabbit81@gmail.com | GHEORGHE Milea | external | Headscale Users |
| valentinakolevabarzina@gmail.com | Valentina | internal | Headscale Users |
| anca.r.cristian10@gmail.com | -- | internal | Wrongmove Users |
| kadir.tugan@gmail.com | Kadir | internal | Wrongmove Users |

## Login Sources
- **Google** (OAuth) -- user matching by identifier
- **GitHub** (OAuth) -- user matching by email_link
- **Facebook** (OAuth) -- user matching by email_link
- All sources use `invitation-enrollment` as enrollment flow (new users require invitation)

## Authorization Flows
- **Explicit consent** (`default-provider-authorization-explicit-consent`): Shows consent screen
- **Implicit consent** (`default-provider-authorization-implicit-consent`): Auto-redirects

## Invitation Enrollment Flow
Slug: `invitation-enrollment` | PK: `7d667321-2b02-4e16-8161-148078a8dac1`

New users can only sign up via invitation link. Admins generate single-use invite links.

### Stages (in order)
| Order | Stage | Type | Purpose |
|-------|-------|------|---------|
| 10 | invitation-validation | Invitation | Validates `?itoken=` parameter, blocks without valid token |
| 20 | enrollment-identification | Identification | Shows social login (Google/GitHub/Facebook) + passkey |
| 30 | enrollment-prompt | Prompt | Collects name and email (pre-filled from social login) |
| 40 | enrollment-user-write | User Write | Creates user in `Allow Login Users` group |
| 50 | enrollment-login | User Login | Auto-login after signup (policy: `invitation-group-assignment` adds user to target group from invitation `fixed_data.group`) |

### Invitation Management
Script: `.claude/scripts/authentik-invite.sh`

```bash
# Create invitation (single-use, no expiry)
./authentik-invite.sh create "Headscale Users"

# Create invitation with expiry
./authentik-invite.sh create "Wrongmove Users" --days 7

# Add user to group after enrollment
./authentik-invite.sh assign <username> "Headscale Users"

# List pending invitations
./authentik-invite.sh list
```

Invited users sign up via social login (Google/GitHub/Facebook) or passkey. No username/password enrollment.
The target group (e.g. "Headscale Users") is auto-assigned on enrollment via the `invitation-group-assignment` expression policy. The `assign` command is available for manual post-enrollment group changes.

## Cleanup Log (2026-03-13)
### Deleted Flows
- `enrollment-inviation` (typo) -- previous invitation attempt
- `headscale-authentication` -- not used by any provider
- `headscale-authorization` -- not used by any provider
- `default-enrollment-flow` -- password-based, unused
- `oauth-enrollment` -- replaced by invitation-enrollment

### Deleted Stages
- `enrollment-invitation`, `enrollment-invitation-write` (from old invitation flow)
- `invitation` (unbound)
- `default-enrollment-prompt-first`, `default-enrollment-prompt-second` (from default enrollment)
- `default-enrollment-user-write`, `default-enrollment-email-verification`, `default-enrollment-user-login`

### Deleted Groups
- `authentik Read-only` -- 0 users, unused role

### Deleted Policies
- `map github username to email` -- unbound
- `Map Google Attributes` -- unbound

### Deleted Roles
- `authentik Read-only` -- no group assignment

## Policy Fix (2026-04-06)
### Unbound brute-force-protection Policy
The `brute-force-protection` ReputationPolicy (PK: `ac98cb11-31d3-46ab-8883-bf51e6b09a60`, `check_username=True`, `check_ip=True`, `threshold=-5`) was bound to 3 authentication flows, causing "Flow does not apply to current user" for all unauthenticated users (no username to evaluate → failure_result=false → flow denied).

Removed bindings from:
- `default-authentication-flow` (PK: `34618cf3`) — username/password login
- `webauthn` (PK: `0b60c2a5`) — passkey login
- `default-source-authentication` (PK: via policybindingmodel `1a779f24`) — Google/GitHub/Facebook OAuth

Policy still exists with 0 bindings. If brute-force protection is needed, bind to the **password stage** (not the flow level).

## Session Duration (2026-05-01)

Pinned via Terraform in `stacks/authentik/`:

| Knob | Value | Surface | Effect |
|------|-------|---------|--------|
| `UserLoginStage.session_duration` on `default-authentication-login` | `weeks=4` | `authentik_stage_user_login.default_login` in `authentik_provider.tf` | Authenticated users stay logged in 4 weeks across browser restarts. No sliding refresh — resets on each login. |
| `AUTHENTIK_SESSIONS__UNAUTHENTICATED_AGE` (server + worker) | `hours=2` | `server.env` + `worker.env` in `modules/authentik/values.yaml` | Anonymous Django sessions (bots, healthcheckers, partial flows) are reaped within 2h instead of the 1d default. |

Notes:
- There is **no** `Brand.session_duration`; `UserLoginStage` is the only correct lever for authenticated session lifetime.
- Embedded outpost session storage moved from `/dev/shm` → Postgres table `authentik_providers_proxy_proxysession` in authentik 2025.10. The 2026-04-18 `/dev/shm`-fill outage class is no longer load-bearing in 2026.2.2; the `unauthenticated_age` cap is still the right lever for anonymous-session bloat from external monitors.
- `ProxyProvider.access_token_validity` and `remember_me_offset` stay UI-managed via `ignore_changes`.
- The `unauthenticated_age` env var is injected via `server.env` / `worker.env` (not `authentik.sessions.unauthenticated_age`) because we set `authentik.existingSecret.secretName: goauthentik`, which makes the chart skip rendering its own `AUTHENTIK_*` Secret. The `authentik.*` value block is therefore inert in this stack — anything new under `authentik.*` must use the `*.env` arrays instead. The same applies to the existing `authentik.cache.*`, `authentik.web.*`, `authentik.worker.*` blocks (currently inert; live values come from the orphaned, helm-keep-policy `goauthentik` Secret created by chart 2025.10.3 before `existingSecret` was introduced).
