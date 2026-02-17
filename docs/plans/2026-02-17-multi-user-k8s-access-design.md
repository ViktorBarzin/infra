# Multi-User Kubernetes Access Design

**Date**: 2026-02-17
**Status**: Approved

## Problem

The cluster uses a single `kubernetes-admin` client certificate for all access. There is no way to:
- Give different users different levels of access
- Track who performed which actions
- Enforce resource limits per user
- Onboard new users without sharing admin credentials

## Decision

Native OIDC authentication on the kube-apiserver using Authentik as the identity provider, with Terraform-managed RBAC and a self-service Svelte portal for user onboarding.

### Alternatives Considered

1. **Pinniped (Concierge + Supervisor)**: Avoids API server changes but adds two components to maintain. Requires Pinniped CLI on user machines. Overkill for a single-cluster setup.
2. **kube-oidc-proxy**: Avoids API server changes but adds a proxy in the request path (single point of failure, extra latency). Sporadic maintenance from JetStack.

## Architecture

```
User → Self-Service Portal → Authentik Login → Download Kubeconfig
                                                       │
User → kubectl (with kubelogin) → kube-apiserver → OIDC validation → Authentik
                                        │
                                   RBAC evaluation
                                        │
                                   Audit logging → Alloy → Loki → Grafana
```

### User Roles

| Role | Scope | Access |
|------|-------|--------|
| `admin` | Cluster-wide | Full `cluster-admin` access |
| `power-user` | Cluster-wide | Deploy/manage workloads, view all resources, no RBAC/node modification |
| `namespace-owner` | Specific namespaces | Full `admin` within assigned namespaces only |

## Components

### 1. Authentik OIDC Provider

New OAuth2/OIDC application in Authentik configured via Terraform (`modules/kubernetes/authentik/`).

- **Application name**: `kubernetes`
- **Provider type**: OAuth2/OpenID Connect
- **Client type**: Public (no client secret, kubelogin uses PKCE)
- **Redirect URIs**: `http://localhost:8000/callback` (kubelogin default)
- **Scopes**: `openid`, `email`, `profile`, `groups`
- **Property mappings**: Include `groups` claim for RBAC group matching

### 2. kube-apiserver OIDC Flags

One-time change on k8s-master (`10.0.20.100`), automated via Terraform `null_resource` with `remote-exec`.

Added to `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
- --oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/kubernetes/
- --oidc-client-id=kubernetes
- --oidc-username-claim=email
- --oidc-groups-claim=groups
```

Kubelet auto-restarts the API server pod when the manifest changes. These flags persist through `kubeadm upgrade apply`.

### 3. RBAC (Terraform-managed)

New module: `modules/kubernetes/rbac/main.tf`

**User definition** in `terraform.tfvars`:

```hcl
k8s_users = {
  "viktor" = {
    role  = "admin"
    email = "viktor@viktorbarzin.me"
  }
  "alice" = {
    role  = "power-user"
    email = "alice@example.com"
  }
  "bob" = {
    role       = "namespace-owner"
    namespaces = ["bob-apps", "bob-dev"]
    email      = "bob@example.com"
  }
}
```

**Resources created per role:**

| Role | Terraform Resources |
|------|-------------------|
| `admin` | `ClusterRoleBinding` → `cluster-admin` for user email |
| `power-user` | Custom `ClusterRole` (workload management, no RBAC/node access) + `ClusterRoleBinding` |
| `namespace-owner` | `Namespace`(s) + `RoleBinding` → built-in `admin` ClusterRole + `ResourceQuota` per namespace |

### 4. Self-Service Portal

Svelte (SvelteKit) app at `https://k8s-portal.viktorbarzin.me`.

**Flow:**
1. User visits portal → Authentik login via Traefik forward auth
2. Portal displays user's role and assigned namespaces
3. User downloads pre-configured kubeconfig (generated server-side)
4. Portal shows setup instructions (install kubectl + kubelogin)

**Kubeconfig template** includes:
- Cluster: `https://10.0.20.100:6443` with CA cert
- Auth: `exec` credential plugin pointing to kubelogin
- OIDC issuer URL and client ID pre-configured

**Deployment**: Standard Kubernetes deployment + service + ingress, Terraform-managed like other services. No database needed — user role info read from Kubernetes RBAC bindings or a Terraform-generated ConfigMap.

### 5. Audit Logging

Kubernetes audit policy deployed to master via the same `null_resource`.

**Policy** (`/etc/kubernetes/audit-policy.yaml`):
- `RequestResponse` level for OIDC-authenticated users (captures what they changed)
- `Metadata` level for system/service accounts (keeps volume down)
- Secrets logged at `Metadata` level only (no request/response bodies)

**Log pipeline**: Audit log file → Alloy (DaemonSet on master) → Loki → Grafana dashboard

**Grafana dashboard** shows: who accessed what resource, when, from where, and the outcome (allow/deny).

### 6. Resource Quotas

Each namespace-owner namespace gets a `ResourceQuota`:

```hcl
requests.cpu    = "2"
requests.memory = "4Gi"
limits.cpu      = "4"
limits.memory   = "8Gi"
pods            = "20"
```

Defaults can be overridden per-user via an optional `quota` field in the `k8s_users` variable.

## Implementation Order

1. Authentik OIDC application setup
2. kube-apiserver OIDC flag configuration
3. RBAC Terraform module
4. Audit logging
5. Self-service portal
6. Grafana dashboard for audit logs
