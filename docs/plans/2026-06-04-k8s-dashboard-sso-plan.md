# K8s Dashboard SSO via Authentik (oauth2-proxy) — Implementation Plan

> **⚠️ AS-BUILT DIVERGED (2026-06-04).** Tasks 2–3 (oauth2-proxy + `k8s-dashboard`
> Authentik app) shipped as written, but the audience strategy here is WRONG: the
> apiserver matches the token **issuer** exactly, and a separate app has a
> different per-slug issuer — so the dual-`aud` trick can't avoid an apiserver
> change. The implementation pivoted to **Option B**: a structured multi-issuer
> `AuthenticationConfiguration` on the apiserver (`stacks/rbac`). See the
> **ADDENDUM (§12)** in `2026-06-04-k8s-dashboard-sso-design.md` for the as-built.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let namespace-owner users (e.g. gheorghe / `vabbit81`) open `https://k8s.viktorbarzin.me`, log in once with Authentik, and manage their own namespace in the Kubernetes Dashboard under their existing per-user RBAC.

**Architecture:** Deploy oauth2-proxy in the `kubernetes-dashboard` namespace in front of the existing `kong-proxy`. It runs the Authentik OIDC code-flow and injects the user's id_token as a `Bearer` header so the apiserver applies the per-user RBAC that already exists. A new confidential Authentik OIDC client (`k8s-dashboard`) plus a custom scope mapping emits `aud = ["kubernetes","k8s-dashboard"]`, satisfying both the apiserver and oauth2-proxy without touching the existing CLI (`kubernetes` public client). The change is additive; the only mutation to existing state is one ingress repoint, instantly revertible.

**Tech Stack:** Terraform/Terragrunt, Authentik (`goauthentik/authentik` TF provider), oauth2-proxy v7, External Secrets Operator, Vault KV, Kubernetes Dashboard v7 (Kong).

**Design doc:** `docs/plans/2026-06-04-k8s-dashboard-sso-design.md`

---

## Conventions for every apply step

- **Auth first:** `vault login -method=oidc` (humans) before any `scripts/tg`.
- **Presence claim before each apply** (CLAUDE.md mandatory rule):
  `~/code/scripts/presence claim service:k8s-dashboard --purpose "dashboard SSO via oauth2-proxy"`
  and `~/code/scripts/presence claim stack:k8s-dashboard --purpose "..."`. Release on completion.
- **Apply wrapper:** run from inside the stack dir: `cd stacks/k8s-dashboard && ../../scripts/tg <plan|apply>`. `scripts/tg` handles PG-backend creds and runs the ingress-auth comment guard.
- **Never** `kubectl apply/edit` as final state — Terraform only.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `stacks/k8s-dashboard/authentik.tf` | **Create** | `provider "authentik"` block + OIDC provider, custom audience scope mapping, application, group-restriction policy + binding |
| `stacks/k8s-dashboard/oauth2_proxy.tf` | **Create** | ExternalSecret → `oauth2-proxy` Secret, oauth2-proxy Deployment + Service |
| `stacks/k8s-dashboard/main.tf` | **Modify** | Repoint the dashboard ingress from `kong-proxy` → `oauth2-proxy`, flip `auth` to `none` |
| `docs/architecture/authentication.md` | **Modify** | Document the new OIDC app + dashboard SSO flow |
| `docs/architecture/multi-tenancy.md` | **Modify** | Document dashboard access path for namespace-owners |
| `.claude/reference/authentik-state.md` | **Modify** | Record the new app/provider/scope-mapping |
| `.claude/reference/service-catalog.md` | **Modify** | Update k8s-dashboard auth posture |

The `authentik` provider is already in every stack's generated `required_providers` (root `terragrunt.hcl` → `generate "k8s_providers"`). We only add the `provider "authentik"` config block (reads the API token from Vault `secret/authentik → tf_api_token`).

---

## Task 1: Vault secret for oauth2-proxy + Authentik client

**Files:** none (Vault KV state).

- [ ] **Step 1: Authenticate to Vault**

Run:
```bash
vault login -method=oidc
```
Expected: `Success! You are now authenticated.`

- [ ] **Step 2: Generate the three secret values**

Run:
```bash
CLIENT_ID="k8s-dashboard"
CLIENT_SECRET="$(openssl rand -hex 32)"
COOKIE_SECRET="$(openssl rand -base64 32 | tr -d '\n')"   # 32 bytes, base64 — required length for AES cookie
echo "client_id=$CLIENT_ID"; echo "client_secret set"; echo "cookie_secret set"
```
Expected: prints `client_id=k8s-dashboard` and confirmations. `COOKIE_SECRET` must decode to exactly 16/24/32 bytes (32 base64 chars from `rand -base64 32` → 32 bytes ✓).

- [ ] **Step 3: Write the secret to Vault**

Run:
```bash
VAULT_ADDR=https://vault.viktorbarzin.me vault kv put secret/k8s-dashboard \
  oauth2_proxy_client_id="$CLIENT_ID" \
  oauth2_proxy_client_secret="$CLIENT_SECRET" \
  oauth2_proxy_cookie_secret="$COOKIE_SECRET"
```
Expected: `Success! Data written to: secret/data/k8s-dashboard`.

- [ ] **Step 4: Verify**

Run:
```bash
VAULT_ADDR=https://vault.viktorbarzin.me vault kv get -field=oauth2_proxy_client_id secret/k8s-dashboard
```
Expected: `k8s-dashboard`.

No commit (Vault state, not git).

---

## Task 2: Authentik OIDC application (additive — no user impact)

**Files:**
- Create: `stacks/k8s-dashboard/authentik.tf`

- [ ] **Step 1: Create `stacks/k8s-dashboard/authentik.tf`**

```hcl
# -----------------------------------------------------------------------------
# Authentik OIDC application for the Kubernetes Dashboard (via oauth2-proxy).
#
# Confidential client `k8s-dashboard`. A custom scope mapping emits
# aud = ["kubernetes","k8s-dashboard"] so BOTH the kube-apiserver
# (--oidc-client-id=kubernetes) and oauth2-proxy (client_id=k8s-dashboard)
# accept the id_token. The existing UI-managed `kubernetes` public client
# used by the kubelogin CLI is untouched.
#
# Provider token: Vault secret/authentik -> tf_api_token (same as
# stacks/authentik/authentik_provider.tf).
# -----------------------------------------------------------------------------

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "vault_kv_secret_v2" "k8s_dashboard" {
  mount = "secret"
  name  = "k8s-dashboard"
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# Default OIDC scope mappings. `profile` carries the `groups` claim in
# Authentik's default expression, which the apiserver reads via
# --oidc-groups-claim=groups. offline_access enables refresh tokens.
data "authentik_property_mapping_provider_scope" "defaults" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-offline_access",
  ]
}

# Custom scope mapping that overrides the audience. It only fires when the
# client REQUESTS this scope, so oauth2-proxy must include
# `k8s-dashboard-audience` in its --scope (see oauth2_proxy.tf).
resource "authentik_property_mapping_provider_scope" "k8s_dashboard_aud" {
  name       = "k8s-dashboard audience"
  scope_name = "k8s-dashboard-audience"
  expression = "return {\"aud\": [\"kubernetes\", \"k8s-dashboard\"]}"
}

resource "authentik_provider_oauth2" "k8s_dashboard" {
  name          = "k8s-dashboard"
  client_id     = data.vault_kv_secret_v2.k8s_dashboard.data["oauth2_proxy_client_id"]
  client_secret = data.vault_kv_secret_v2.k8s_dashboard.data["oauth2_proxy_client_secret"]
  client_type   = "confidential"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://k8s.viktorbarzin.me/oauth2/callback"
    },
  ]

  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true

  property_mappings = concat(
    data.authentik_property_mapping_provider_scope.defaults.ids,
    [authentik_property_mapping_provider_scope.k8s_dashboard_aud.id],
  )
}

resource "authentik_application" "k8s_dashboard" {
  name              = "Kubernetes Dashboard"
  slug              = "k8s-dashboard"
  protocol_provider = authentik_provider_oauth2.k8s_dashboard.id
  meta_launch_url   = "https://k8s.viktorbarzin.me"
  policy_engine_mode = "any"
}

# Restrict who can complete the OIDC flow to the K8s RBAC groups.
resource "authentik_policy_expression" "k8s_dashboard_groups" {
  name       = "k8s-dashboard-group-access"
  expression = <<-EOT
    return (
        ak_is_group_member(request.user, name="kubernetes-admins")
        or ak_is_group_member(request.user, name="kubernetes-power-users")
        or ak_is_group_member(request.user, name="kubernetes-namespace-owners")
    )
  EOT
}

resource "authentik_policy_binding" "k8s_dashboard_groups" {
  target = authentik_application.k8s_dashboard.uuid
  policy = authentik_policy_expression.k8s_dashboard_groups.id
  order  = 0
}
```

- [ ] **Step 2: Plan**

Run: `cd stacks/k8s-dashboard && ../../scripts/tg plan`
Expected: plan adds `authentik_property_mapping_provider_scope.k8s_dashboard_aud`, `authentik_provider_oauth2.k8s_dashboard`, `authentik_application.k8s_dashboard`, `authentik_policy_expression.k8s_dashboard_groups`, `authentik_policy_binding.k8s_dashboard_groups`. **No changes to existing resources** (kong-proxy, ingress untouched).

- [ ] **Step 3: Claim presence, then apply**

Run:
```bash
~/code/scripts/presence claim stack:k8s-dashboard --purpose "add Authentik OIDC app for dashboard SSO"
cd stacks/k8s-dashboard && ../../scripts/tg apply --non-interactive
```
Expected: 5 resources added, 0 changed, 0 destroyed.

- [ ] **Step 4: Verify the application exists in Authentik**

Run:
```bash
curl -s -H "Authorization: Bearer $(VAULT_ADDR=https://vault.viktorbarzin.me vault kv get -field=tf_api_token secret/authentik)" \
  "https://authentik.viktorbarzin.me/api/v3/core/applications/?slug=k8s-dashboard" | jq '.results[].slug'
```
Expected: `"k8s-dashboard"`.

- [ ] **Step 5: Commit**

```bash
git add stacks/k8s-dashboard/authentik.tf
git commit -m "feat(k8s-dashboard): add Authentik OIDC app for dashboard SSO"
git push origin master
```

---

## Task 3: oauth2-proxy Deployment + Service (additive — still no cutover)

**Files:**
- Create: `stacks/k8s-dashboard/oauth2_proxy.tf`

- [ ] **Step 1: Create `stacks/k8s-dashboard/oauth2_proxy.tf`**

```hcl
# -----------------------------------------------------------------------------
# oauth2-proxy: runs the Authentik OIDC code-flow and injects the user's
# id_token as `Authorization: Bearer` upstream to kong-proxy, so the dashboard
# talks to the apiserver AS THE USER (per-user RBAC applies).
# -----------------------------------------------------------------------------

resource "kubernetes_manifest" "oauth2_proxy_externalsecret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "oauth2-proxy"
      namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "oauth2-proxy", creationPolicy = "Owner" }
      data = [
        { secretKey = "client-id", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_client_id" } },
        { secretKey = "client-secret", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_client_secret" } },
        { secretKey = "cookie-secret", remoteRef = { key = "k8s-dashboard", property = "oauth2_proxy_cookie_secret" } },
      ]
    }
  }
}

locals {
  oauth2_proxy_upstream = "https://kubernetes-dashboard-kong-proxy.kubernetes-dashboard.svc.cluster.local:443"
}

resource "kubernetes_deployment" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    labels    = { app = "oauth2-proxy" }
  }

  spec {
    replicas = 2
    selector { match_labels = { app = "oauth2-proxy" } }

    template {
      metadata { labels = { app = "oauth2-proxy" } }
      spec {
        container {
          name  = "oauth2-proxy"
          image = "quay.io/oauth2-proxy/oauth2-proxy:v7.7.1"
          args = [
            "--http-address=0.0.0.0:4180",
            "--provider=oidc",
            "--oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/k8s-dashboard/",
            "--redirect-url=https://k8s.viktorbarzin.me/oauth2/callback",
            "--upstream=${local.oauth2_proxy_upstream}",
            "--ssl-upstream-insecure-skip-verify=true",
            "--scope=openid email profile offline_access k8s-dashboard-audience",
            "--oidc-extra-audience=kubernetes",
            "--pass-authorization-header=true",
            "--set-authorization-header=true",
            "--pass-access-token=true",
            "--email-domain=*",
            "--insecure-oidc-allow-unverified-email=true",
            "--cookie-secure=true",
            "--cookie-domain=k8s.viktorbarzin.me",
            "--whitelist-domain=k8s.viktorbarzin.me",
            "--cookie-refresh=30m",
            "--cookie-expire=168h",
            "--code-challenge-method=S256",
            "--reverse-proxy=true",
            "--skip-provider-button=true",
          ]
          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from { secret_key_ref { name = "oauth2-proxy", key = "client-id" } }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from { secret_key_ref { name = "oauth2-proxy", key = "client-secret" } }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from { secret_key_ref { name = "oauth2-proxy", key = "cookie-secret" } }
          }
          port { container_port = 4180 }
          readiness_probe {
            http_get {
              path = "/ping"
              port = 4180
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          resources {
            requests = { cpu = "25m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  spec {
    selector = { app = "oauth2-proxy" }
    port {
      port        = 4180
      target_port = 4180
    }
  }
}
```

- [ ] **Step 2: First-apply the ExternalSecret only (plan-time-secret gotcha)**

Run:
```bash
cd stacks/k8s-dashboard && ../../scripts/tg apply --non-interactive \
  -target=kubernetes_manifest.oauth2_proxy_externalsecret
```
Expected: 1 resource added.

- [ ] **Step 3: Verify the K8s Secret materialized**

Run:
```bash
kubectl get secret oauth2-proxy -n kubernetes-dashboard -o jsonpath='{.data.client-id}' | base64 -d
```
Expected: `k8s-dashboard`.

- [ ] **Step 4: Full apply (deployment + service)**

Run: `cd stacks/k8s-dashboard && ../../scripts/tg apply --non-interactive`
Expected: `kubernetes_deployment.oauth2_proxy` + `kubernetes_service.oauth2_proxy` added, 0 changed.

- [ ] **Step 5: Verify oauth2-proxy is healthy** (background watch, no `sleep`)

Run:
```bash
kubectl get pods -n kubernetes-dashboard -l app=oauth2-proxy -w
```
Expected: 2/2 pods `Running`, readiness passing. Then check logs for clean OIDC discovery:
```bash
kubectl logs -n kubernetes-dashboard -l app=oauth2-proxy --tail=30
```
Expected: `OAuthProxy configured for OpenID Connect Client ID: k8s-dashboard` and no discovery errors. (The ingress still points at kong-proxy; nothing user-facing changed yet.)

- [ ] **Step 6: Commit**

```bash
git add stacks/k8s-dashboard/oauth2_proxy.tf
git commit -m "feat(k8s-dashboard): deploy oauth2-proxy (not yet wired to ingress)"
git push origin master
```

---

## Task 4: Cutover — repoint ingress to oauth2-proxy

This is the only step that changes existing behavior. Rollback = revert this commit.

**Files:**
- Modify: `stacks/k8s-dashboard/main.tf` (the `module "ingress"` block, currently around `main.tf:92-111`)

- [ ] **Step 1: Edit the ingress module block**

Replace the existing `module "ingress"` block in `stacks/k8s-dashboard/main.tf` with:

```hcl
module "ingress" {
  source       = "../../modules/kubernetes/ingress_factory"
  namespace    = kubernetes_namespace.k8s-dashboard.metadata[0].name
  name         = "kubernetes-dashboard"
  service_name = "oauth2-proxy"
  host         = "k8s"
  dns_type     = "proxied"
  tls_secret_name = var.tls_secret_name
  # auth = "none": oauth2-proxy is the gate — it runs the Authentik OIDC
  # code-flow and injects the user's id_token as Bearer for dashboard->apiserver
  # auth. A group policy on the Authentik app restricts access to the
  # kubernetes-* RBAC groups. See docs/plans/2026-06-04-k8s-dashboard-sso-design.md.
  auth             = "none"
  backend_protocol = "HTTP"
  port             = 4180
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Kubernetes Dashboard"
    "gethomepage.dev/description"  = "Cluster dashboard"
    "gethomepage.dev/icon"         = "kubernetes-dashboard.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}
```

- [ ] **Step 2: Plan (the comment guard runs here)**

Run: `cd stacks/k8s-dashboard && ../../scripts/tg plan`
Expected: the ingress `Service`/middleware updates in place (kong-proxy→oauth2-proxy, drops the Authentik forward-auth middleware). `scripts/check-ingress-auth-comments.py` passes (the `# auth = "none": …` comment is present). No resource destroyed/recreated beyond the ingress objects.

- [ ] **Step 3: Apply the cutover**

Run: `cd stacks/k8s-dashboard && ../../scripts/tg apply --non-interactive`
Expected: ingress resources updated; apply succeeds.

- [ ] **Step 4: VERIFY THE AUDIENCE (blocking gate)**

Log in once in a browser to `https://k8s.viktorbarzin.me` as `viktor`. Capture the
id_token the dashboard sends to the apiserver: open browser devtools → Network →
click any `/api/v1/...` request → Request Headers → copy the value of
`Authorization` (the part after `Bearer `). Decode its claims:
```bash
JWT='<paste-token-here>'
echo "$JWT" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{aud, email, groups}'
```
Expected: `aud` contains **both** `"kubernetes"` and `"k8s-dashboard"`, `email` is set
(e.g. `viktor@viktorbarzin.me`), and `groups` is a non-empty list.

**If `aud` does NOT contain `kubernetes`** → the scope-mapping audience override didn't
take. STOP, revert (Step 7 rollback) so the dashboard returns to forward-auth, then
apply the §5 design fallback (reuse the `kubernetes` client as confidential +
add `--oidc-client-secret` to the kubelogin setup script). Do not leave the cutover
live with a broken audience — users would get apiserver 401s.

- [ ] **Step 5: VERIFY end-to-end RBAC** (Playwright MCP; screenshot on failure)

  - As **viktor** (admin): dashboard lists all namespaces; can view/edit any Deployment. ✅
  - As **gheorghe** (`vabbit81`): switch to namespace `vabbit81` → can view + edit Deployments, read pod logs; attempting to create a resource in another namespace returns `Forbidden`. ✅
  - Unauthenticated/other user: Authentik denies at the group policy (no dashboard session issued). ✅

- [ ] **Step 6: VERIFY CLI regression (must still work, untouched)**

Run (as viktor, existing kubeconfig):
```bash
kubectl --context=<oidc-context> get nodes
```
Expected: succeeds exactly as before (the public `kubernetes` client + kubelogin path is unchanged).

- [ ] **Step 7: Commit** (rollback = `git revert` this commit + re-apply)

```bash
git add stacks/k8s-dashboard/main.tf
git commit -m "feat(k8s-dashboard): cut over ingress to oauth2-proxy SSO

Dashboard now authenticates users via Authentik (oauth2-proxy) and applies
each user's own RBAC. Rollback: revert this commit + scripts/tg apply."
git push origin master
```

- [ ] **Step 8: Release presence claims**

```bash
~/code/scripts/presence release stack:k8s-dashboard
~/code/scripts/presence release service:k8s-dashboard
```

---

## Task 5: Documentation (same logical change set)

**Files:**
- Modify: `docs/architecture/authentication.md`
- Modify: `docs/architecture/multi-tenancy.md`
- Modify: `.claude/reference/authentik-state.md`
- Modify: `.claude/reference/service-catalog.md`

- [ ] **Step 1: `docs/architecture/authentication.md`**

  - In the "OIDC Applications" table, add a row: `Kubernetes Dashboard | OIDC (confidential, via oauth2-proxy) | Dashboard SSO with per-user RBAC`.
  - Add a subsection "Kubernetes Dashboard SSO" describing the oauth2-proxy → kong-proxy → apiserver flow, the dual-audience (`kubernetes` + `k8s-dashboard`) scope mapping, and the group-restriction policy. Note the dashboard ingress is `auth = "none"` because oauth2-proxy is the gate (not a regression of the forward-auth default).

- [ ] **Step 2: `docs/architecture/multi-tenancy.md`**

  - In "User Setup (Self-Service)", add that namespace-owners can also use the **web dashboard** at `k8s.viktorbarzin.me` (Authentik SSO → their namespace RBAC), in addition to kubectl.

- [ ] **Step 3: `.claude/reference/authentik-state.md`**

  - Record the new application `Kubernetes Dashboard` (slug `k8s-dashboard`), confidential provider `k8s-dashboard`, custom scope mapping `k8s-dashboard audience` (scope `k8s-dashboard-audience`, sets dual `aud`), and the group-access policy/binding. Note these are TF-managed in `stacks/k8s-dashboard/authentik.tf`.

- [ ] **Step 4: `.claude/reference/service-catalog.md`**

  - Update the k8s-dashboard entry: auth posture is now oauth2-proxy OIDC SSO (was Authentik forward-auth + static cluster-admin SA), per-user RBAC.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture/authentication.md docs/architecture/multi-tenancy.md \
  .claude/reference/authentik-state.md .claude/reference/service-catalog.md
git commit -m "docs(k8s-dashboard): document dashboard SSO + per-user RBAC [ci skip]"
git push origin master
```

---

## Self-Review notes (coverage vs. design)

- Design §4.1 Authentik app → Task 2. §4.2 Vault+ESO → Task 1 + Task 3 Step 1-3. §4.3 oauth2-proxy → Task 3. §4.4 ingress → Task 4.
- Design §5 audience strategy + apply-time verification + fallback → Task 4 Step 4 (blocking gate).
- Design §7 testing → Task 4 Steps 5-6. §8 rollback → Task 4 Step 7. §10 docs → Task 5.
- Out-of-scope (design §9): static cluster-admin SA intentionally NOT touched — no task, by design.

## Known integration risks (watch during Task 4)

- **Dashboard v7 ignoring a pre-set Authorization header** (kubernetes/dashboard #5105, #1213): if the dashboard still shows its token-login page after SSO, confirm `--pass-authorization-header=true` and that kong forwards the header; the dashboard `api` component uses the bearer for apiserver calls. Validate in Task 4 Step 5.
- **Scope mapping audience override** (primary risk): mitigated by the blocking decode in Task 4 Step 4 + the documented fallback.
