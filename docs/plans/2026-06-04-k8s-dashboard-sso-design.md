# K8s Dashboard SSO via Authentik (oauth2-proxy) — Design

**Date:** 2026-06-04
**Status:** Approved (design)
**Author:** Viktor + Claude
**Scope:** Let namespace-owner users (e.g. gheorghe / `vabbit81`) open the
Kubernetes Dashboard at `https://k8s.viktorbarzin.me`, authenticate once with
their Authentik account, and manage their own namespace (inspect/edit
Deployments, read logs) with read-only visibility elsewhere — no second login,
no manually-pasted token.

---

## 1. Goal & Non-Goals

### Goal
A user in an Authentik `kubernetes-*` group browses to the dashboard, completes
the normal Authentik SSO redirect, and lands in a dashboard session whose
permissions are **their own** K8s RBAC (scoped by the OIDC `email`/`groups`
claims the apiserver already trusts). gheorghe gets full control of namespace
`vabbit81` and read-only cluster visibility.

### Non-Goals
- No change to the kube-apiserver OIDC flags (already configured).
- No change to the RBAC module or the `k8s_users` schema (gheorghe is already
  onboarded; his RoleBindings already exist).
- No change to the existing **CLI** OIDC flow (kubelogin against the public
  `kubernetes` client) used by viktor/anca — it must keep working untouched.
- Not replacing the dashboard (Headlamp et al. were considered and rejected).
- Not hardening/removing the existing static cluster-admin SA (tracked as an
  optional future item in §9, deliberately out of scope here to keep blast
  radius minimal and break-glass intact).

---

## 2. Current State (verified)

| Fact | Evidence |
|---|---|
| Dashboard deployed via Helm chart `kubernetes-dashboard` 7.12.0 in ns `kubernetes-dashboard`; fronted by `kubernetes-dashboard-kong-proxy` (HTTPS 443) | `stacks/k8s-dashboard/main.tf` |
| Ingress `k8s.viktorbarzin.me` currently `auth = "required"` (Authentik forward-auth) → kong-proxy. After auth, the dashboard only had a **static cluster-admin SA token** to talk to the apiserver — every authenticated user was effectively cluster-admin | `stacks/k8s-dashboard/main.tf` (ingress + `admin-user` CRB) |
| kube-apiserver already OIDC-configured: `--oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/kubernetes/`, `--oidc-client-id=kubernetes`, `--oidc-username-claim=email`, `--oidc-groups-claim=groups` | `stacks/rbac/modules/rbac/apiserver-oidc.tf` |
| Per-user RBAC already created from `k8s_users` (Vault `secret/platform`): namespace-owners get a `RoleBinding` to ClusterRole `admin` in their namespace + a cluster-wide read-only ClusterRoleBinding, keyed on **email** | `stacks/rbac/modules/rbac/main.tf` |
| gheorghe = `vabbit81`, email `vabbit81@gmail.com`, namespace `vabbit81`, role `namespace-owner`. Bindings `namespace-owner-vabbit81` + `oidc-ns-owner-readonly-vabbit81` exist | Vault `secret/platform → k8s_users` |
| Authentik is Terraform-managed (provider adopted 2026-04-18, Wave 6a). Proxy providers/outposts/guest flow live in `stacks/authentik/*.tf`. The `goauthentik/authentik` provider is available to every stack via central `terragrunt.hcl` | `stacks/authentik/authentik_provider.tf`, `guest.tf` |
| The existing `kubernetes` OIDC **application** is still UI-managed (no `client_id="kubernetes"` in the repo) — must not be disturbed | repo grep (no match) |
| `ingress_factory` `auth` enum + comment-convention guard (`scripts/check-ingress-auth-comments.py`) require a `# auth = "<tier>": …` comment above any `auth = "none"/"app"` line | `modules/kubernetes/ingress_factory/main.tf`, `infra/.claude/CLAUDE.md` |

The missing link is purely **token injection**: nothing today gives the
dashboard the *user's own* OIDC id_token, so the apiserver can't apply the
per-user RBAC that already exists.

---

## 3. Architecture

```
Browser
  → Cloudflare (proxied)
  → Traefik (ingress auth = "none"; oauth2-proxy is now the gate)
  → oauth2-proxy.kubernetes-dashboard.svc:4180
       ├─ no session → 302 → Authentik OIDC code-flow (+PKCE) → /oauth2/callback
       │     gated by a group policy: only kubernetes-{admins,power-users,namespace-owners}
       └─ session valid → proxies upstream + sets `Authorization: Bearer <id_token>`
  → kubernetes-dashboard-kong-proxy.svc:443  (UNCHANGED)
  → dashboard `api` → kube-apiserver (Bearer token)
       → OIDC validates: iss ✓, aud ⊇ {kubernetes} ✓, sig ✓
       → username = email, groups = groups claim
       → RBAC: namespace-owner-<user> (admin in their ns) + cluster read-only
```

**The entire change is additive + one ingress repoint.** New objects:
oauth2-proxy Deployment/Service, an Authentik OIDC application/provider + scope
mapping + group policy, and an ESO-synced secret. The ingress backend flips
from kong-proxy → oauth2-proxy and `auth` flips `required → none`.

---

## 4. Components

### 4.1 Authentik (Terraform, in `stacks/k8s-dashboard/`)

Follows the `stacks/authentik/guest.tf` pattern (provider block reads
`secret/authentik → tf_api_token` from Vault).

- `authentik_provider_oauth2 "k8s_dashboard"`:
  - `client_type = "confidential"`, `client_id = "k8s-dashboard"`,
    `client_secret` from Vault.
  - `allowed_redirect_uris = [{ matching_mode="strict",
    url="https://k8s.viktorbarzin.me/oauth2/callback" }]`.
  - `authorization_flow` = default implicit-consent (data source);
    `invalidation_flow` = default (data source).
  - `access_token_validity = "hours=1"`, `refresh_token_validity = "days=30"`.
  - `include_claims_in_id_token = true` (so the id_token carries `email` +
    `groups`; the apiserver reads the `email` claim for username regardless of
    `sub_mode`).
  - `property_mappings` = the default OIDC scope mappings (`openid`, `email`,
    `profile`) **plus** the goauthentik `groups` scope mapping **plus** the
    custom audience mapping below. (Resolved via `data
    authentik_property_mapping_provider_scope` lookups so we don't drop the
    standard claims.)
- `authentik_property_mapping_provider_scope "k8s_dashboard_aud"`:
  - `scope_name = "k8s-dashboard-audience"`,
    `expression = return {"aud": ["kubernetes", "k8s-dashboard"]}`.
  - Emits **both** audiences so the apiserver (`kubernetes`) and oauth2-proxy
    (`k8s-dashboard`) each find their own client id in `aud`.
- `authentik_application "k8s_dashboard"`: slug `k8s-dashboard`,
  `protocol_provider` = the oauth2 provider, `policy_engine_mode = "any"`.
- Group gate: `authentik_policy_expression "k8s_dashboard_groups"` →
  `return ak_is_group_member(request.user, name="kubernetes-admins") or
  ak_is_group_member(request.user, name="kubernetes-power-users") or
  ak_is_group_member(request.user, name="kubernetes-namespace-owners")`,
  bound to the application via `authentik_policy_binding`.

### 4.2 Vault + ESO

- Vault `secret/k8s-dashboard` (new): `oauth2_proxy_client_id`,
  `oauth2_proxy_client_secret`, `oauth2_proxy_cookie_secret` (32 random bytes,
  base64). The Authentik provider reads the same client id/secret so the two
  sides match.
- `ExternalSecret` in `stacks/k8s-dashboard/main.tf` → K8s Secret
  `oauth2-proxy` in ns `kubernetes-dashboard`. First-apply: target the
  ExternalSecret before the full apply (documented plan-time gotcha).

### 4.3 oauth2-proxy (Terraform, in `stacks/k8s-dashboard/`)

- Image `quay.io/oauth2-proxy/oauth2-proxy:v7.x` (pin a concrete tag; SHA-tag
  convention). `linux/amd64`.
- Deployment: 2 replicas (HA path), Recreate not needed (stateless), readiness
  `/ping`, requests 25m/64Mi, limit 128Mi. Standard `dns_config`
  `ignore_changes` (KYVERNO_LIFECYCLE_V1).
- Config (env `OAUTH2_PROXY_*` or args):
  - `provider=oidc`,
    `oidc_issuer_url=https://authentik.viktorbarzin.me/application/o/k8s-dashboard/`
  - `client_id`/`client_secret`/`cookie_secret` from the `oauth2-proxy` Secret
  - `redirect_url=https://k8s.viktorbarzin.me/oauth2/callback`
  - `upstreams=https://kubernetes-dashboard-kong-proxy.kubernetes-dashboard.svc.cluster.local:443`
  - `ssl_upstream_insecure_skip_verify=true` (kong self-signed cert)
  - `pass_authorization_header=true` (passes id_token to the dashboard)
  - `set_authorization_header=true` (belt-and-suspenders)
  - `oidc_extra_audience=kubernetes` (accept the apiserver audience too)
  - `scope=openid email profile groups offline_access`
  - `email_domains=*` (the Authentik group policy is the real gate)
  - `cookie_secure=true`, `cookie_domains=k8s.viktorbarzin.me`,
    `whitelist_domains=k8s.viktorbarzin.me`, `cookie_refresh=30m`,
    `cookie_expire=168h`
  - `reverse_proxy=true`, `skip_provider_button=true`
- Service `oauth2-proxy` (port 4180).

### 4.4 Ingress (edit existing in `stacks/k8s-dashboard/main.tf`)

- `service_name = "oauth2-proxy"`, `backend_protocol = "HTTP"`, `port = 4180`.
- `auth = "none"` with the mandatory comment:
  `# auth = "none": oauth2-proxy is the gate — it runs the Authentik OIDC
  code-flow and injects the user's id_token as Bearer for dashboard→apiserver
  auth. Group policy on the Authentik app restricts to kubernetes-* groups.`
- Keep `dns_type = "proxied"` and the homepage annotations.

---

## 5. The Audience Strategy (the crux) + Fallback

The apiserver is pinned to a single legacy `--oidc-client-id=kubernetes`; the
CLI uses the public `kubernetes` client. oauth2-proxy must be its own
confidential client (`k8s-dashboard`). A token with `aud=k8s-dashboard` alone
would be rejected by the apiserver; a token with `aud=kubernetes` alone would
be rejected by oauth2-proxy. **Resolution:** the Authentik scope mapping emits
`aud = ["kubernetes", "k8s-dashboard"]`; both validators do a membership check
and each finds its own id. `oidc_extra_audience=kubernetes` on oauth2-proxy is
an extra safety net in case Authentik's scope mapping *overrides* `aud` to a
single value rather than appending.

**Apply-time verification (blocking):** decode a freshly issued id_token and
assert `aud` contains both `kubernetes` and `k8s-dashboard`, and that `groups`
is present. If Authentik refuses to emit a multi-valued `aud` via scope
mapping, **fallback** (documented, not preferred): repoint oauth2-proxy at the
existing `kubernetes` client made confidential and add `--oidc-client-secret`
to the kubelogin setup script — this unifies the audience at the cost of
touching the CLI flow. We try the additive multi-aud path first precisely to
avoid that.

---

## 6. Data Flow — gheorghe end-to-end

1. `https://k8s.viktorbarzin.me` → Cloudflare → Traefik (auth=none) →
   oauth2-proxy.
2. No session → 302 to Authentik (`k8s-dashboard` client, code+PKCE).
3. Authentik runs the group policy: `vabbit81 ∈ kubernetes-namespace-owners` ✓.
   Issues id_token: `email=vabbit81@gmail.com`,
   `groups=[…,kubernetes-namespace-owners]`, `aud=[kubernetes,k8s-dashboard]`.
4. oauth2-proxy validates token (`k8s-dashboard ∈ aud`), sets session cookie,
   proxies to kong-proxy with `Authorization: Bearer <id_token>`.
5. kong-proxy → dashboard `api` → kube-apiserver with the Bearer token.
6. apiserver OIDC: `username=vabbit81@gmail.com`, groups from claim.
7. RBAC: `RoleBinding namespace-owner-vabbit81` (ClusterRole `admin`) in ns
   `vabbit81` + `ClusterRoleBinding oidc-ns-owner-readonly-vabbit81`.
8. Dashboard shows full control of `vabbit81`, read-only elsewhere — the goal.

No RBAC changes required; bindings already key on his email.

---

## 7. Testing

1. **Token shape (blocking):** decode an issued id_token; assert
   `aud ⊇ {kubernetes,k8s-dashboard}` and `groups` present.
2. **Admin:** viktor logs in → sees/edits everything (cluster-admin group).
3. **Namespace-owner:** gheorghe logs in → can edit Deployments / read logs in
   `vabbit81`; gets Forbidden creating resources in other namespaces; can view
   (read-only) cluster resources.
4. **No regression:** viktor/anca CLI `kubectl` (kubelogin → public
   `kubernetes` client) still works.
5. Browser checks driven via Playwright MCP; screenshot on failure.

---

## 8. Rollback

Single-commit revert of the ingress edit restores `service_name=kong-proxy`,
`backend_protocol=HTTPS`, `port=443`, `auth=required` → instant return to
Authentik forward-auth gating. oauth2-proxy + Authentik objects are additive
and inert once the ingress no longer points at them; they can be destroyed in a
follow-up. No apiserver, RBAC, data, or CLI changes to unwind.

---

## 9. Security Notes & Out-of-Scope Hardening

- The id_token only ever lives server-side (Bearer header oauth2-proxy→kong);
  the browser holds an opaque oauth2-proxy session cookie
  (secure/httponly/samesite-lax, scoped to `k8s.viktorbarzin.me`).
- Two gates: Authentik **group policy** (only `kubernetes-*` groups complete
  the flow) and apiserver **RBAC** (per-user, by email). Defense in depth.
- The `authentik_walloff` blackbox guard is for `auth=none` carve-outs that
  must NOT redirect to Authentik. The dashboard intentionally **does** redirect
  (via oauth2-proxy), so it is **not** added to that guard.
- **Out of scope (optional future hardening):** the existing static
  `admin-user` cluster-admin ClusterRoleBinding + SA remain. They predate this
  change and provide break-glass. Removing them (admins would rely on SSO +
  Vault `kubernetes/creds/dashboard-admin` + kubelogin) is a separate, reversible
  security decision the user can request later. Not done here to keep blast
  radius minimal.

---

## 10. Monitoring & Docs

- Uptime-Kuma external monitor auto-created (`dns_type=proxied` →
  `ingress_factory` adds the `external-monitor` label). No manual monitor.
- oauth2-proxy readiness probe on `/ping`.
- Docs updated in the **same commit**: `docs/architecture/authentication.md`
  (new OIDC app + dashboard SSO flow), `docs/architecture/multi-tenancy.md`
  (dashboard access path for namespace-owners),
  `.claude/reference/authentik-state.md` (new app/provider/scope-mapping),
  `.claude/reference/service-catalog.md` (k8s-dashboard auth posture), and the
  companion `2026-06-04-k8s-dashboard-sso-plan.md`.

---

## 11. Open Risks

| Risk | Mitigation |
|---|---|
| Authentik scope mapping overrides rather than appends `aud` | `oidc_extra_audience=kubernetes` + blocking apply-time token decode; fallback in §5 |
| Dashboard v7 ignores a pre-set Authorization header (known friction: kubernetes/dashboard #5105, #1213) | `pass_authorization_header` + `set_authorization_header`; validate in §7; kong forwards headers by default |
| ESO first-apply ordering | `terragrunt apply -target` the ExternalSecret first (documented plan-time pattern) |
| Single-master apiserver assumption (memory id=2484) | We don't touch apiserver flags; no new exposure |

---

## 12. ADDENDUM (2026-06-04) — As-built pivoted to Option B (apiserver multi-issuer)

Sections 4–5 above describe the *original* plan: a separate `k8s-dashboard`
confidential client whose token carries a dual `aud` so the apiserver (pinned
to `--oidc-client-id=kubernetes`) would accept it **without** an apiserver
change. **That approach does not work**, for a reason discovered during
implementation:

1. **The issuer is the binding constraint, not the audience.** Every Authentik
   OAuth2 application has its own per-slug issuer. A token from the
   `k8s-dashboard` app has `iss=…/o/k8s-dashboard/`, but the apiserver does an
   **exact issuer-string match** against its single configured issuer
   (`…/o/kubernetes/`). The dual-`aud` scope mapping is irrelevant — the token
   is rejected on issuer before audience is even considered.

2. **Apiserver OIDC was already silently broken.** Inspecting the live
   `kube-apiserver` static-pod manifest showed **no `--oidc-*` flags at all** —
   the kubeadm v1.34 upgrade had regenerated the manifest and dropped the
   flags the `rbac` stack's `null_resource` had injected (its content-hash
   trigger never re-fired). So OIDC apiserver auth was off cluster-wide.

3. **Reusing the `kubernetes` app (make it confidential) — rejected.** It would
   force distributing the now-confidential client secret to every CLI user via
   the **public** k8s-portal `/setup/script` endpoint (a leak), plus
   re-onboarding existing CLI users. Too invasive.

**As-built = Option B: structured `AuthenticationConfiguration` on the
apiserver trusting BOTH issuers.** `stacks/rbac/modules/rbac/apiserver-oidc.tf`
now writes `/etc/kubernetes/pki/auth-config.yaml`
(`apiserver.config.k8s.io/v1`) with two `jwt` issuers — `kubernetes`
(audience `kubernetes`, for the kubelogin CLI) and `k8s-dashboard` (audience
`k8s-dashboard`, for oauth2-proxy) — each mapping `username<-email` and
`groups<-groups` with empty prefixes (to match existing RBAC subjects). The
legacy `--oidc-*` flags are replaced by `--authentication-config=…`. The remote
script health-gates `/livez` and **auto-rolls-back** the manifest if the
single-master apiserver doesn't recover. The oauth2-proxy + `k8s-dashboard`
Authentik app from §4 are reused unchanged (the dual-`aud` mapping is now
harmless — issuer2 only requires `k8s-dashboard ∈ aud`).

This keeps the CLI flow 100% untouched (its own `kubernetes` issuer is one of
the two trusted issuers) and restores the apiserver OIDC that the kubeadm
upgrade had broken.

**Known drift (carried forward):** a future `kubeadm upgrade` will again
regenerate the manifest and drop `--authentication-config`. The
content-hash trigger won't auto-detect this. **Operational mitigation:
re-apply the `rbac` stack after every k8s control-plane upgrade** (add to the
upgrade runbook). The `rbac` provisioner needs `TF_VAR_ssh_private_key` (an SSH
key authorized on the master) — it is not wired from Vault yet.
