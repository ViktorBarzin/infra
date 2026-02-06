# Setup Project Skill

**Purpose**: Deploy a new self-hosted service to the Kubernetes cluster from a GitHub repository.

**When to use**: User provides a GitHub URL or project name and wants to deploy it to the cluster.

## Workflow

### 1. Research Phase

**Input**: GitHub repository URL or project name

**Actions**:
- Visit the GitHub repository
- Check the README for:
  - Official Docker image (Docker Hub, ghcr.io, etc.)
  - docker-compose.yml file
  - Self-hosting documentation
  - Required dependencies (PostgreSQL, MySQL, Redis, etc.)
  - Environment variables needed
  - Default ports
  - Storage requirements

**Find Docker Image Priority**:
1. Check official documentation for recommended image
2. Look in docker-compose.yml for `image:` directive
3. Check GitHub Container Registry: `ghcr.io/<org>/<repo>`
4. Check Docker Hub: `<org>/<repo>`
5. Check releases page for container images
6. Last resort: Build from Dockerfile (avoid if possible)

**Extract Configuration**:
- Container port (default port the app listens on)
- Environment variables (DATABASE_URL, REDIS_HOST, SMTP, etc.)
- Volume mounts (what data needs persistence)
- Dependencies (database type, cache, etc.)

### 2. Database Setup (if needed)

**If project requires PostgreSQL**:
- User provides database credentials or use pattern: `<service>` user with secure password
- Database will be created in shared `postgresql.dbaas.svc.cluster.local`
- Connection string format: `postgresql://<user>:<password>@postgresql.dbaas.svc.cluster.local:5432/<dbname>`

**If project requires MySQL**:
- User provides database credentials
- Database in shared `mysql.dbaas.svc.cluster.local`
- Connection string format: `mysql://<user>:<password>@mysql.dbaas.svc.cluster.local:3306/<dbname>`

**If project requires Redis**:
- Use shared Redis: `redis.redis.svc.cluster.local:6379`
- No password required

**IMPORTANT**: Never create databases yourself - always ask user for credentials to use.

### 3. Terraform Module Creation

**Create module directory**:
```bash
mkdir -p modules/kubernetes/<service-name>/
```

**Create `modules/kubernetes/<service-name>/main.tf`**:

```hcl
variable "tls_secret_name" {}
variable "tier" { type = string }
variable "postgresql_password" {}  # Only if needed
# Add other variables as needed (smtp_password, api_keys, etc.)

resource "kubernetes_namespace" "<service>" {
  metadata {
    name = "<service>"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.<service>.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# If database migrations needed, add init_container
resource "kubernetes_deployment" "<service>" {
  metadata {
    name      = "<service>"
    namespace = kubernetes_namespace.<service>.metadata[0].name
    labels = {
      app  = "<service>"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "<service>"
      }
    }
    template {
      metadata {
        labels = {
          app = "<service>"
        }
      }
      spec {
        # Init container for migrations (if needed)
        # init_container { ... }

        container {
          name  = "<service>"
          image = "<docker-image>:<tag>"

          port {
            container_port = <port>
          }

          # Environment variables
          env {
            name  = "DATABASE_URL"
            value = "postgresql://<service>:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/<service>"
          }
          # Add other env vars as needed

          # Volume mounts for persistent data
          volume_mount {
            name       = "data"
            mount_path = "<mount-path>"
            sub_path   = "<optional-subpath>"
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
            limits = {
              memory = "2Gi"
              cpu    = "1"
            }
          }

          # Health checks (if endpoints exist)
          liveness_probe {
            http_get {
              path = "/health"  # or /healthz, /, etc.
              port = <port>
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }
        }

        # NFS volume for persistence
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/<service>"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "<service>" {
  metadata {
    name      = "<service>"
    namespace = kubernetes_namespace.<service>.metadata[0].name
    labels = {
      app = "<service>"
    }
  }

  spec {
    selector = {
      app = "<service>"
    }
    port {
      name        = "http"
      port        = 80
      target_port = <container-port>
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.<service>.metadata[0].name
  name            = "<service>"
  tls_secret_name = var.tls_secret_name
  # Add extra_annotations if needed (proxy-body-size, timeouts, etc.)
}
```

### 4. Update Main Terraform Files

**Add to `modules/kubernetes/main.tf`**:

1. Add variable declarations at top:
```hcl
variable "<service>_postgresql_password" { type = string }
```

2. Add to appropriate DEFCON level (ask user which level, default to 5):
```hcl
5 : [
  ...,
  "<service>"
]
```

3. Add module block at bottom:
```hcl
module "<service>" {
  source              = "./<service>"
  for_each            = contains(local.active_modules, "<service>") ? { <service> = true } : {}
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.<service>_postgresql_password
  tier                = local.tiers.aux  # or appropriate tier

  depends_on = [null_resource.core_services]
}
```

**Add to `main.tf`**:

1. Add variable:
```hcl
variable "<service>_postgresql_password" { type = string }
```

2. Pass to kubernetes_cluster module:
```hcl
module "kubernetes_cluster" {
  ...
  <service>_postgresql_password = var.<service>_postgresql_password
}
```

**Update `terraform.tfvars`**:

1. Add password/credentials:
```hcl
<service>_postgresql_password = "<secure-password>"
```

2. Add to Cloudflare DNS (ask user if proxied or non-proxied):
```hcl
cloudflare_non_proxied_names = [
  ...,
  "<service>"
]
```

### 5. Email/SMTP Configuration (if needed)

If service needs to send emails:
```hcl
env {
  name  = "MAILER_HOST"
  value = "mailserver.viktorbarzin.me"  # Public hostname for TLS
}
env {
  name  = "MAILER_PORT"
  value = "587"
}
env {
  name  = "MAILER_USER"
  value = "info@viktorbarzin.me"
}
env {
  name  = "MAILER_PASSWORD"
  value = var.mailserver_accounts["info@viktorbarzin.me"]  # Pass from module
}
```

Add to module call:
```hcl
smtp_password = var.mailserver_accounts["info@viktorbarzin.me"]
```

### 6. Apply Terraform

```bash
# Via remote executor
terraform init
terraform apply -target=module.kubernetes_cluster.module.<service> -auto-approve
```

### 7. Verification

```bash
kubectl get pods -n <service>
kubectl logs -n <service> -l app=<service> --tail=50
```

Test URL: `https://<service>.viktorbarzin.me`

### 8. Commit Changes

```bash
git add modules/kubernetes/<service>/ main.tf modules/kubernetes/main.tf terraform.tfvars
git commit -m "Add <service> deployment

- Deploy <service> as <description>
- Uses <dependencies>
- Ingress at <service>.viktorbarzin.me

[ci skip]"
```

## Common Patterns

### Init Container for Migrations
```hcl
init_container {
  name    = "migration"
  image   = "<same-image>"
  command = ["sh", "-c", "<migration-command>"]

  # Same env vars and volumes as main container
}
```

### Dynamic Environment Variables
```hcl
locals {
  common_env = [
    { name = "VAR1", value = "value1" },
    { name = "VAR2", value = "value2" },
  ]
}

dynamic "env" {
  for_each = local.common_env
  content {
    name  = env.value.name
    value = env.value.value
  }
}
```

### External URL Configuration
Many apps need their public URL configured:
```hcl
env {
  name  = "APP_URL"  # or PUBLIC_URL, EXTERNAL_URL, etc.
  value = "https://<service>.viktorbarzin.me"
}
env {
  name  = "HTTPS"  # or ENABLE_HTTPS, etc.
  value = "true"
}
```

## Checklist

- [ ] Find official Docker image or docker-compose
- [ ] Identify dependencies (DB, Redis, etc.)
- [ ] Ask user for database credentials (never create yourself)
- [ ] Create `modules/kubernetes/<service>/main.tf`
- [ ] Update `modules/kubernetes/main.tf` (variables, DEFCON level, module block)
- [ ] Update `main.tf` (variable, pass to module)
- [ ] Update `terraform.tfvars` (password, Cloudflare DNS)
- [ ] Run `terraform init` and `terraform apply`
- [ ] Verify pods are running
- [ ] Test the URL
- [ ] Commit changes with `[ci skip]`

## Questions to Ask User

1. What DEFCON level should this service be in? (Default: 5)
2. Should Cloudflare proxy this domain? (Default: no, add to non_proxied_names)
3. Does this need email/SMTP? (Configure if yes)
4. What database credentials should I use? (Never create yourself)
5. What tier? (core/cluster/gpu/edge/aux - default: aux)

## Notes

- **Always use official documentation** as the source of truth
- **Prefer stable/latest tags** over specific versions for self-hosted
- **Use shared infrastructure**: PostgreSQL at `postgresql.dbaas.svc.cluster.local`, Redis at `redis.redis.svc.cluster.local`
- **NFS storage**: Always at `10.0.10.15:/mnt/main/<service>`
- **Email**: Use `mailserver.viktorbarzin.me` (public hostname) not internal service name
- **Resource limits**: Start conservative, can increase if needed
- **Health checks**: Only add if the app has health endpoints
