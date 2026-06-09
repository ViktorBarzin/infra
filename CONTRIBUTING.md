# Contributing to the Infrastructure Repo

This guide covers the namespace-owner workflow for deploying apps on the cluster. For admin operations, see `AGENTS.md`.

## Prerequisites

1. You are listed in `k8s_users` (Vault KV `secret/platform`) with `role: "namespace-owner"`
2. Your namespace exists (auto-created by the vault stack)
3. You have Vault CLI access: `vault login -method=oidc`
4. You have cluster access: `kubectl get namespaces` (uses OIDC via kubelogin)

## Deploy Your App (5 Steps)

### 1. Copy the Template

```bash
cp -r stacks/_template stacks/myapp
mv stacks/myapp/main.tf.example stacks/myapp/main.tf
```

### 2. Customize `main.tf`

Replace all `<placeholders>`:

| Placeholder | Example |
|-------------|---------|
| `<your-namespace>` | `anca` |
| `<app-name>` | `my-webapp` |
| `<dockerhub-user>/<app-name>:<tag>` | `jdoe/my-webapp:abc12345` |

Set resources explicitly on every container:

```hcl
resources {
  requests = { cpu = "10m", memory = "256Mi" }
  limits   = { memory = "256Mi" }
}
```

### 3. Store Secrets in Vault

```bash
vault login -method=oidc
vault kv put secret/<your-username>/myapp DB_PASSWORD=xxx API_KEY=yyy
```

Your Vault path is `secret/<your-username>/*` — full CRUD access there only.

### 4. Submit a PR

```bash
git checkout -b feat/myapp
git add stacks/myapp/
git commit -m "add myapp stack"
git push -u origin feat/myapp
```

Open a PR. Admin reviews and runs `terragrunt apply`.

### 5. Set Up CI/CD (Optional)

For automated deploys on push, create `.woodpecker/deploy.yml` in your app repo:

```yaml
steps:
  - name: deploy
    image: bitnami/kubectl:latest
    commands:
      - kubectl set image deployment/<app-name> <app-name>=<image>:${CI_COMMIT_SHA:0:8} -n <namespace>
```

## Resource Constraints

Your namespace has hard limits enforced by ResourceQuota:

| Resource | Default |
|----------|---------|
| CPU requests | 2 cores |
| Memory requests | 4Gi |
| Memory limits | 8Gi |
| Pods | 20 |
| Storage | 20Gi |
| PVCs | 5 |

- Pods run at **tier-4-aux** priority — they never preempt platform services.
- Kyverno injects default limits (256Mi) for containers without explicit resources.
- Always set explicit `resources {}` to avoid surprises.

## Vault Secret Paths

| Path | Access |
|------|--------|
| `secret/<your-username>/*` | Full CRUD (your secrets) |
| `kubernetes/creds/<namespace>-deployer` | Read (dynamic K8s deploy tokens) |
| `transit/encrypt/sops-state-<namespace>` | Encrypt (state encryption) |
| `transit/decrypt/sops-state-<namespace>` | Decrypt (state encryption) |

## What NOT to Do

- **No kubectl mutations**: Never `kubectl apply/edit/patch/delete` for persistent changes. Read-only kubectl is fine for debugging.
- **No secrets in code**: Use Vault KV or Sealed Secrets. Never commit plaintext secrets.
- **No `:latest` tags**: The pull-through cache serves stale `:latest` manifests. Use 8-char git SHA tags (e.g., `abc12345`).
- **No resources outside your namespace**: RBAC prevents it. Don't try.
- **No `terragrunt apply`**: Admin-only. Submit a PR instead.
- **No unbounded resource specs**: Always set `resources {}` with explicit CPU/memory.

## AI Agent Instructions

If you're an AI agent helping a namespace-owner:

1. Read this file and `AGENTS.md` before making changes
2. Check `stacks/_template/` for the canonical starting point
3. Always set explicit `resources {}` (256Mi memory minimum)
4. Store secrets at `secret/<username>/<app>` in Vault
5. Never run `terragrunt apply` — create a PR for admin review
6. Use versioned image tags, never `:latest`
7. Interactive setup: `curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac`
8. Agent bootstrap doc: `curl -fsSL https://k8s-portal.viktorbarzin.me/agent`

## Further Reading

- [Onboarding guide](https://k8s-portal.viktorbarzin.me/onboarding)
- [Agent bootstrap doc](https://k8s-portal.viktorbarzin.me/agent)
- Template: `stacks/_template/main.tf.example`
- Full agent instructions: `AGENTS.md`
