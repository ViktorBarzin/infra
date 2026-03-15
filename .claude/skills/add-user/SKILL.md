---
name: add-user
description: |
  Add a new namespace-owner to the Kubernetes cluster. Use when:
  (1) "add user", "onboard user", "create user", "new namespace-owner",
  (2) someone new needs their own namespace and CI access,
  (3) user asks to set up cluster access for a person.
  Interactive: asks questions, updates Vault KV, applies stacks.
---

# Add User

Add a new namespace-owner to the cluster. No code changes needed — only Vault KV update + stack applies.

## Workflow

### Step 1: Collect Information

Ask the user for ALL of the following before proceeding:

| Field | Question | Default |
|-------|----------|---------|
| `username` | Username (must match Forgejo username for CI) | — |
| `email` | Email address (used for OIDC identity) | — |
| `namespaces` | Namespace name(s) to create | `[username]` |
| `domains` | Subdomain(s) under viktorbarzin.me for their apps | `[]` |
| `cpu_requests` | CPU request quota | `"2"` |
| `memory_requests` | Memory request quota | `"4Gi"` |
| `memory_limits` | Memory limit quota | `"8Gi"` |
| `pods` | Max pods | `"20"` |

Also confirm:
- Has the user been added to the **`kubernetes-namespace-owners`** group in [Authentik](https://authentik.viktorbarzin.me)? (Manual step — admin must do this in the UI)
- Does the user need VPN access? If yes, also add to **`Headscale Users`** group in Authentik.

**Do NOT proceed until the Authentik group assignment is confirmed.**

### Step 2: Update Vault KV

Read the current `k8s_users` JSON from Vault, add the new entry, and write it back.

```bash
# Ensure authenticated
vault login -method=oidc

# Read current value
vault kv get -format=json secret/platform | jq -r '.data.data.k8s_users' > /tmp/k8s_users.json

# Add the new user entry (use jq to merge)
jq --arg user "USERNAME" \
   --arg email "EMAIL" \
   --argjson ns '["NAMESPACE"]' \
   --argjson domains '["DOMAIN1"]' \
   --argjson quota '{"cpu_requests":"2","memory_requests":"4Gi","memory_limits":"8Gi","pods":"20"}' \
   '. + {($user): {"role":"namespace-owner","email":$email,"namespaces":$ns,"domains":$domains,"quota":$quota}}' \
   /tmp/k8s_users.json > /tmp/k8s_users_updated.json

# Write back — must write the entire platform secret, not just k8s_users
# First get all current keys
vault kv get -format=json secret/platform | jq -r '.data.data' > /tmp/platform_secret.json

# Update k8s_users key with new JSON (as a string, since complex types are stored as JSON strings)
jq --arg users "$(cat /tmp/k8s_users_updated.json)" '.k8s_users = $users' /tmp/platform_secret.json > /tmp/platform_updated.json

# Write back
vault kv put secret/platform @/tmp/platform_updated.json

# Clean up
rm -f /tmp/k8s_users.json /tmp/k8s_users_updated.json /tmp/platform_secret.json /tmp/platform_updated.json
```

**Verify** the write:
```bash
vault kv get -field=k8s_users secret/platform | jq '.USERNAME'
```

### Step 3: Apply Stacks

Apply in order. Use the `scripts/tg` wrapper or `terragrunt` directly.

```bash
cd /Users/viktorbarzin/code/infra

# 1. Vault stack — creates namespace, Vault policy, identity entity, deployer role
cd stacks/vault && terragrunt apply --non-interactive
cd ../..

# 2. Platform stack — creates RBAC bindings, ResourceQuota, TLS secret, DNS records
cd stacks/platform && terragrunt apply --non-interactive
cd ../..

# 3. Woodpecker stack — adds user to Woodpecker admin list
cd stacks/woodpecker && terragrunt apply --non-interactive
cd ../..
```

Use the `devops-engineer` agent for each apply to get background pod health monitoring.

### Step 4: Verify

```bash
# Namespace exists
kubectl get namespace USERNAME_NAMESPACE

# ResourceQuota applied
kubectl describe resourcequota -n USERNAME_NAMESPACE

# Vault policy exists
vault policy read namespace-owner-USERNAME

# Vault identity entity exists
vault read identity/entity/name/USERNAME

# K8s deployer role works
vault write kubernetes/creds/NAMESPACE-deployer kubernetes_namespace=NAMESPACE

# DNS record (if domains specified)
dig DOMAIN.viktorbarzin.me
```

### Step 5: Notify User

Tell the user to share these onboarding instructions with the new user:
- K8s Portal: `https://k8s-portal.viktorbarzin.me/onboarding?role=namespace-owner`
- README: `https://github.com/ViktorBarzin/infra#new-user-onboarding`

## What Gets Auto-Generated

| Resource | Stack | Driven by |
|----------|-------|-----------|
| Kubernetes namespace | vault | `namespaces` list |
| Vault policy (`namespace-owner-{user}`) | vault | user key |
| Vault identity entity + OIDC alias | vault | user email |
| K8s deployer Role + Vault K8s role | vault | `namespaces` list |
| RBAC RoleBinding (namespace admin) | platform | `namespaces` list |
| RBAC ClusterRoleBinding (cluster read-only) | platform | user role |
| ResourceQuota | platform | `quota` object |
| TLS secret in namespace | platform | `namespaces` list |
| Cloudflare DNS records | platform | `domains` list |
| Woodpecker admin access | woodpecker | user key |

## Checklist

- [ ] Authentik: user added to `kubernetes-namespace-owners` group
- [ ] Authentik: user added to `Headscale Users` group (if VPN needed)
- [ ] Vault KV: `k8s_users` entry added to `secret/platform`
- [ ] Vault stack applied — namespace + policy + identity + deployer role created
- [ ] Platform stack applied — RBAC + quota + TLS + DNS created
- [ ] Woodpecker stack applied — admin list updated
- [ ] Verification: namespace, quota, policy, deployer role all confirmed
- [ ] User notified with onboarding link
