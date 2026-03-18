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

Add a new namespace-owner to the cluster. Two modes: **automated** (preferred) and **manual** (fallback).

SOPS state encryption access is **automatically provisioned** by the vault stack — per-stack Transit keys, policies, identity groups, and group aliases are all created from the `k8s_users` map. No manual SOPS setup required.

## Automated Flow (Preferred)

**Admin creates an Authentik invite → user signs up → provisioning happens automatically.**

### Steps

1. **Create Authentik Invitation**
   - Go to [Authentik Admin](https://authentik.viktorbarzin.me/if/admin/#/core/invitations)
   - Create a new invitation
   - Pre-assign the user to the **`kubernetes-namespace-owners`** group
   - Copy the invite link

2. **Send Invite Link to User**
   - The user clicks the link and signs up

3. **Automatic Provisioning (Vault KV + Authentik)**
   - Authentik fires a webhook to `webhook.viktorbarzin.me/authentik/provision`
   - The webhook handler validates the event and triggers the Woodpecker `provision-user` pipeline
   - Pipeline automatically:
     - Adds user to Vault KV (`secret/platform` → `k8s_users`) with convention defaults
     - Creates `sops-<username>` group in Authentik and assigns the user
     - Sends Slack notification with manual apply instructions

4. **Convention Defaults** (applied automatically)
   - Namespace: `username`
   - Quota: CPU 2, Memory 4Gi requests / 8Gi limits, 20 pods
   - Domains: none (user can request later)

5. **Manual Apply** (admin receives Slack notification)
   - The vault stack requires TLS certs (git-crypt) and can't run in CI. Apply manually:
   ```bash
   cd /Users/viktorbarzin/code/infra
   cd stacks/vault && ../../scripts/tg apply --non-interactive && cd ../..
   cd stacks/rbac && ../../scripts/tg apply --non-interactive && cd ../..
   cd stacks/woodpecker && ../../scripts/tg apply --non-interactive && cd ../..
   ```

6. **Post-Provisioning**
   - Send user the onboarding link: `https://k8s-portal.viktorbarzin.me/onboarding?role=namespace-owner`
   - If custom quota/domains needed, update Vault KV manually and re-apply stacks

### Monitoring the Pipeline

Watch the pipeline at: `https://ci.viktorbarzin.me` → infra repo → provision-user pipeline

## Manual Flow (Fallback)

Use when automated flow isn't available or custom configuration is needed.

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

### Step 4: Verify

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
```

### Step 5: Notify User

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

## Checklist (Manual Flow)

- [ ] Authentik: user added to `kubernetes-namespace-owners` group
- [ ] Authentik: user added to `sops-USERNAME` group (for SOPS state decrypt)
- [ ] Authentik: user added to `Headscale Users` group (if VPN needed)
- [ ] Vault KV: `k8s_users` entry added to `secret/platform`
- [ ] Vault stack applied — namespace + policy + identity + deployer role + SOPS Transit key + SOPS policy + SOPS group created
- [ ] RBAC stack applied — RBAC + quota + TLS created
- [ ] Woodpecker stack applied — admin list updated
- [ ] Verification: namespace, quota, policies (namespace-owner + sops-user), deployer role, Transit key all confirmed
- [ ] User notified with onboarding link
