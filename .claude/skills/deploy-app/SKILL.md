---
name: deploy-app
description: Deploy a GitHub repo as a running web app on the cluster with full CI/CD.
  Use when the user says "deploy app", "deploy repo", "set up CI/CD for", or provides
  a GitHub URL and wants it running on the cluster. Handles Dockerfile, GHA build,
  Woodpecker deploy, Terraform stack, DNS, TLS, and auth — end to end.
---

# deploy-app Skill

Deploy a GitHub repository as a running web application on the Kubernetes cluster with full CI/CD.

**Architecture**: `GitHub push → GHA builds Docker image → pushes DockerHub → POSTs Woodpecker API → kubectl set image → app live at <name>.viktorbarzin.me`

## Checklist

- [ ] Step 1: Collect information (interactive prompts)
- [ ] Step 2-4: Create CI files via `gh` PR (Dockerfile, Woodpecker, GHA)
- [ ] Step 5: Set GitHub repo secrets
- [ ] Step 6: Create Terraform stack
- [ ] Step 7: Add DNS entry to terraform.tfvars
- [ ] Step 8: Apply Terraform
- [ ] Step 9: Activate Woodpecker repo
- [ ] Step 10: Update GHA workflow with real repo ID
- [ ] Step 11: Verify end-to-end
- [ ] Step 12: Commit infra changes

---

## Step 1: Collect Information

Prompt the user for each field. Auto-detect what you can from the repo.

| Field | Default | Notes |
|-------|---------|-------|
| `github_repo` | — | `owner/repo` or full URL (required) |
| `app_name` | repo name | K8s namespace/deployment name |
| `subdomain` | `app_name` | DNS subdomain (may differ, e.g. f1-stream uses `f1`) |
| `image_name` | `viktorbarzin/<app_name>` | DockerHub image |
| `port` | 8000 | Container port |
| `database` | none | `postgresql` / `mysql` / `none` |
| `protected` | true | Authentik SSO gate |
| `env_vars` | `{}` | Key=value pairs for the container |
| `needs_storage` | false | NFS persistent volume |

**Auto-detect from repo** (use `gh api`):
- Project type: check for `package.json`, `requirements.txt`/`pyproject.toml`, `go.mod`
- Default branch
- Whether a Dockerfile already exists

```bash
# Example detection
OWNER="..." REPO="..."
DEFAULT_BRANCH=$(gh api repos/$OWNER/$REPO --jq '.default_branch')
gh api repos/$OWNER/$REPO/contents/Dockerfile --jq '.name' 2>/dev/null && echo "Dockerfile exists"
gh api repos/$OWNER/$REPO/contents/package.json --jq '.name' 2>/dev/null && echo "Node project"
gh api repos/$OWNER/$REPO/contents/requirements.txt --jq '.name' 2>/dev/null && echo "Python project"
gh api repos/$OWNER/$REPO/contents/pyproject.toml --jq '.name' 2>/dev/null && echo "Python project (pyproject)"
gh api repos/$OWNER/$REPO/contents/go.mod --jq '.name' 2>/dev/null && echo "Go project"
```

Present detected values as defaults, let user confirm or override.

---

## Steps 2-4: Create CI Files via `gh` PR

Create all CI files in the remote repo without cloning locally. Use `gh` CLI to create a branch, add files, and merge a PR.

### Create the branch

```bash
DEFAULT_BRANCH=$(gh api repos/$OWNER/$REPO --jq '.default_branch')
SHA=$(gh api repos/$OWNER/$REPO/git/ref/heads/$DEFAULT_BRANCH --jq '.object.sha')
gh api repos/$OWNER/$REPO/git/refs -X POST -f ref=refs/heads/ci-setup -f sha=$SHA
```

### File 1: Dockerfile (only if missing)

Generate based on detected project type:

**Python** (requirements.txt or pyproject.toml):
```dockerfile
FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE {{PORT}}
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "{{PORT}}"]
```

**Node** (package.json):
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=build /app .
EXPOSE {{PORT}}
CMD ["node", "build"]
```

**Go** (go.mod):
```dockerfile
FROM golang:1.24 AS build
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /app/server .

FROM gcr.io/distroless/static
COPY --from=build /app/server /server
EXPOSE {{PORT}}
CMD ["/server"]
```

### File 2: `.woodpecker/deploy.yml`

```yaml
when:
  - event: [manual, push]

steps:
  - name: check-vars
    image: alpine
    commands:
      - "[ -n \"$IMAGE_TAG\" ] || (echo 'IMAGE_TAG not set, skipping deploy'; exit 78)"

  - name: deploy
    image: bitnami/kubectl:latest
    commands:
      - "kubectl set image deployment/{{APP_NAME}} {{APP_NAME}}=${IMAGE_NAME}:${IMAGE_TAG} -n {{APP_NAME}}"
      - "kubectl rollout status deployment/{{APP_NAME}} -n {{APP_NAME}} --timeout=300s"

  - name: notify
    image: woodpeckerci/plugin-slack
    settings:
      webhook:
        from_secret: slack-webhook-url
      channel: general
    when:
      - status: [success, failure]
```

### File 3: `.github/workflows/build-and-deploy.yml`

Use `REPO_ID_PLACEHOLDER` — will be replaced in Step 10 after Woodpecker activation.

```yaml
name: Build and Deploy

on:
  push:
    branches: [{{DEFAULT_BRANCH}}]

env:
  IMAGE_NAME: {{APP_NAME}}

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.meta.outputs.sha }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - id: meta
        run: echo "sha=$(echo ${{ github.sha }} | cut -c1-8)" >> $GITHUB_OUTPUT
      - uses: docker/build-push-action@v6
        with:
          push: true
          platforms: linux/amd64
          tags: |
            viktorbarzin/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.sha }}
            viktorbarzin/${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Woodpecker deploy
        run: |
          for attempt in 1 2 3; do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
              "https://ci.viktorbarzin.me/api/repos/REPO_ID_PLACEHOLDER/pipelines" \
              -H "Authorization: Bearer ${{ secrets.WOODPECKER_TOKEN }}" \
              -H "Content-Type: application/json" \
              -d '{"branch":"{{DEFAULT_BRANCH}}","variables":{"IMAGE_TAG":"${{ needs.build.outputs.image_tag }}","IMAGE_NAME":"viktorbarzin/${{ env.IMAGE_NAME }}"}}')
            if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
              echo "Woodpecker deploy triggered (HTTP $STATUS)"
              exit 0
            fi
            echo "Attempt $attempt failed (HTTP $STATUS), retrying in 30s..."
            sleep 30
          done
          echo "Failed to trigger Woodpecker deploy after 3 attempts"
          exit 1
```

### Upload files and create PR

For each file, upload via GitHub API:

```bash
# Upload a file (base64-encoded)
gh api repos/$OWNER/$REPO/contents/PATH -X PUT \
  -f message="ci: add CI/CD pipeline" -f branch=ci-setup \
  -f content="$(base64 < /tmp/file)"
```

Then create and merge the PR:

```bash
gh pr create --repo $OWNER/$REPO --head ci-setup --base $DEFAULT_BRANCH \
  --title "ci: add CI/CD pipeline" --body "Adds GHA build + Woodpecker deploy pipeline"
gh pr merge --repo $OWNER/$REPO --merge --auto
```

**Note**: Merging triggers GHA — build job succeeds (pushes Docker image), deploy job fails gracefully (404 from placeholder). This is intentional so the image exists before Terraform creates the deployment.

---

## Step 5: Set GitHub Repo Secrets

```bash
# Get values from Vault
DOCKERHUB_USERNAME=$(vault kv get -field=docker_username secret/ci/global)
DOCKERHUB_TOKEN=$(vault kv get -field=dockerhub-pat secret/ci/global)
WOODPECKER_TOKEN=$(vault kv get -field=woodpecker_api_token secret/ci/global)

# Set via gh CLI
gh secret set DOCKERHUB_USERNAME --repo $OWNER/$REPO --body "$DOCKERHUB_USERNAME"
gh secret set DOCKERHUB_TOKEN --repo $OWNER/$REPO --body "$DOCKERHUB_TOKEN"
gh secret set WOODPECKER_TOKEN --repo $OWNER/$REPO --body "$WOODPECKER_TOKEN"
```

Verify: `gh secret list --repo $OWNER/$REPO` — should show 3 secrets.

---

## Step 6: Create Terraform Stack

Create `/Users/viktorbarzin/code/infra/stacks/{{APP_NAME}}/` with two files.

### `terragrunt.hcl`

```hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path  = "../platform"
  skip_outputs = true
}

dependency "vault" {
  config_path  = "../vault"
  skip_outputs = true
}
```

### `main.tf`

Generate based on collected information. Use the f1-stream stack as the primary reference, plus the template's lifecycle block.

**Minimum required resources:**
- `kubernetes_namespace` with tier label (`aux`)
- `kubernetes_deployment` with:
  - `image = "viktorbarzin/{{IMAGE_NAME}}:latest"` (initial; CI updates via `kubectl set image`)
  - `image_pull_policy = "Always"`
  - `lifecycle { ignore_changes = [spec[0].template[0].spec[0].dns_config] }` (Kyverno ndots drift)
  - `annotations = { "reloader.stakater.com/auto" = "true" }` (auto-restart on secret changes)
  - Resources: **256Mi** request=limit, **10m** CPU request
  - Port, env vars, optional volume mounts
- `kubernetes_service` (port 80 → container port)
- `module "tls_secret"` from `../../modules/kubernetes/setup_tls_secret`
- `module "ingress"` from `../../modules/kubernetes/ingress_factory` with `protected` flag

**Conditional resources:**
- If `database != "none"` or `env_vars` has secrets: add `kubernetes_manifest` ExternalSecret from `vault-kv` ClusterSecretStore, key = `{{APP_NAME}}`
- If `needs_storage`: add `module "nfs_data"` from `../../modules/kubernetes/nfs_volume`

**Example main.tf** (adapt per collected info):

```hcl
variable "tls_secret_name" {
  type      = string
  sensitive = true
}
# Add variable "nfs_server" { type = string } if needs_storage

resource "kubernetes_namespace" "{{APP_NAME}}" {
  metadata {
    name = "{{APP_NAME}}"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

# Include ExternalSecret block if database or secrets needed:
# resource "kubernetes_manifest" "external_secret" {
#   manifest = {
#     apiVersion = "external-secrets.io/v1beta1"
#     kind       = "ExternalSecret"
#     metadata = {
#       name      = "{{APP_NAME}}-secrets"
#       namespace = "{{APP_NAME}}"
#     }
#     spec = {
#       refreshInterval = "15m"
#       secretStoreRef = {
#         name = "vault-kv"
#         kind = "ClusterSecretStore"
#       }
#       target = {
#         name = "{{APP_NAME}}-secrets"
#       }
#       dataFrom = [{
#         extract = {
#           key = "{{APP_NAME}}"
#         }
#       }]
#     }
#   }
#   depends_on = [kubernetes_namespace.{{APP_NAME}}]
# }

resource "kubernetes_deployment" "{{APP_NAME}}" {
  metadata {
    name      = "{{APP_NAME}}"
    namespace = kubernetes_namespace.{{APP_NAME}}.metadata[0].name
    labels = {
      app  = "{{APP_NAME}}"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "{{APP_NAME}}"
      }
    }
    template {
      metadata {
        labels = {
          app = "{{APP_NAME}}"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/{{IMAGE_NAME}}:latest"
          image_pull_policy = "Always"
          name              = "{{APP_NAME}}"
          resources {
            limits = {
              memory = "256Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
          }
          port {
            container_port = {{PORT}}
          }
          # Add env blocks for env_vars here
          # For secret refs:
          # env {
          #   name = "DB_PASSWORD"
          #   value_from {
          #     secret_key_ref {
          #       name = "{{APP_NAME}}-secrets"
          #       key  = "db_password"
          #     }
          #   }
          # }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "{{APP_NAME}}" {
  metadata {
    name      = "{{SUBDOMAIN}}"
    namespace = kubernetes_namespace.{{APP_NAME}}.metadata[0].name
    labels = {
      "app" = "{{APP_NAME}}"
    }
  }
  spec {
    selector = {
      app = "{{APP_NAME}}"
    }
    port {
      port        = "80"
      target_port = "{{PORT}}"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.{{APP_NAME}}.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.{{APP_NAME}}.metadata[0].name
  name            = "{{SUBDOMAIN}}"
  tls_secret_name = var.tls_secret_name
  # protected     = true  # Set based on user choice
}
```

---

## Step 7: Add DNS Entry

Edit `/Users/viktorbarzin/code/infra/terraform.tfvars`:

- If `protected` (Authentik-gated): add `"{{SUBDOMAIN}}"` to `cloudflare_proxied_names` (line ~1154)
- If public/not protected: add `"{{SUBDOMAIN}}"` to `cloudflare_non_proxied_names` (line ~1157)

---

## Step 8: Apply Terraform

```bash
cd /Users/viktorbarzin/code/infra

# Ensure Vault auth
vault login -method=oidc  # if needed

# Apply the new stack
cd stacks/{{APP_NAME}} && ../../scripts/tg apply --non-interactive

# Apply platform to create the DNS record
cd ../platform && ../../scripts/tg apply --non-interactive
```

Verify:
```bash
KUBECONFIG=/Users/viktorbarzin/code/config kubectl get pods -n {{APP_NAME}}
KUBECONFIG=/Users/viktorbarzin/code/config kubectl get svc -n {{APP_NAME}}
curl -s -o /dev/null -w "%{http_code}" https://{{SUBDOMAIN}}.viktorbarzin.me
```

---

## Step 9: Activate Woodpecker Repo

Try API-first (fully automated):

```bash
WOODPECKER_TOKEN=$(vault kv get -field=woodpecker_api_token secret/ci/global)
GITHUB_REPO_ID=$(gh api repos/$OWNER/$REPO --jq '.id')

curl -s -X POST "https://ci.viktorbarzin.me/api/repos" \
  -H "Authorization: Bearer $WOODPECKER_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"forge_remote_id\":\"$GITHUB_REPO_ID\"}"
```

If API activation fails, guide the user to activate via `https://ci.viktorbarzin.me` UI.

Then get the Woodpecker numeric repo ID:

```bash
WP_REPO_ID=$(curl -s -H "Authorization: Bearer $WOODPECKER_TOKEN" \
  "https://ci.viktorbarzin.me/api/repos/lookup/$OWNER/$REPO" | jq '.id')
echo "Woodpecker repo ID: $WP_REPO_ID"
```

---

## Step 10: Update GHA Workflow with Real Repo ID

Replace `REPO_ID_PLACEHOLDER` in the GHA workflow remotely:

```bash
# Get current file SHA
FILE_SHA=$(gh api repos/$OWNER/$REPO/contents/.github/workflows/build-and-deploy.yml \
  --jq '.sha' -H "Accept: application/vnd.github.v3+json")

# Download, replace placeholder, re-upload
gh api repos/$OWNER/$REPO/contents/.github/workflows/build-and-deploy.yml \
  --jq '.content' | base64 -d | sed "s/REPO_ID_PLACEHOLDER/$WP_REPO_ID/" | base64 > /tmp/workflow.b64

gh api repos/$OWNER/$REPO/contents/.github/workflows/build-and-deploy.yml \
  -X PUT -f message="ci: set Woodpecker repo ID ($WP_REPO_ID)" \
  -f content="$(cat /tmp/workflow.b64)" -f sha="$FILE_SHA"
```

This commit triggers the first full build→deploy cycle.

---

## Step 11: Verify End-to-End

1. Wait for GHA build: `gh run watch --repo $OWNER/$REPO`
2. Check Woodpecker deploy triggered:
   ```bash
   curl -s -H "Authorization: Bearer $WOODPECKER_TOKEN" \
     "https://ci.viktorbarzin.me/api/repos/$WP_REPO_ID/pipelines?page=1&per_page=1" | jq '.[0].status'
   ```
3. Check pod running with new image:
   ```bash
   KUBECONFIG=/Users/viktorbarzin/code/config kubectl get pods -n {{APP_NAME}} -o jsonpath='{..image}'
   ```
4. Check URL: `curl -sI https://{{SUBDOMAIN}}.viktorbarzin.me`

---

## Step 12: Commit Infra Changes

```bash
cd /Users/viktorbarzin/code/infra
git add stacks/{{APP_NAME}}/ terraform.tfvars
git commit -m "$(cat <<'EOF'
add {{APP_NAME}} stack and DNS entry [ci skip]
EOF
)"
git push origin master
```

---

## Chicken-and-Egg Resolution

The Woodpecker repo ID is needed in GHA but only exists after activation:

1. **PR merge** (Steps 2-4): GHA workflow with `REPO_ID_PLACEHOLDER`. Build succeeds (image pushed), deploy fails harmlessly (404).
2. **Terraform** (Step 8): Creates deployment using `:latest` — the image from the first build.
3. **Activation** (Step 9): Woodpecker repo activated, deploy.yml already in place.
4. **API update** (Step 10): Real repo ID patched into workflow → first full CI/CD cycle succeeds.

## Important Notes

- **Woodpecker API uses numeric repo IDs** (`/api/repos/10/pipelines`), NOT owner/name paths
- **Global secrets must have `manual` in allowed events** for API-triggered pipelines (already configured)
- **Docker images must be `linux/amd64`** — the cluster runs amd64
- **Use 8-char SHA tags** — `:latest` causes stale pull-through cache issues
- **`image_pull_policy = "Always"`** is required for CI image updates to take effect
- **Kyverno ndots drift**: Always add `lifecycle { ignore_changes = [spec[0].template[0].spec[0].dns_config] }`
- **Vault KV path for secrets**: `secret/{{APP_NAME}}` — create via `vault kv put secret/{{APP_NAME}} KEY=value` if needed
- **256Mi memory default** is safer than 128Mi (many apps OOM at 128Mi)
