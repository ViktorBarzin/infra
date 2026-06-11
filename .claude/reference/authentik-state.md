# Authentik Current State

> Snapshot of applications, groups, users, and flows. Use `authentik` skill for management tasks.

## Applications (11)
| Application | Provider Type | Auth Flow |
|-------------|--------------|-----------|
| Cloudflare Access | OAuth2/OIDC | implicit consent |
| Domain wide catch all | Proxy (forward auth) | implicit consent |
| Forgejo | OAuth2/OIDC | implicit consent |
| Grafana | OAuth2/OIDC | implicit consent |
| Headscale | OAuth2/OIDC | implicit consent |
| Immich | OAuth2/OIDC | implicit consent |
| Kubernetes | OAuth2/OIDC (public) | implicit consent |
| Kubernetes Dashboard | OAuth2/OIDC (confidential) | implicit consent |
| linkwarden | OAuth2/OIDC | implicit consent |
| Vault | OAuth2/OIDC | implicit consent |
| wrongmove | OAuth2/OIDC | implicit consent |

> **2026-06-10 — every provider now uses implicit consent.** Cloudflare
> Access (pk 9), Forgejo (20), Immich (1), Headscale (13), linkwarden (8)
> and Vault (53) were switched from
> `default-provider-authorization-explicit-consent` via the API (these
> providers are UI-managed, not in TF). All are first-party apps; the
> expiring consent screen (re-shown every 4 weeks per app) only slowed
> first-time signin.

> **Kubernetes Dashboard** (TF-managed in `stacks/k8s-dashboard/authentik.tf`):
> confidential client `k8s-dashboard`, built for seamless dashboard SSO via
> oauth2-proxy. **Currently IDLE** — the apiserver rejects all OIDC tokens (see
> `docs/plans/2026-06-04-k8s-dashboard-sso-design.md` §12), so the dashboard runs
> on forward-auth + token-paste instead and oauth2-proxy is unwired. Kept for a
> future SSO retry once apiserver OIDC is fixed.
>
> **admin-services-restriction** policy (TF-managed in
> `stacks/authentik/admin-services-restriction.tf`, adopted 2026-06-04): gates the
> 15 admin-only hostnames to `Home Server Admins`, with a carve-out admitting the
> `kubernetes-*` RBAC groups to `k8s.viktorbarzin.me` (dashboard login page).

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
| vabbit81@gmail.com | GHEORGHE Milea | external | Headscale Users, kubernetes-namespace-owners, sops-vabbit81 |
| valentinakolevabarzina@gmail.com | Valentina | internal | Headscale Users |
| anca.r.cristian10@gmail.com | -- | internal | Wrongmove Users |
| kadir.tugan@gmail.com | Kadir | internal | Wrongmove Users |

## Login Sources
- **Google** (OAuth) -- user matching by identifier
- **GitHub** (OAuth) -- user matching by email_link
- **Facebook** (OAuth) -- user matching by email_link
- All sources use `invitation-enrollment` as enrollment flow (new users require invitation)

## Authorization Flows
- **Explicit consent** (`default-provider-authorization-explicit-consent`): Shows consent screen — no provider uses it since 2026-06-10
- **Implicit consent** (`default-provider-authorization-implicit-consent`): Auto-redirects — used by ALL providers

## Authentication Flow (single-screen login, 2026-06-10)

`default-authentication-flow` bindings: identification (order 10) →
mfa-validation (order 30) → user-login (order 100). The identification
stage (`default-authentication-identification`, pk
`32aca5ab-106e-43f4-a4cc-4513d80e57f3`) has `password_stage` set to
`default-authentication-password`, so username + password render on ONE
screen (one round trip instead of two). The previously separate
password-stage binding at order 20 (pk `0fc677db-a23f-4ee7-8648-da342e14573b`)
was DELETED via the API — authentik requires removing it when the
identification stage embeds the password field. `password_stage` is pinned in
Terraform (`authentik_stage_identification.default_identification` in
`stacks/authentik/authentik_provider.tf`); all other stage fields stay
UI-managed via `ignore_changes`. Social-login buttons remain on the same
screen and bypass the password field, so Google/GitHub/Facebook users are
unaffected. If a future authentik upgrade/blueprint re-adds the order-20
binding, users would briefly see a second password prompt — delete the
binding again.

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
| `ProxyProvider.access_token_validity` on `Provider for Domain wide catch all` | `weeks=4` | `authentik_provider_proxy.catchall.access_token_validity` in `authentik_provider.tf` | Cookie `Max-Age` on `authentik_proxy_*` and `expires` on rows in `authentik_providers_proxy_proxysession`. Bumped 2026-05-10 from `hours=168`. **Bumping requires `kubectl rollout restart deploy/ak-outpost-authentik-embedded-outpost`** — the gorilla session store binds the value once at outpost startup; the 5-min provider refresh logs `"reusing existing session store"` and skips rebuild. |
| `AUTHENTIK_SESSIONS__UNAUTHENTICATED_AGE` (server + worker) | `hours=2` | `server.env` + `worker.env` in `modules/authentik/values.yaml` | Anonymous Django sessions (bots, healthcheckers, partial flows) are reaped within 2h instead of the 1d default. |

Notes:
- There is **no** `Brand.session_duration`; `UserLoginStage` is the only correct lever for authenticated session lifetime.
- Embedded outpost session storage: PostgreSQL table `authentik_providers_proxy_proxysession` in authentik 2025.10+ (PR #16628), but **only when `IsEmbedded()` returns true** (i.e. `Outpost.managed == "goauthentik.io/outposts/embedded"`). Our outpost record had `managed=null` until 2026-05-10, which silently kept it on the gorilla `FilesystemStore` at `/dev/shm` (TMPDIR) and re-exposed the 2026-04-18 mismatched-session-ID class on every pod restart. Fix landed 2026-05-10: see `authentik_outpost.embedded` in `authentik_provider.tf` and post-mortem `2026-04-18-authentik-outpost-shm-full.md`.
- The proxy outpost service has a known goauthentik 2026.2.2 bug (`internal/outpost/controllers/k8s/service.py:52`): for embedded outposts the controller sets the Service selector to `app.kubernetes.io/name=authentik` (the server pods), not `authentik-outpost-proxy`. We work around it via a `kubernetes_json_patches.service` patch on the outpost record (replaces `/spec/selector` with the outpost's own labels). Without this, endpoints are empty and Traefik forward-auth fails over to the Basic Auth realm `Emergency Access`.
- The standalone embedded-outpost deployment needs `AUTHENTIK_POSTGRESQL__{HOST,PORT,USER,PASSWORD,NAME}` env vars to reach the dbaas cluster — codified via `kubernetes_json_patches.deployment` envFrom the shared `goauthentik` Secret. The `app.kubernetes.io/component=server` pod label is also injected via JSON patch (matches the `component:server` half of the Service selector that the controller adds for embedded outposts).
- `ProxyProvider.remember_me_offset` stays UI-managed via `ignore_changes`.
- The Authentik provider's resource schema does **not** expose the `Outpost.managed` field. We rely on TF's "write only fields it knows about" semantic: the server-set `goauthentik.io/outposts/embedded` value is preserved across applies because Terraform never writes `managed`. Don't change the resource provider schema expectations without verifying this assumption holds.
- ALL tuned env vars are injected via `server.env` / `worker.env` (not the `authentik.*` values block) because we set `authentik.existingSecret.secretName: goauthentik`, which makes the chart skip rendering its own `AUTHENTIK_*` Secret. The `authentik.*` value block is therefore inert in this stack — anything new under `authentik.*` must use the `*.env` arrays instead. Live base values come from the orphaned, helm-keep-policy `goauthentik` Secret created by chart 2025.10.3 before `existingSecret` was introduced. **2026-06-10:** the previously-inert tuning (`AUTHENTIK_WEB__WORKERS=3`, `AUTHENTIK_WEB__THREADS=4`, `AUTHENTIK_CACHE__TIMEOUT_FLOWS=1800`, `AUTHENTIK_CACHE__TIMEOUT_POLICIES=900`, `AUTHENTIK_POSTGRESQL__CONN_MAX_AGE=60`, `AUTHENTIK_POSTGRESQL__CONN_HEALTH_CHECKS=true`, worker `AUTHENTIK_WORKER__THREADS=4`) was moved into the env arrays and is now actually live — before that, pods silently ran defaults (2 gunicorn workers, 300s caches, no persistent DB conns).
- **Outpost (2026-06-10):** `log_level=info` (was `trace` — per-request overhead on the forward-auth hot path) and `kubernetes_replicas=2` (was 1 — single-pod hot path; safe since proxy sessions live in Postgres). Both in `authentik_outpost.embedded` config.
- **Image tag is PINNED in values (`global.image.tag`), 2026-06-10:** Keel moves the authentik image between chart releases, while helm derives the tag from the chart appVersion — an unpinned helm apply silently DOWNGRADES live pods (caused the 2026-06-10 boot storm + shared-PG failover; see `docs/post-mortems/2026-06-10-authentik-downgrade-boot-storm.md`). Before touching this chart, check the live image tag and refresh the pin.
- **Liveness budget (2026-06-10):** `server.livenessProbe` = 6×10s, 5s timeout (chart default 3×10s/3s kill-loops pods that queue on the DB migration advisory lock during rolling restarts).
- **PgBouncer (2026-06-10):** `idle_transaction_timeout=300` reaps ghost `idle in transaction` sessions (a killed pod mid-migration otherwise holds the migration advisory lock forever, serializing all boots); the deployment carries a config-checksum annotation so ini changes roll the pods. Do NOT set `AUTHENTIK_POSTGRESQL__CONN_MAX_AGE` — session-mode PgBouncer pins persistent conns 1:1 (pool saturation).
- **Static assets (2026-06-10):** a second `ingress_factory` (`module.ingress-static`, path `/static` on the authentik host) attaches the `authentik-static-cache-headers` middleware → `Cache-Control: public, max-age=31536000, immutable`. Authentik itself serves no max-age; assets are version-fingerprinted so immutable is safe. Mainly helps split-horizon internal users (no Cloudflare edge cache on the direct path).

## Upgrade Validation Checklist

Run after **any** of these:
- Authentik chart version bump in `stacks/authentik/modules/authentik/main.tf` (the `version = "..."` line on `helm_release.authentik`).
- `goauthentik/authentik` Terraform provider version bump.
- Outpost pod recreation (kured reboot, eviction, manual `rollout restart`, scheduler move).

The fragile surfaces are the `kubernetes_json_patches` and the `Outpost.managed` field — both rely on assumptions that can silently break across upgrades. The checklist exercises the same path the alerts watch, so it doubles as a smoke test for the alerts.

```bash
# 1. Service routes to the outpost pods (NOT the server pods).
#    Empty endpoints => auth-proxy fallback fires; expected: TWO pod IPs
#    (kubernetes_replicas=2 since 2026-06-10), ports 9000/9300/9443.
kubectl -n authentik get endpoints ak-outpost-authentik-embedded-outpost

# 2. Service selector still excludes the server pods. Expected: includes
#    `app.kubernetes.io/name: authentik-outpost-proxy`. If it flips to
#    `name: authentik`, the goauthentik upstream bug came back or our
#    JSON patch was unset.
kubectl -n authentik get svc ak-outpost-authentik-embedded-outpost -o jsonpath='{.spec.selector}'

# 3. Outpost mode + session backend. Expected log lines on startup:
#      {"embedded":true,"event":"Outpost mode",...}
#      {"event":"using PostgreSQL session backend",...}
#    If embedded=false or `using filesystem session backend`, the postgres
#    fix is broken — likely `Outpost.managed` got cleared, or the upstream
#    schema started exposing `managed` and TF reset it.
kubectl -n authentik logs deploy/ak-outpost-authentik-embedded-outpost | grep -E '"Outpost mode"|"session backend"' | head -3

# 4. /dev/shm is essentially empty (postgres backend = no filesystem use).
#    A row count > a few dozen indicates filesystem fallback is firing.
kubectl -n authentik exec deploy/ak-outpost-authentik-embedded-outpost -- sh -c 'df -h /dev/shm; ls /dev/shm | wc -l'

# 5. Postgres session table is growing with traffic. Expected: rows with
#    `expires` ~28 days out (matches access_token_validity = weeks=4).
kubectl -n authentik exec deploy/goauthentik-server -- ak shell -c "
from django.db import connection; c = connection.cursor()
c.execute('SELECT COUNT(*), MAX(expires) FROM authentik_providers_proxy_proxysession')
print(c.fetchone())"

# 6. Edge auth flow: should be 302 → authentik. NOT 401 with WWW-Authenticate.
curl -sS -o /dev/null -D - 'https://terminal.viktorbarzin.me/' -H 'User-Agent: Mozilla/5.0' \
  | grep -iE '^HTTP|^location|x-auth-fallback|www-authenticate'

# 7. Terraform plan-to-zero on the whole authentik stack.
( cd stacks/authentik && /home/wizard/code/infra/scripts/tg plan ) | grep -E 'No changes|Plan:'
```

Steps 1, 3, 6 cover the failure modes the Prometheus alerts trigger on (`AuthentikForwardAuthFallbackActive`, `AuthentikOutpostForwardAuth400Spike`). Steps 4 and 5 cover the silent-regression case (filesystem fallback) where the alerts don't fire but the system loses its postgres-backed session persistence on the next pod restart.

If step 2 shows the controller restored `app.kubernetes.io/name=authentik`, watch goauthentik/authentik issue tracker for fixes around `internal/outpost/controllers/k8s/service.py:52` — the upstream patch might let us drop our `kubernetes_json_patches.service` workaround.
