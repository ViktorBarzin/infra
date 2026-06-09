# Codebase Structure

**Analysis Date:** 2026-02-23

## Directory Layout

```
/Users/viktorbarzin/code/infra/
├── .claude/                     # Project-level Claude knowledge (skills, reference docs)
├── .git/                        # Git repository metadata
├── .git-crypt/                  # git-crypt encryption keys
├── .planning/codebase/          # GSD codebase analysis documents
├── .terraform/                  # Terraform cache (gitignored)
├── .woodpecker/                 # CI/CD pipeline definitions
├── cli/                         # Custom CLI tools (bash/python scripts)
├── diagram/                     # Infrastructure diagram sources
├── docs/                        # Documentation (deployment guides, design docs)
├── modules/                     # Shared Terraform modules (Proxmox, K8s utilities)
├── playbooks/                   # Ansible playbooks (infrastructure setup)
├── scripts/                     # Maintenance scripts (healthcheck, DNS updates, etc.)
├── secrets/                     # git-crypt encrypted files (NFS dirs, TLS certs, SSH keys)
├── stacks/                      # Terragrunt stacks (platform + ~70 service stacks)
├── state/                       # Terraform state files (local backend, gitignored)
├── terragrunt.hcl              # Root Terragrunt config (DRY provider/backend setup)
├── terraform.tfvars            # All variables + secrets (git-crypt encrypted, ~48KB)
├── config                      # Kubernetes config (kubeconfig file)
├── README.md                   # Project overview
└── package.json               # Node.js deps (minimal; mostly for cli tools)
```

## Directory Purposes

**`.claude/`:**
- Purpose: Project-level Claude knowledge and execution skills
- Contains: `skills/` (setup-project, authentik workflows), `reference/` (inventory tables, API patterns)
- Key files: `CLAUDE.md` (this file's counterpart with full infrastructure context)

**`.planning/codebase/`:**
- Purpose: GSD codebase analysis output directory
- Contains: `ARCHITECTURE.md`, `STRUCTURE.md` (this file), and focus-specific docs
- Auto-generated: Yes (by /gsd:map-codebase)

**`modules/`:**
- Purpose: Reusable Terraform modules for VM creation and Kubernetes utilities
- Contains:
  - `create-template-vm/`: Cloud-init Ubuntu template VM provisioning (K8s + non-K8s)
  - `create-vm/`: VM instance creation from templates with cloud-init injection
  - `docker-registry/`: Docker registry pull-through cache setup
  - `kubernetes/`: K8s-specific utilities (ingress_factory, setup_tls_secret)

**`stacks/`:**
- Purpose: Terragrunt stacks with isolated state and per-service configuration
- Contains: 1 platform stack + ~70 application stacks
- Structure: Each stack is a directory with `terragrunt.hcl` + `main.tf` + optional `factory/` (for multi-instance services)

**`stacks/platform/`:**
- Purpose: Core infrastructure services (22 modules)
- Contains: Modules for MetalLB, DBaaS, Redis, Traefik, DNS, VPN, auth, monitoring, security
- Key subdirs: `modules/` (platform-specific modules like traefik, authentik, monitoring)

**`stacks/infra/`:**
- Purpose: Proxmox VM template and instance provisioning
- Contains: K8s node templates, docker-registry VM, Proxmox provider configuration

**`stacks/<service>/`:**
- Purpose: Single application stack with isolated state
- Pattern: `terragrunt.hcl` (includes root, declares dependencies) + `main.tf` (resources) + optional `factory/` + optional `chart_values.yaml`
- Examples: `nextcloud/`, `immich/`, `matrix/`, `actualbudget/` (multi-tenant), etc.

**`secrets/`:**
- Purpose: git-crypt encrypted sensitive files
- Contains: TLS certificates/keys, NFS export list, SSH keys, Dkim keys, Postfix config
- Key files:
  - `nfs_directories.txt`: List of NFS shares (sorted); regenerate exports with `nfs_exports.sh`
  - `tls/`: TLS certificate chain and keys
  - `mailserver/`: OpenDKIM keys, Postfix SASL creds

**`scripts/`:**
- Purpose: Operational and maintenance automation
- Key scripts:
  - `cluster_healthcheck.sh`: 24-point cluster health status
  - `renew2.sh`: TLS certificate renewal via certbot + Cloudflare
  - `setup_certs.sh`: Initial certificate setup
  - `pve_*`: Proxmox management scripts
  - `ha_*`: Home Assistant integration scripts

**`docs/`:**
- Purpose: Design and deployment documentation
- Contains: High-level architecture diagrams, deployment guides, troubleshooting

**`cli/`:**
- Purpose: Custom CLI utilities
- Contains: Python/bash scripts for common operations (DNS management, NFS, etc.)

## Key File Locations

**Entry Points:**
- `terragrunt.hcl`: Root Terragrunt config; invoked by `terragrunt apply` in any stack directory
- `stacks/platform/main.tf`: Platform stack; applies 22 core modules
- `stacks/infra/main.tf`: Infrastructure stack; creates VM templates and docker-registry VM

**Configuration:**
- `terraform.tfvars`: Central variables file (~48KB, git-crypt encrypted). Used by all stacks. Contains: Cloudflare credentials, DNS records, service secrets, TLS secret name
- `stacks/<service>/terragrunt.hcl`: Stack-specific Terragrunt config (includes root, declares `dependency` blocks)
- `stacks/platform/modules/<service>/main.tf`: Platform module implementation (22 modules)

**Core Logic:**
- `stacks/platform/main.tf`: 1000+ lines; instantiates all 22 platform modules
- `stacks/<service>/main.tf`: 30–450 lines; creates namespaces, Helm releases, Kubernetes resources
- `stacks/<service>/factory/main.tf`: Multi-instance service pattern; called multiple times with different parameters
- `modules/kubernetes/ingress_factory/main.tf`: Traefik ingress + service template with security defaults

**Testing & Validation:**
- `.woodpecker/`: CI/CD pipeline (pushes platform apply on merge)
- `scripts/cluster_healthcheck.sh`: Manual cluster health validation

**Kubernetes & Cluster Config:**
- `config`: Kubeconfig file for cluster access
- Namespace pattern: One namespace per service stack
- TLS secret: `tls-secret` injected into all namespaces via `setup_tls_secret` module

## Naming Conventions

**Files:**
- `main.tf`: Primary Terraform resource file per stack
- `terragrunt.hcl`: Terragrunt-specific configuration (includes root, dependencies)
- `terraform.tfvars`: Global variables (git-crypt encrypted)
- `chart_values.yaml`: Helm chart values template (uses templatefile for variable substitution)
- `*_values.tpl`: Helm values template (evaluated with templatefile)
- `.terraform.lock.hcl`: Provider lock file (one per stack)

**Directories:**
- `stacks/<service>/`: Kebab-case service names (e.g., `real-estate-crawler`, `k8s-dashboard`)
- `stacks/platform/modules/<service>/`: Kebab-case module names
- `state/stacks/<service>/`: Mirrored state directory structure
- `secrets/`: Single top-level directory for all encrypted files
- `modules/kubernetes/`, `modules/create-template-vm/`: Category-based grouping

**Terraform Resources:**
- **Kubernetes**: `kubernetes_*` (namespace, deployment, service, configmap, etc.)
- **Helm**: `helm_release` (Helm chart deployments)
- **Local files**: `local_file` (for generated scripts and configs)
- **Module calls**: `module "<short-name>"` (e.g., `module "traefik"`, `module "redis"`)

**Variables:**
- Snake_case: `tls_secret_name`, `crowdsec_api_key`, `nextcloud_db_password`
- Service-prefixed: `<service>_<attribute>` (e.g., `authentik_secret_key`, `mailserver_accounts`)

## Where to Add New Code

**New Service Stack:**
1. Create `stacks/<service>/` directory
2. Add `terragrunt.hcl`:
   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }
   dependency "platform" {
     config_path = "../platform"
     skip_outputs = true
   }
   ```
3. Create `main.tf` with:
   - Variable declarations for required inputs from `terraform.tfvars`
   - `locals { tiers = { ... } }` (copy from existing stack)
   - `kubernetes_namespace` resource with tier label
   - `module "tls_secret"` call to `../../modules/kubernetes/setup_tls_secret`
   - Service-specific resources (Helm releases, Deployments, etc.)
4. Add Cloudflare DNS records in `terraform.tfvars` if needed
5. Create optional `secrets/` symlink: `ln -s ../../secrets secrets`
6. Apply: `cd stacks/<service> && terragrunt apply --non-interactive`

**Multi-Tenant Service (using Factory Pattern):**
1. Create parent stack: `stacks/<service>/main.tf` with namespace + TLS setup
2. Create `stacks/<service>/factory/main.tf` with single-instance logic
3. In parent, call factory multiple times:
   ```hcl
   module "instance1" {
     source = "./factory"
     name = "instance1"
     # ... other params
   }
   ```
4. Example: `stacks/actualbudget/` has factory instantiated for viktor, anca, emo

**New Platform Module:**
1. Create `stacks/platform/modules/<service>/` directory
2. Add `main.tf` with resources (Helm chart, namespace, ConfigMaps, etc.)
3. Add `variables.tf` or declare variables in `main.tf`
4. In `stacks/platform/main.tf`, add module call:
   ```hcl
   module "<service>" {
     source = "./modules/<service>"
     tier = local.tiers.<tier>
     # ... pass required variables
   }
   ```
5. Add variable declarations in `stacks/platform/main.tf`

**New Shared Module:**
1. Create `modules/kubernetes/<module_name>/` or `modules/terraform/<module_name>/`
2. Add `main.tf` with reusable resources
3. Declare clear variable inputs and output any useful values
4. Call from service stacks: `module "<name>" { source = "../../modules/kubernetes/<module_name>" ... }`

**Utilities & Scripts:**
- Shared helpers: `scripts/` directory
- Custom CLI tools: `cli/` directory
- CI/CD pipelines: `.woodpecker/`

## Special Directories

**`state/`:**
- Purpose: Terraform state files (local backend)
- Generated: Yes (automatically by Terragrunt)
- Committed: No (gitignored; backed up separately)
- Structure: `state/stacks/<service>/terraform.tfstate`

**`secrets/`:**
- Purpose: git-crypt encrypted secrets and sensitive config
- Generated: No (managed manually or via scripts)
- Committed: Yes (encrypted via git-crypt)
- Contents: TLS certs, SSH keys, NFS export list, mailserver config, Dkim keys

**`.terraform/`:**
- Purpose: Terraform provider cache
- Generated: Yes (by Terraform during init)
- Committed: No (gitignored)

**`node_modules/`:**
- Purpose: Node.js dependencies for CLI tools
- Generated: Yes (by npm install)
- Committed: No (gitignored; use lockfile)

## File Patterns & Imports

**Terragrunt Patterns:**
- Include root: `include "root" { path = find_in_parent_folders() }`
- Declare dependencies: `dependency "platform" { config_path = "../platform"; skip_outputs = true }`
- Variable access: `var.<name>` in `main.tf` (variables sourced from `terraform.tfvars`)

**Kubernetes Resource Patterns:**
- Namespace per service: `kubernetes_namespace.<service>` with tier label
- Helm releases: `helm_release.<chart_name>` with `templatefile` for values
- Inline NFS volumes: `volume { name = "data"; nfs { server = "10.0.10.15"; path = "/mnt/main/<service>" } }`
- TLS injection: Every stack calls `module "tls_secret"` to populate namespace secret

**Module Call Pattern:**
- Standard: `module "<name>" { source = "./modules/<module>" ... }`
- Platform modules: `source = "./modules/<service>"`
- Shared modules: `source = "../../modules/kubernetes/<module>"`

---

*Structure analysis: 2026-02-23*
