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
| 50 | enrollment-login | User Login | Auto-login after signup |

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
