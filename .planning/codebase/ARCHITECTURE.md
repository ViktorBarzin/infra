# Architecture

**Analysis Date:** 2026-02-23

## Pattern Overview

**Overall:** Terragrunt-based IaC with per-service state isolation, using Kubernetes as the primary platform and Proxmox for VM infrastructure.

**Key Characteristics:**
- Monorepo containing ~70 service stacks with independent state files
- Declarative, GitOps-driven infrastructure using Terraform + Terragrunt
- DRY provider/backend configuration via root `terragrunt.hcl`
- Clear layering: platform (core/cluster services) → application stacks → shared modules
- Service decoupling with explicit dependencies via `dependency` blocks
- Resource governance through Kubernetes tier system (0-core through 4-aux)

## Layers

**Platform Layer (`stacks/platform/main.tf`):**
- Purpose: Core infrastructure services that enable all application stacks (22 modules)
- Location: `stacks/platform/`
- Contains: MetalLB, DBaaS, Redis, Traefik, Technitium DNS, Headscale VPN, Authentik SSO, RBAC, CrowdSec, Prometheus/Grafana/Loki monitoring, nginx reverse proxy, mailserver, GPU node configuration, Kyverno policy engine
- Depends on: Kubernetes cluster (declared via `stacks/infra` dependency), External secrets in `terraform.tfvars`
- Used by: All application stacks declare `dependency "platform"` to ensure platform is applied first

**Infrastructure Layer (`stacks/infra/main.tf`):**
- Purpose: VM template provisioning and Proxmox resource management
- Location: `stacks/infra/`
- Contains: K8s node templates via cloud-init, docker-registry VM, Proxmox VM lifecycle
- Depends on: Proxmox API credentials
- Used by: Platform stack depends on it to ensure infrastructure is ready

**Application Stacks (~70 services):**
- Purpose: User-facing and supplementary services (Nextcloud, Immich, Matrix, Ollama, etc.)
- Location: `stacks/<service>/main.tf` (102 total stacks)
- Contains: Kubernetes namespaces, Helm releases, raw Kubernetes resources (Deployments, StatefulSets, Services, PersistentVolumes)
- Depends on: Platform stack, shared TLS secret via `modules/kubernetes/setup_tls_secret`, optional NFS volumes
- Used by: Self-contained; declared dependencies control execution order

**Shared Modules:**
- **Kubernetes utilities** (`modules/kubernetes/`):
  - `ingress_factory/`: Reusable Traefik ingress + service template with anti-AI scraping, CrowdSec integration, rate limiting, authentication support
  - `setup_tls_secret/`: TLS certificate secret setup in namespaces
- **Terraform modules** (`modules/`):
  - `create-template-vm/`: Ubuntu cloud-init template VM provisioning (K8s and non-K8s variants)
  - `create-vm/`: VM instance creation from templates
  - `docker-registry/`: Docker registry pull-through cache configuration

## Data Flow

**Infrastructure Provisioning Flow:**

1. **Initialize**: Root `terragrunt.hcl` loads `terraform.tfvars` globally, generates provider/backend configs
2. **Infra Stack Apply**: `stacks/infra/` creates/updates Proxmox VMs and Kubernetes node templates
3. **Platform Apply**: `stacks/platform/` applies all ~22 core services (depends on infra stack)
4. **Service Apply**: Individual `stacks/<service>/` apply their resources (depend on platform stack)

Example dependency chain for Nextcloud:
```
stacks/infra/main.tf (VMs)
  ↓ (dependency)
stacks/platform/main.tf (Traefik, Redis, DBaaS, etc.)
  ↓ (dependency)
stacks/nextcloud/main.tf (Nextcloud Helm chart + storage)
```

**State Management:**
- Each stack has isolated state at `state/stacks/<service>/terraform.tfstate`
- Root `terragrunt.hcl` defines local backend: `path = "${get_repo_root()}/state/${path_relative_to_include()}/terraform.tfstate"`
- Variables flow from `terraform.tfvars` → each stack's `terraform` block → Terraform execution
- Unused variables are silently ignored (Terraform 1.x behavior)

**Configuration Flow:**
1. User edits `terraform.tfvars` (encrypted via git-crypt)
2. Each stack includes root terragrunt config: `include "root" { path = find_in_parent_folders() }`
3. Root config injects `terraform.tfvars` as `required_var_files`
4. Stack-specific `main.tf` declares which variables it uses

## Key Abstractions

**Tier System:**
- Purpose: Resource governance via Kubernetes PriorityClasses, LimitRanges, ResourceQuotas
- Tiers: `0-core` (critical: ingress, DNS, auth) → `4-aux` (optional workloads)
- Applied via: Kyverno policy engine in `stacks/platform/modules/kyverno/`
- Usage: Every namespace/pod gets labeled with tier; Kyverno generates corresponding LimitRange + ResourceQuota

**Service Factory Pattern:**
- Purpose: Multi-tenant/multi-instance services (Actual Budget, Freedify)
- Pattern: Parent stack (`stacks/<service>/main.tf`) creates namespace + TLS secret, then calls `factory/` module multiple times
- Examples: `stacks/actualbudget/main.tf` calls `factory/` for viktor, anca, emo instances
- Each instance: Separate pod, service, NFS share, Cloudflare DNS entry

**Ingress Factory (`modules/kubernetes/ingress_factory/`):**
- Purpose: DRY, opinionated Traefik ingress pattern with security defaults
- Variables: `name`, `namespace`, `port`, `host`, `protected`, `anti_ai_scraping` (default true)
- Provides: Service, Ingress, CrowdSec exemptions, rate limiting, Authentik ForwardAuth integration, anti-AI middleware
- Anti-AI layers: Bot blocking → X-Robots-Tag → Trap links → Tarpit → Poison content cache

**NFS Volume Pattern:**
- Purpose: Persistent storage for stateful services
- Pattern: Inline NFS volumes in pod specs (preferred over PV/PVC)
- Server: `10.0.10.15` (TrueNAS)
- Paths: `/mnt/main/<service>` or `/mnt/main/<service>/<instance>`
- Used by: ~60 services; registered in `secrets/nfs_directories.txt` (git-crypt encrypted)

## Entry Points

**Terragrunt Root (`terragrunt.hcl`):**
- Location: `/Users/viktorbarzin/code/infra/terragrunt.hcl`
- Triggers: `cd stacks/<service> && terragrunt plan/apply --non-interactive`
- Responsibilities: Load providers, backend, `terraform.tfvars`, set kube config path

**Platform Stack (`stacks/platform/main.tf`):**
- Location: `stacks/platform/main.tf` (1000+ lines)
- Triggers: Applied before any service stack to ensure platform services exist
- Responsibilities: 22 module instantiations, tier definition, variable collection from tfvars

**Service Stacks (`stacks/<service>/main.tf`):**
- Location: `stacks/<service>/main.tf` (27–456 lines, avg ~130)
- Triggers: `terragrunt apply --non-interactive` in service directory
- Responsibilities: Create namespace, setup TLS, instantiate Helm charts or raw K8s resources, configure storage

**Proxmox/Infra Stack (`stacks/infra/main.tf`):**
- Location: `stacks/infra/main.tf` (200+ lines)
- Triggers: Applied first to ensure VM infrastructure is available
- Responsibilities: VM template creation, VM instance lifecycle, containerd mirror config

**Factory Module (`stacks/<service>/factory/main.tf`):**
- Location: `stacks/actualbudget/factory/main.tf`, `stacks/freedify/factory/main.tf`
- Triggers: Called multiple times from parent `main.tf` with different `name` parameter
- Responsibilities: Single-instance deployment (pod, service, NFS share, ingress)

## Error Handling

**Strategy:** Declarative state reconciliation (Terraform/Kubernetes watch loop). No imperative error recovery.

**Patterns:**
- **Helm deployments**: `atomic = true` for rollback on failure
- **Terraform apply**: `--non-interactive` to prevent hanging on prompts
- **Cloud-init VM provisioning**: Embedded error logging in scripts; check `/var/log/cloud-init-output.log` on VM
- **Dependencies**: Explicit `dependency` blocks prevent applying child before parent
- **Validation**: `terraform plan` executed by CI before apply
- **Secrets**: git-crypt locking ensures encrypted state checked into repo; no accidental plaintext commits

## Cross-Cutting Concerns

**Logging:** Loki + Alloy (DaemonSet collects container logs) configured in `stacks/platform/modules/monitoring/`

**Validation:**
- Terraform validation: `terraform validate` in CI/CD pipeline
- HCL formatting: `terraform fmt -recursive`
- Kyverno policies: Enforce resource requests, tier labels, pod security standards

**Authentication:**
- **Kubernetes API**: OIDC via Authentik (issuer: `https://authentik.viktorbarzin.me/application/o/kubernetes/`)
- **Traefik Ingress**: Authentik ForwardAuth when `protected = true` in ingress_factory
- **TLS**: Shared secret injected into all namespaces via `setup_tls_secret` module

**Rate Limiting:** Traefik middleware `default-rate-limit` (applied by ingress_factory unless `skip_default_rate_limit = true`)

**Anti-AI Scraping:** 5-layer defense (bot blocking → headers → trap links → tarpit → poison content) applied via `anti_ai_scraping = true` (default) in ingress_factory; disable per-service with `anti_ai_scraping = false`

---

*Architecture analysis: 2026-02-23*
