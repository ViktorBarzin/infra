# Authentik Current State

> Snapshot of applications, groups, users, and flows. Use `authentik` skill for management tasks.

## Applications (9)
| Application | Provider Type | Auth Flow |
|-------------|--------------|-----------|
| Cloudflare Access | OAuth2/OIDC | explicit consent |
| Domain wide catch all | Proxy (forward auth) | implicit consent |
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
| Allow Login Users | — | No | Parent group for login-permitted users |
| authentik Admins | — | Yes | Full admin access |
| authentik Read-only | — | No | Read-only access (has role) |
| Headscale Users | Allow Login Users | No | VPN access |
| Home Server Admins | Allow Login Users | No | Server admin access |
| Wrongmove Users | Allow Login Users | No | Real-estate app access |
| kubernetes-admins | — | No | K8s cluster-admin RBAC |
| kubernetes-power-users | — | No | K8s power-user RBAC |
| kubernetes-namespace-owners | — | No | K8s namespace-owner RBAC |

## Users (7 real)
| Username | Name | Type | Groups |
|----------|------|------|--------|
| akadmin | authentik Default Admin | internal | authentik Admins, Home Server Admins, Headscale Users |
| vbarzin@gmail.com | Viktor Barzin | internal | authentik Admins, Home Server Admins, Wrongmove Users, Headscale Users |
| emil.barzin@gmail.com | Emil Barzin | internal | Home Server Admins, Headscale Users |
| ancaelena98@gmail.com | Anca Milea | external | Wrongmove Users, Headscale Users |
| vabbit81@gmail.com | GHEORGHE Milea | external | Headscale Users |
| valentinakolevabarzina@gmail.com | Валентина Колева-Барзина | internal | Headscale Users |
| anca.r.cristian10@gmail.com | — | internal | Wrongmove Users |
| kadir.tugan@gmail.com | Kadir | internal | Wrongmove Users |

## Login Sources
- **Google** (OAuth) — user matching by identifier
- **GitHub** (OAuth) — user matching by email_link
- **Facebook** (OAuth) — user matching by email_link

## Authorization Flows
- **Explicit consent** (`default-provider-authorization-explicit-consent`): Shows consent screen
- **Implicit consent** (`default-provider-authorization-implicit-consent`): Auto-redirects
