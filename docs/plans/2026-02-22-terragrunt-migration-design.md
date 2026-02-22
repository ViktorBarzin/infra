# Terragrunt Migration Design

**Date**: 2026-02-22
**Status**: Approved

## Problem

The infrastructure repo has a monolithic Terraform setup:
- 15MB state file, 857 resources, 85+ service modules in a single root
- `terraform plan/apply` evaluates all modules even when targeting one service
- `null_resource.core_services` bottleneck blocks 73 services behind 12 core modules
- 150+ variables passed through root -> kubernetes_cluster -> individual services
- 3 providers (kubernetes, helm, proxmox) initialize on every run

## Goals

- **Speed**: Faster plan/apply by splitting state into independent stacks
- **Blast radius isolation**: Bad apply can't break unrelated services
- **DRY config**: Shared provider/backend configuration via Terragrunt
- **Proper DAG**: Full references between stacks (not hardcoded DNS strings)
- **Bootstrappable**: `terragrunt run-all apply` works from scratch
- **CI/CD**: Changed-stack detection in Drone CI

## Architecture: Flat Stacks

### Directory Structure

```
infra/
├── terragrunt.hcl              # Root config (providers, backend, common vars)
├── stacks/
│   ├── infra/                  # Proxmox VMs, templates, docker-registry
│   │   ├── terragrunt.hcl
│   │   └── main.tf
│   ├── platform/               # Core: traefik, metallb, redis, dbaas, authentik, etc.
│   │   ├── terragrunt.hcl
│   │   └── main.tf
│   ├── blog/                   # One dir per user service
│   │   ├── terragrunt.hcl
│   │   └── main.tf
│   ├── immich/
│   │   ├── terragrunt.hcl
│   │   └── main.tf
│   └── ... (~65 service dirs)
├── modules/                    # UNCHANGED — existing modules stay where they are
│   ├── kubernetes/
│   │   ├── ingress_factory/
│   │   ├── setup_tls_secret/
│   │   ├── blog/
│   │   ├── immich/
│   │   └── ...
│   ├── create-vm/
│   └── create-template-vm/
├── state/                      # Per-stack state files
│   ├── infra/terraform.tfstate
│   ├── platform/terraform.tfstate
│   ├── blog/terraform.tfstate
│   └── ...
├── terraform.tfvars            # UNCHANGED — encrypted secrets
├── secrets/                    # UNCHANGED — TLS certs
├── main.tf                     # LEGACY — gradually emptied during migration
└── terraform.tfstate           # LEGACY — gradually emptied during migration
```

Each stack has a thin `main.tf` wrapper that calls the existing module via
`source = "../../modules/kubernetes/<service>"`. We do NOT use Terragrunt's
`terraform { source }` directive because our modules use relative paths
(`../ingress_factory`, `../setup_tls_secret`) that would break when Terragrunt
copies them to `.terragrunt-cache/`.

### Stack Composition

**Infra stack** (~10 resources):
- Proxmox VM templates (k8s, non-k8s, docker-registry)
- Docker registry VM
- Uses proxmox provider (not kubernetes/helm)

**Platform stack** (~200 resources, ~20 services):
- traefik, metallb, redis, dbaas, technitium, authentik, crowdsec, cloudflared
- monitoring (prometheus, alertmanager, grafana, loki, alloy)
- kyverno, metrics-server, nvidia, mailserver, authelia
- wireguard, headscale, xray, uptime-kuma, vaultwarden, reverse-proxy
- Exports outputs consumed by service stacks

**Per-service stacks** (~65, each 5-25 resources):
- One stack per user-facing service
- Each depends on platform via Terragrunt `dependency` block
- Some depend on other services (f1-stream -> coturn, etc.)

### Dependency Graph

```
                         ┌─────────┐
                         │  infra  │
                         └────┬────┘
                              │
                         ┌────▼────┐
                         │platform │  exports: redis_host, postgresql_host,
                         │         │  mysql_host, smtp_host, tls_secret_name, ...
                         └────┬────┘
                              │
         ┌────────┬───────────┼───────────┬────────┐
         │        │           │           │        │
    ┌────▼──┐ ┌───▼───┐ ┌────▼───┐ ┌─────▼──┐ ┌──▼───┐
    │ blog  │ │immich │ │ affine │ │ollama  │ │coturn│  ...
    └───────┘ └───────┘ └────────┘ └───┬────┘ └──┬───┘
                                       │         │
                                  ┌────▼───┐ ┌───▼──────┐
                                  │openclaw│ │f1-stream │
                                  │gramps  │ └──────────┘
                                  │ytdlp   │
                                  └────────┘
```

### Platform Stack Outputs

| Output | Value | Consumers |
|--------|-------|-----------|
| `redis_host` | `redis.redis.svc.cluster.local` | 10 services |
| `postgresql_host` | `postgresql.dbaas.svc.cluster.local` | 10 services |
| `postgresql_port` | `5432` | 10 services |
| `mysql_host` | `mysql.dbaas.svc.cluster.local` | 8 services |
| `mysql_port` | `3306` | 8 services |
| `smtp_host` | `mail.viktorbarzin.me` | 6 services |
| `smtp_port` | `587` | 6 services |
| `tls_secret_name` | from variable | all services |
| `authentik_outpost_url` | `http://ak-outpost-...` | traefik |
| `crowdsec_lapi_host` | `crowdsec-service...` | traefik |
| `alertmanager_url` | `http://prometheus-alertmanager...` | loki |
| `loki_push_url` | `http://loki...` | alloy |

Service-to-service dependencies:

| Service | Depends on | Outputs consumed |
|---------|-----------|-----------------|
| f1-stream | coturn | `coturn_host`, `coturn_port` |
| real-estate-crawler | osm-routing | `osrm_foot_host`, `osrm_bicycle_host` |
| openclaw, grampsweb, ytdlp | ollama | `ollama_host` |

### Module Modifications

Service modules that hardcode DNS names need modification to accept hosts as variables.
~20 modules affected. Example for affine:

**Before:**
```hcl
# modules/kubernetes/affine/main.tf
DATABASE_URL      = "postgresql://...@postgresql.dbaas.svc.cluster.local:5432/affine"
REDIS_SERVER_HOST = "redis.redis.svc.cluster.local"
```

**After:**
```hcl
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "postgresql_port" { type = number }

DATABASE_URL      = "postgresql://...@${var.postgresql_host}:${var.postgresql_port}/affine"
REDIS_SERVER_HOST = var.redis_host
```

## Root Terragrunt Configuration

```hcl
# infra/terragrunt.hcl

remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    path = "${get_repo_root()}/state/${path_relative_to_include()}/terraform.tfstate"
  }
}

terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = [
      "${get_repo_root()}/terraform.tfvars"
    ]
  }
}

generate "k8s_providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

provider "kubernetes" {
  config_path = var.kube_config_path
}

provider "helm" {
  kubernetes {
    config_path = var.kube_config_path
  }
}
EOF
}
```

## Stack Wrapper Examples

### Simple service (blog)

```hcl
# stacks/blog/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path = "../platform"
}

inputs = {
  tls_secret_name = dependency.platform.outputs.tls_secret_name
}
```

```hcl
# stacks/blog/main.tf
variable "tls_secret_name" {}
variable "kube_config_path" { default = "~/.kube/config" }

module "blog" {
  source          = "../../modules/kubernetes/blog"
  tls_secret_name = var.tls_secret_name
  tier            = "4-aux"
}
```

### Database-backed service (affine)

```hcl
# stacks/affine/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path = "../platform"
}

inputs = {
  tls_secret_name = dependency.platform.outputs.tls_secret_name
  redis_host      = dependency.platform.outputs.redis_host
  postgresql_host = dependency.platform.outputs.postgresql_host
  postgresql_port = dependency.platform.outputs.postgresql_port
  smtp_host       = dependency.platform.outputs.smtp_host
  smtp_port       = dependency.platform.outputs.smtp_port
}
```

```hcl
# stacks/affine/main.tf
variable "tls_secret_name" {}
variable "kube_config_path" { default = "~/.kube/config" }
variable "affine_postgresql_password" {}
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "postgresql_port" { type = number }
variable "smtp_host" { type = string }
variable "smtp_port" { type = number }

module "affine" {
  source              = "../../modules/kubernetes/affine"
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.affine_postgresql_password
  redis_host          = var.redis_host
  postgresql_host     = var.postgresql_host
  postgresql_port     = var.postgresql_port
  smtp_host           = var.smtp_host
  smtp_port           = var.smtp_port
  tier                = "4-aux"
}
```

### Service-to-service dependency (f1-stream -> coturn)

```hcl
# stacks/f1-stream/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path = "../platform"
}

dependency "coturn" {
  config_path = "../coturn"
}

inputs = {
  tls_secret_name = dependency.platform.outputs.tls_secret_name
  coturn_host     = dependency.coturn.outputs.coturn_host
  coturn_port     = dependency.coturn.outputs.coturn_port
}
```

## Migration Strategy

### Phase 0: Setup
- Install Terragrunt
- Create root `terragrunt.hcl`, `stacks/`, `state/` directories
- No state changes, no risk

### Phase 1: Infra Stack (VMs)
- Create `stacks/infra/` with Proxmox provider + VM module calls
- `terraform state mv` 4 root-level module resources to `state/infra/`
- Remove from root `main.tf`
- Verify: `cd stacks/infra && terragrunt plan` shows no changes

### Phase 2: Platform Stack (Core Services)
- Create `stacks/platform/main.tf` with ~20 core services + outputs
- `terraform state mv` ~200 resources from `module.kubernetes_cluster.module.<core>`
- Remove `null_resource.core_services` (Terragrunt handles ordering)
- Verify: `cd stacks/platform && terragrunt plan` shows no changes

### Phase 3: Simple Services (No DB Dependencies)
- blog, echo, privatebin, excalidraw, city-guesser, dashy, etc.
- Create stack, move state, verify — one at a time

### Phase 4: Database-Backed Services
- Modify modules to accept hosts as variables
- affine, immich, linkwarden, nextcloud, grampsweb, etc.
- Create stack, move state, verify

### Phase 5: Service-to-Service Dependencies
- ollama -> openclaw, grampsweb, ytdlp
- coturn -> f1-stream
- osm-routing -> real-estate-crawler

### Phase 6: Cleanup
- Delete DEFCON system from `modules/kubernetes/main.tf`
- Delete legacy `terraform.tfstate`
- Delete root `main.tf` kubernetes_cluster module call
- Update CI/CD to Terragrunt

### Rollback
At any phase, `terraform state mv` resources back to monolith state and
restore module calls.

## CI/CD: Changed-Stack Detection

Drone CI pipeline detects changed files per commit and maps to affected stacks:

| Changed file | Affected stack |
|-------------|---------------|
| `stacks/blog/*` | blog |
| `modules/kubernetes/blog/*` | blog |
| `terraform.tfvars` | all stacks |
| `terragrunt.hcl` | all stacks |
| `modules/kubernetes/ingress_factory/*` | all stacks |

### Manual Workflow

```bash
# Apply single service
cd stacks/blog && terragrunt apply

# Apply everything (respects DAG ordering)
cd stacks && terragrunt run-all apply

# Plan everything
cd stacks && terragrunt run-all plan
```

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tool | Terragrunt | DRY config, dependency management, run-all orchestration |
| Stack granularity | 1 platform + 1 per service | Max isolation for apps, grouped core |
| Migration | Incremental | Lower risk, verify each step |
| Shared modules | Relative paths | Simple, no registry overhead |
| State backend | Local files | No external dependencies |
| Cross-stack refs | Full references via outputs | Proper DAG, bootstrappable from scratch |
| CI/CD | Changed-stack detection | Only apply what changed |
