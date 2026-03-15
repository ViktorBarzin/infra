This repo contains my infra-as-code sources.

My infrastructure is built using Terraform, Kubernetes and CI/CD is done using Woodpecker CI.

Read more by visiting my website:
https://viktorbarzin.me

## Adding a New User (Admin)

Adding a new namespace-owner to the cluster requires three steps — no code changes needed.

### 1. Authentik Group Assignment

In the [Authentik admin UI](https://authentik.viktorbarzin.me), add the user to:
- `kubernetes-namespace-owners` group (grants OIDC group claim for K8s RBAC)
- `Headscale Users` group (if they need VPN access)

### 2. Vault KV Entry

Add a JSON entry to `secret/platform` → `k8s_users` key in [Vault](https://vault.viktorbarzin.me):

```json
"username": {
  "role": "namespace-owner",
  "email": "user@example.com",
  "namespaces": ["username"],
  "domains": ["myapp"],
  "quota": {
    "cpu_requests": "2",
    "memory_requests": "4Gi",
    "memory_limits": "8Gi",
    "pods": "20"
  }
}
```

- `username` key must match the user's Forgejo username (for Woodpecker admin access)
- `namespaces` — K8s namespaces to create and grant admin access to
- `domains` — subdomains under `viktorbarzin.me` for Cloudflare DNS records
- `quota` — resource limits per namespace (defaults shown above)

### 3. Apply Stacks

```bash
vault login -method=oidc

cd stacks/vault && terragrunt apply --non-interactive
# Creates: namespace, Vault policy, identity entity, K8s deployer role

cd ../platform && terragrunt apply --non-interactive
# Creates: RBAC bindings, ResourceQuota, TLS secret, DNS records

cd ../woodpecker && terragrunt apply --non-interactive
# Adds user to Woodpecker admin list
```

### What Gets Auto-Generated

| Resource | Stack |
|----------|-------|
| Kubernetes namespace | vault |
| Vault policy (`namespace-owner-{user}`) | vault |
| Vault identity entity + OIDC alias | vault |
| K8s deployer Role + Vault K8s role | vault |
| RBAC RoleBinding (namespace admin) | platform |
| RBAC ClusterRoleBinding (cluster read-only) | platform |
| ResourceQuota | platform |
| TLS secret in namespace | platform |
| Cloudflare DNS records | platform |
| Woodpecker admin access | woodpecker |

## New User Onboarding

If you've been added as a namespace-owner, follow these steps to get started.

### 1. Join the VPN

```bash
# Install Tailscale: https://tailscale.com/download
tailscale login --login-server https://headscale.viktorbarzin.me
# Send the registration URL to Viktor, wait for approval
ping 10.0.20.100  # verify connectivity
```

### 2. Install Tools

Run the setup script to install kubectl, kubelogin, Vault CLI, Terraform, and Terragrunt:

```bash
# macOS
bash <(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac)

# Linux
bash <(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)
```

### 3. Authenticate

```bash
# Log into Vault (opens browser for SSO)
vault login -method=oidc

# Test kubectl (opens browser for OIDC login)
kubectl get pods -n YOUR_NAMESPACE
```

### 4. Deploy Your First App

```bash
# Clone the infra repo
git clone https://github.com/ViktorBarzin/infra.git && cd infra

# Copy the stack template
cp -r stacks/_template stacks/myapp
mv stacks/myapp/main.tf.example stacks/myapp/main.tf

# Edit main.tf — replace all <placeholders>

# Store secrets in Vault
vault kv put secret/YOUR_USERNAME/myapp DB_PASSWORD=secret123

# Submit a PR
git checkout -b feat/myapp
git add stacks/myapp/
git commit -m "add myapp stack"
git push -u origin feat/myapp
```

After review and merge, an admin runs `cd stacks/myapp && terragrunt apply`.

### 5. Set Up CI/CD (Optional)

Create `.woodpecker.yml` in your app's Forgejo repo:

```yaml
steps:
  - name: build
    image: woodpeckerci/plugin-docker-buildx
    settings:
      repo: YOUR_DOCKERHUB_USER/myapp
      tag: ["${CI_PIPELINE_NUMBER}", "latest"]
      username:
        from_secret: dockerhub-username
      password:
        from_secret: dockerhub-token
      platforms: linux/amd64

  - name: deploy
    image: hashicorp/vault:1.18.1
    commands:
      - export VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200
      - export VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login
          role=ci jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
      - KUBE_TOKEN=$(vault write -field=service_account_token
          kubernetes/creds/YOUR_NAMESPACE-deployer
          kubernetes_namespace=YOUR_NAMESPACE)
      - kubectl --server=https://kubernetes.default.svc
          --token=$KUBE_TOKEN
          --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          -n YOUR_NAMESPACE set image deployment/myapp
          myapp=YOUR_DOCKERHUB_USER/myapp:${CI_PIPELINE_NUMBER}
```

### Useful Commands

```bash
# Check your pods
kubectl get pods -n YOUR_NAMESPACE

# View quota usage
kubectl describe resourcequota -n YOUR_NAMESPACE

# Store/read secrets
vault kv put secret/YOUR_USERNAME/myapp KEY=value
vault kv get secret/YOUR_USERNAME/myapp

# Get a short-lived K8s deploy token
vault write kubernetes/creds/YOUR_NAMESPACE-deployer \
  kubernetes_namespace=YOUR_NAMESPACE
```

### Important Rules

- **All changes go through Terraform** — never `kubectl apply/edit/patch` directly
- **Never put secrets in code** — use Vault: `vault kv put secret/YOUR_USERNAME/...`
- **Always use a PR** — never push directly to master
- **Docker images**: build for `linux/amd64`, use versioned tags (not `:latest`)

## git-crypt setup

To decrypt the secrets, you need to setup [git-crypt](https://github.com/AGWA/git-crypt).

1. Install [git-crypt](https://github.com/AGWA/git-crypt).
2. Setup gpg keys on the machine
3. `git-crypt unlock`

This will unlock the secrets and will lock them on commit

