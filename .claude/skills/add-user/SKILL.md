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

SOPS state encryption access is **automatically provisioned** by the vault stack — per-stack Transit keys, policies, identity groups, and group aliases are all created from the `k8s_users` map. No manual SOPS setup required.

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
- Has the user been added to the **`sops-USERNAME`** group in Authentik? (Required for terraform state decrypt — the vault stack creates the Vault external group, but the Authentik group must exist and the user must be in it)
- Does the user need VPN access? If yes, also add to **`Headscale Users`** group in Authentik.

**Do NOT proceed until the Authentik group assignments are confirmed.**

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

Apply in order. Use the `scripts/tg` wrapper.

```bash
cd /Users/viktorbarzin/code/infra

# 1. Vault stack — creates namespace, Vault policy, identity entity, deployer role,
#    SOPS Transit key, SOPS policy, SOPS identity group + alias
cd stacks/vault && ../../scripts/tg apply --non-interactive
cd ../..

# 2. RBAC stack — creates RBAC bindings, ResourceQuota, TLS secret
cd stacks/rbac && ../../scripts/tg apply --non-interactive
cd ../..

# 3. Woodpecker stack — adds user to Woodpecker admin list
cd stacks/woodpecker && ../../scripts/tg apply --non-interactive
cd ../..
```

### Step 4: Create Per-Stack Encrypted State

For each of the user's namespaces, ensure the Transit key is used for state encryption. New stacks created for the user will automatically use per-stack keys via `scripts/state-sync`.

If the user's stack already has state, re-encrypt it with the new per-stack key:
```bash
# Force re-encrypt (delete old .enc, state-sync will use per-stack Transit key)
rm state/stacks/NAMESPACE/terraform.tfstate.enc
scripts/state-sync encrypt NAMESPACE
git add state/stacks/NAMESPACE/terraform.tfstate.enc
git commit -m "state(NAMESPACE): re-encrypt with per-stack Transit key"
```

### Step 5: Verify

```bash
# Namespace exists
kubectl get namespace USERNAME_NAMESPACE

# ResourceQuota applied
kubectl describe resourcequota -n USERNAME_NAMESPACE

# Vault policy exists (namespace-owner + SOPS)
vault policy read namespace-owner-USERNAME
vault policy read sops-user-USERNAME

# Vault identity entity exists (with both policies)
vault read identity/entity/name/USERNAME

# SOPS group exists
vault read identity/group/name/sops-USERNAME

# K8s deployer role works
vault write kubernetes/creds/NAMESPACE-deployer kubernetes_namespace=NAMESPACE

# SOPS Transit key exists
vault read transit/keys/sops-state-NAMESPACE

# DNS record (if domains specified)
dig DOMAIN.viktorbarzin.me
```

### Step 6: Notify User

Tell the user to share these onboarding instructions with the new user:
- K8s Portal: `https://k8s-portal.viktorbarzin.me/onboarding?role=namespace-owner`
- README: `https://github.com/ViktorBarzin/infra#new-user-onboarding`

The user can decrypt their stack's state with:
```bash
vault login -method=oidc   # authenticates via Authentik SSO
scripts/state-sync decrypt NAMESPACE   # decrypts only their stack
```

## What Gets Auto-Generated

| Resource | Stack | Driven by |
|----------|-------|-----------|
| Kubernetes namespace | vault | `namespaces` list |
| Vault policy (`namespace-owner-{user}`) | vault | user key |
| Vault identity entity + OIDC alias | vault | user email |
| K8s deployer Role + Vault K8s role | vault | `namespaces` list |
| **SOPS Transit key** (`sops-state-{ns}`) | vault | `namespaces` list |
| **SOPS Vault policy** (`sops-user-{user}`) | vault | user key + namespaces |
| **SOPS identity group** (`sops-{user}`) | vault | user key |
| **SOPS group alias** (maps Authentik group) | vault | user key |
| RBAC RoleBinding (namespace admin) | rbac | `namespaces` list |
| RBAC ClusterRoleBinding (cluster read-only) | rbac | user role |
| ResourceQuota | rbac | `quota` object |
| TLS secret in namespace | rbac | `namespaces` list |
| Cloudflare DNS records | cloudflared | `domains` list |
| Woodpecker admin access | woodpecker | user key |

## Checklist

- [ ] Authentik: user added to `kubernetes-namespace-owners` group
- [ ] Authentik: user added to `sops-USERNAME` group (for SOPS state decrypt)
- [ ] Authentik: user added to `Headscale Users` group (if VPN needed)
- [ ] Vault KV: `k8s_users` entry added to `secret/platform`
- [ ] Vault stack applied — namespace + policy + identity + deployer role + SOPS Transit key + SOPS policy + SOPS group created
- [ ] RBAC stack applied — RBAC + quota + TLS created
- [ ] Woodpecker stack applied — admin list updated
- [ ] Verification: namespace, quota, policies (namespace-owner + sops-user), deployer role, Transit key all confirmed
- [ ] User notified with onboarding link
