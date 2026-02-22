# Terragrunt Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate the monolithic Terraform setup (857 resources, 15MB state) to Terragrunt with per-service state isolation, proper DAG dependencies, and changed-stack CI/CD detection.

**Architecture:** Flat stacks under `stacks/` with thin `main.tf` wrappers calling existing modules. Root `terragrunt.hcl` provides DRY provider/backend config. Platform stack groups ~20 core services and exports outputs (redis_host, postgresql_host, etc.) consumed by ~65 per-service stacks via Terragrunt `dependency` blocks.

**Tech Stack:** Terragrunt, Terraform 1.14.x, local state backend, Drone CI

**Design Doc:** `docs/plans/2026-02-22-terragrunt-migration-design.md`

---

## Task 1: Install Terragrunt and Create Directory Skeleton

**Files:**
- Create: `stacks/` directory
- Create: `state/` directory
- Create: `.gitignore` updates

**Step 1: Install Terragrunt**

Run:
```bash
brew install terragrunt
```
Expected: Terragrunt available at `terragrunt --version`

**Step 2: Create directory skeleton**

Run:
```bash
mkdir -p stacks/{infra,platform}
mkdir -p state
```

**Step 3: Update `.gitignore`**

Add to `.gitignore`:
```
# Terragrunt
.terragrunt-cache/
state/
```

The `state/` directory contains per-stack terraform state files. These are local-only and should not be committed (they contain resource IDs and potentially sensitive data, same as the current `terraform.tfstate`).

**Step 4: Commit**

```bash
git add stacks/ .gitignore
git commit -m "[ci skip] Add Terragrunt directory skeleton"
```

---

## Task 2: Create Root Terragrunt Configuration

**Files:**
- Create: `terragrunt.hcl`

**Step 1: Write root terragrunt.hcl**

```hcl
# Root Terragrunt configuration
# Provides DRY provider, backend, and variable loading for all stacks.

# Each stack gets its own local state file under state/<stack-name>/
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

# Load terraform.tfvars for all stacks.
# Variables not declared by a stack are silently ignored (Terraform 1.x behavior).
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = [
      "${get_repo_root()}/terraform.tfvars"
    ]
  }

  extra_arguments "kube_config" {
    commands = get_terraform_commands_that_need_vars()
    arguments = [
      "-var", "kube_config_path=${get_repo_root()}/config"
    ]
  }
}

# Generate kubernetes + helm providers for K8s stacks.
# The infra stack overrides this to add the proxmox provider.
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

**Step 2: Verify Terragrunt parses it**

Run:
```bash
cd stacks/infra && terragrunt validate-inputs 2>&1 | head -5
```
Expected: No parse errors (may show warnings about missing main.tf, that's fine)

**Step 3: Commit**

```bash
git add terragrunt.hcl
git commit -m "[ci skip] Add root Terragrunt configuration"
```

---

## Task 3: Create Infra Stack (Proxmox VMs)

**Files:**
- Create: `stacks/infra/terragrunt.hcl`
- Create: `stacks/infra/main.tf`

**Step 1: Write infra terragrunt.hcl**

This stack needs the proxmox provider instead of (or in addition to) the default k8s providers.

```hcl
# stacks/infra/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

# Override provider generation to include proxmox
generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

variable "proxmox_pm_api_url" { type = string }
variable "proxmox_pm_api_token_id" { type = string }
variable "proxmox_pm_api_token_secret" { type = string }

provider "proxmox" {
  pm_api_url          = var.proxmox_pm_api_url
  pm_api_token_id     = var.proxmox_pm_api_token_id
  pm_api_token_secret = var.proxmox_pm_api_token_secret
  pm_tls_insecure     = true
}
EOF
}
```

**Step 2: Write infra main.tf**

Copy the VM template and docker-registry module calls from the current root `main.tf` (lines 196-400). These reference `./modules/create-template-vm` and `./modules/create-vm` — adjust paths to `../../modules/...`.

```hcl
# stacks/infra/main.tf
# Proxmox VM templates and docker registry VM

variable "proxmox_host" { type = string }
variable "ssh_private_key" {
  type    = string
  default = ""
}
variable "ssh_public_key" {
  type    = string
  default = ""
}
variable "vm_wizard_password" { type = string }
variable "k8s_join_command" { type = string }
variable "dockerhub_registry_password" { type = string }

locals {
  k8s_vm_template             = "ubuntu-2404-cloudinit-k8s-template"
  k8s_cloud_init_snippet_name = "k8s_cloud_init.yaml"
  k8s_cloud_init_image_path   = "/var/lib/vz/template/iso/noble-server-cloudimg-amd64-k8s.img"

  non_k8s_vm_template             = "ubuntu-2404-cloudinit-non-k8s-template"
  non_k8s_cloud_init_snippet_name = "non_k8s_cloud_init.yaml"
  non_k8s_cloud_init_image_path   = "/var/lib/vz/template/iso/noble-server-cloudimg-amd64-non-k8s.img"

  cloud_init_image_url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

module "k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root"

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.k8s_cloud_init_image_path
  template_id     = 2000
  template_name   = local.k8s_vm_template
  user_passwd     = var.vm_wizard_password

  is_k8s_template = true
  snippet_name    = local.k8s_cloud_init_snippet_name
  containerd_config_update_command = <<-EOF
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
  mkdir -p /etc/containerd/certs.d/docker.io
  printf 'server = "https://registry-1.docker.io"\n\n[host."http://10.0.20.10:5000"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/docker.io/hosts.toml
  mkdir -p /etc/containerd/certs.d/ghcr.io
  printf 'server = "https://ghcr.io"\n\n[host."http://10.0.20.10:5010"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/ghcr.io/hosts.toml
  mkdir -p /etc/containerd/certs.d/quay.io
  printf 'server = "https://quay.io"\n\n[host."http://10.0.20.10:5020"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/quay.io/hosts.toml
  mkdir -p /etc/containerd/certs.d/registry.k8s.io
  printf 'server = "https://registry.k8s.io"\n\n[host."http://10.0.20.10:5030"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/registry.k8s.io/hosts.toml
  mkdir -p /etc/containerd/certs.d/reg.kyverno.io
  printf 'server = "https://reg.kyverno.io"\n\n[host."http://10.0.20.10:5040"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/reg.kyverno.io/hosts.toml
  sed -i 's/.*max_concurrent_downloads = 3/max_concurrent_downloads = 20/g' /etc/containerd/config.toml
  sudo sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml && \
  sudo sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml && \
  echo -e 'serializeImagePulls: false\nmaxParallelImagePulls: 50' | sudo tee -a /var/lib/kubelet/config.yaml
  EOF
  k8s_join_command = var.k8s_join_command
}

module "non-k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root"

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path
  template_id     = 1000
  template_name   = local.non_k8s_vm_template
  user_passwd     = var.vm_wizard_password

  is_k8s_template = false
  snippet_name    = local.non_k8s_cloud_init_snippet_name
}

module "docker-registry-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root"

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHLhYDfyx237eJgOGVoJRECpUS95+7rEBS9vacsIxtx devvm"

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path
  template_id     = 1001
  template_name   = "docker-registry-template"

  user_passwd     = var.vm_wizard_password
  is_k8s_template = false
  snippet_name    = "docker-registry.yaml"

  provision_cmds = [
    "mkdir -p /etc/docker-registry",
    format("echo %s | base64 -d > /etc/docker-registry/config.yml",
      base64encode(
        templatefile("${path.root}/../../modules/docker-registry/config.yaml", {
          password = var.dockerhub_registry_password
        })
      )
    ),
    # ... (copy remaining provision_cmds from main.tf lines 305-371)
  ]
}

module "docker-registry-vm" {
  source         = "../../modules/create-vm"
  vmid           = 220
  vm_cpus        = 4
  vm_mem_mb      = 4196
  vm_disk_size   = "64G"
  template_name  = "docker-registry-template"
  vm_name        = "docker-registry"
  cisnippet_name = "docker-registry.yaml"
  vm_mac_address = "DE:AD:BE:EF:22:22"
  bridge         = "vmbr1"
  vlan_tag       = "20"
  ipconfig0      = "ip=10.0.20.10/24,gw=10.0.20.1"
}
```

**Note:** The `provision_cmds` for docker-registry-template is long (~60 lines). Copy it exactly from the current `main.tf` lines 296-371. The only change is `templatefile` paths: prefix with `${path.root}/../../` since the working directory is now `stacks/infra/`.

**Step 3: Verify with init (do NOT apply yet)**

Run:
```bash
cd stacks/infra && terragrunt init
```
Expected: Successful init, providers downloaded

**Step 4: Commit**

```bash
git add stacks/infra/
git commit -m "[ci skip] Add infra stack (Proxmox VMs)"
```

---

## Task 4: Migrate Infra Stack State

**CRITICAL: This task modifies live state. Take a backup first.**

**Step 1: Backup current state**

Run:
```bash
cp terraform.tfstate terraform.tfstate.backup-pre-terragrunt
```

**Step 2: List current infra resources in state**

Run:
```bash
terraform state list | grep -E '^module\.(k8s-node-template|non-k8s-node-template|docker-registry-template|docker-registry-vm)\.'
```
Expected: List of ~10 resources belonging to these 4 modules

**Step 3: Move resources to new state file**

For each resource listed in step 2, run:
```bash
mkdir -p state/infra
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/infra/terraform.tfstate \
  'module.k8s-node-template' 'module.k8s-node-template'
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/infra/terraform.tfstate \
  'module.non-k8s-node-template' 'module.non-k8s-node-template'
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/infra/terraform.tfstate \
  'module.docker-registry-template' 'module.docker-registry-template'
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/infra/terraform.tfstate \
  'module.docker-registry-vm' 'module.docker-registry-vm'
```

**Step 4: Verify no changes in new state**

Run:
```bash
cd stacks/infra && terragrunt plan
```
Expected: `No changes. Infrastructure is up-to-date.`

If there are changes, something went wrong — restore from backup and investigate.

**Step 5: Remove infra modules from root main.tf**

Remove (or comment out) the `module.k8s-node-template`, `module.non-k8s-node-template`, `module.docker-registry-template`, and `module.docker-registry-vm` blocks from `main.tf` (lines 208-400).

Also remove the corresponding `locals` block (lines 196-206) since they're now in `stacks/infra/main.tf`.

**Step 6: Verify legacy state is clean**

Run:
```bash
terraform plan -var="kube_config_path=$(pwd)/config"
```
Expected: No changes (the moved resources are gone from this state but also from main.tf)

**Step 7: Commit**

```bash
git add main.tf stacks/infra/
git commit -m "[ci skip] Migrate infra stack (VMs) to Terragrunt"
```

---

## Task 5: Create Platform Stack

**Files:**
- Create: `stacks/platform/terragrunt.hcl`
- Create: `stacks/platform/main.tf`

This is the largest task — it groups ~20 core services into one stack.

**Step 1: Write platform terragrunt.hcl**

```hcl
# stacks/platform/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "infra" {
  config_path = "../infra"
  skip_outputs = true
}
```

**Step 2: Write platform main.tf**

This file contains all core/cluster service module calls. Copy each from `modules/kubernetes/main.tf`, adjusting `source` paths from `"./<service>"` to `"../../modules/kubernetes/<service>"`. Remove `for_each` conditionals (core services are always present). Remove `depends_on = [null_resource.core_services]`.

Platform services (from `modules/kubernetes/main.tf`):

```hcl
# stacks/platform/main.tf

# Variables — declare all variables needed by platform services
variable "kube_config_path" { default = "~/.kube/config" }
variable "tls_secret_name" {}
variable "prod" { default = false }

# dbaas vars
variable "dbaas_root_password" {}
variable "dbaas_postgresql_root_password" {}
variable "dbaas_pgadmin_password" {}

# traefik vars
variable "ingress_crowdsec_api_key" {}

# technitium vars
variable "technitium_db_password" {}
variable "homepage_credentials" { type = map(any) }

# headscale vars
variable "headscale_config" {}
variable "headscale_acl" {}

# authentik vars
variable "authentik_secret_key" {}
variable "authentik_postgres_password" {}
variable "k8s_users" { type = map(any); default = {} }
variable "ssh_private_key" { type = string; default = ""; sensitive = true }

# crowdsec vars
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" { type = string }
variable "crowdsec_dash_api_key" { type = string }
variable "crowdsec_dash_machine_id" { type = string }
variable "crowdsec_dash_machine_password" { type = string }
variable "alertmanager_slack_api_url" {}

# cloudflared vars
variable "cloudflare_api_key" {}
variable "cloudflare_email" {}
variable "cloudflare_account_id" {}
variable "cloudflare_zone_id" {}
variable "cloudflare_tunnel_id" {}
variable "public_ip" {}
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}
variable "cloudflare_tunnel_token" {}

# monitoring vars
variable "alertmanager_account_password" {}
variable "idrac_username" { default = "" }
variable "idrac_password" { default = "" }
variable "tiny_tuya_service_secret" { type = string }
variable "haos_api_token" { type = string }
variable "pve_password" { type = string }
variable "grafana_db_password" { type = string }
variable "grafana_admin_password" { type = string }

# vaultwarden vars
variable "vaultwarden_smtp_password" {}

# reverse-proxy vars (homepage tokens are in homepage_credentials)

# wireguard vars
variable "wireguard_wg_0_conf" {}
variable "wireguard_wg_0_key" {}
variable "wireguard_firewall_sh" {}

# xray vars
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" { type = string }
variable "xray_reality_short_ids" { type = list(string) }

# nvidia vars (none beyond tls_secret_name + tier)

# mailserver vars
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "mailserver_sasl_passwd" {}
variable "mailserver_roundcubemail_db_password" { type = string }

# infra-maintenance vars
variable "webhook_handler_git_user" {}
variable "webhook_handler_git_token" {}
variable "technitium_username" {}
variable "technitium_password" {}

# uptime-kuma (no extra vars)
# metrics-server (no extra vars)
# kyverno (no extra vars)

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

# --- Core Services (no dependencies, deployed first) ---

module "metallb" {
  source = "../../modules/kubernetes/metallb"
  tier   = local.tiers.core
}

module "dbaas" {
  source                   = "../../modules/kubernetes/dbaas"
  prod                     = var.prod
  tls_secret_name          = var.tls_secret_name
  dbaas_root_password      = var.dbaas_root_password
  postgresql_root_password = var.dbaas_postgresql_root_password
  pgadmin_password         = var.dbaas_pgadmin_password
  tier                     = local.tiers.cluster
}

module "redis" {
  source          = "../../modules/kubernetes/redis"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.cluster
}

module "traefik" {
  source           = "../../modules/kubernetes/traefik"
  tier             = local.tiers.core
  crowdsec_api_key = var.ingress_crowdsec_api_key
  tls_secret_name  = var.tls_secret_name
}

module "technitium" {
  source                 = "../../modules/kubernetes/technitium"
  tls_secret_name        = var.tls_secret_name
  homepage_token         = var.homepage_credentials["technitium"]["token"]
  technitium_db_password = var.technitium_db_password
  tier                   = local.tiers.core
}

module "headscale" {
  source           = "../../modules/kubernetes/headscale"
  tls_secret_name  = var.tls_secret_name
  headscale_config = var.headscale_config
  headscale_acl    = var.headscale_acl
  tier             = local.tiers.core
}

module "authentik" {
  source            = "../../modules/kubernetes/authentik"
  tier              = local.tiers.cluster
  tls_secret_name   = var.tls_secret_name
  secret_key        = var.authentik_secret_key
  postgres_password = var.authentik_postgres_password
}

module "rbac" {
  source          = "../../modules/kubernetes/rbac"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = var.k8s_users
  ssh_private_key = var.ssh_private_key
}

module "k8s-portal" {
  source          = "../../modules/kubernetes/k8s-portal"
  tier            = local.tiers.edge
  tls_secret_name = var.tls_secret_name
}

module "crowdsec" {
  source                         = "../../modules/kubernetes/crowdsec"
  tier                           = local.tiers.cluster
  tls_secret_name                = var.tls_secret_name
  homepage_username              = var.homepage_credentials["crowdsec"]["username"]
  homepage_password              = var.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = var.crowdsec_enroll_key
  db_password                    = var.crowdsec_db_password
  crowdsec_dash_api_key          = var.crowdsec_dash_api_key
  crowdsec_dash_machine_id       = var.crowdsec_dash_machine_id
  crowdsec_dash_machine_password = var.crowdsec_dash_machine_password
  slack_webhook_url              = var.alertmanager_slack_api_url
}

module "cloudflared" {
  source                       = "../../modules/kubernetes/cloudflared"
  tier                         = local.tiers.core
  tls_secret_name              = var.tls_secret_name
  cloudflare_api_key           = var.cloudflare_api_key
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = var.cloudflare_tunnel_token
}

module "monitoring" {
  source                        = "../../modules/kubernetes/monitoring"
  tls_secret_name               = var.tls_secret_name
  alertmanager_account_password = var.alertmanager_account_password
  idrac_username                = var.idrac_username
  idrac_password                = var.idrac_password
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url
  tiny_tuya_service_secret      = var.tiny_tuya_service_secret
  haos_api_token                = var.haos_api_token
  pve_password                  = var.pve_password
  grafana_db_password           = var.grafana_db_password
  grafana_admin_password        = var.grafana_admin_password
  tier                          = local.tiers.cluster
}

module "vaultwarden" {
  source          = "../../modules/kubernetes/vaultwarden"
  tls_secret_name = var.tls_secret_name
  smtp_password   = var.vaultwarden_smtp_password
  tier            = local.tiers.edge
}

module "reverse-proxy" {
  source                 = "../../modules/kubernetes/reverse_proxy"
  tls_secret_name        = var.tls_secret_name
  truenas_homepage_token = var.homepage_credentials["reverse_proxy"]["truenas_token"]
  pfsense_homepage_token = var.homepage_credentials["reverse_proxy"]["pfsense_token"]
}

module "metrics-server" {
  source          = "../../modules/kubernetes/metrics-server"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
}

module "nvidia" {
  source          = "../../modules/kubernetes/nvidia"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.gpu
}

module "kyverno" {
  source = "../../modules/kubernetes/kyverno"
}

module "uptime-kuma" {
  source          = "../../modules/kubernetes/uptime-kuma"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.cluster
}

module "wireguard" {
  source          = "../../modules/kubernetes/wireguard"
  tls_secret_name = var.tls_secret_name
  wg_0_conf       = var.wireguard_wg_0_conf
  wg_0_key        = var.wireguard_wg_0_key
  firewall_sh     = var.wireguard_firewall_sh
  tier            = local.tiers.core
}

module "xray" {
  source                   = "../../modules/kubernetes/xray"
  tls_secret_name          = var.tls_secret_name
  tier                     = local.tiers.core
  xray_reality_clients     = var.xray_reality_clients
  xray_reality_private_key = var.xray_reality_private_key
  xray_reality_short_ids   = var.xray_reality_short_ids
}

module "mailserver" {
  source                  = "../../modules/kubernetes/mailserver"
  tls_secret_name         = var.tls_secret_name
  mailserver_accounts     = var.mailserver_accounts
  postfix_account_aliases = var.mailserver_aliases
  opendkim_key            = var.mailserver_opendkim_key
  sasl_passwd             = var.mailserver_sasl_passwd
  roundcube_db_password   = var.mailserver_roundcubemail_db_password
  tier                    = local.tiers.edge
}

module "infra-maintenance" {
  source              = "../../modules/kubernetes/infra-maintenance"
  git_user            = var.webhook_handler_git_user
  git_token           = var.webhook_handler_git_token
  technitium_username = var.technitium_username
  technitium_password = var.technitium_password
}

# --- OUTPUTS (consumed by service stacks via Terragrunt dependency) ---

output "tls_secret_name"   { value = var.tls_secret_name }
output "redis_host"        { value = "redis.redis.svc.cluster.local" }
output "postgresql_host"   { value = "postgresql.dbaas.svc.cluster.local" }
output "postgresql_port"   { value = 5432 }
output "mysql_host"        { value = "mysql.dbaas.svc.cluster.local" }
output "mysql_port"        { value = 3306 }
output "smtp_host"         { value = "mail.viktorbarzin.me" }
output "smtp_port"         { value = 587 }
```

**Step 3: Verify init succeeds**

Run:
```bash
cd stacks/platform && terragrunt init
```

**Step 4: Commit**

```bash
git add stacks/platform/
git commit -m "[ci skip] Add platform stack (core services)"
```

---

## Task 6: Migrate Platform Stack State

**CRITICAL: Largest state migration. Backup first.**

**Step 1: Backup**

```bash
cp terraform.tfstate terraform.tfstate.backup-pre-platform
```

**Step 2: Move core service resources**

The resources are currently at `module.kubernetes_cluster.module.<service>["<key>"]` (the `for_each` key). Services without `for_each` are at `module.kubernetes_cluster.module.<service>`.

Run state mv for each platform service. Example pattern:
```bash
# Services WITH for_each (note the ["key"] suffix):
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.redis["redis"]' \
  'module.redis'

terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.traefik["traefik"]' \
  'module.traefik'

# Services WITHOUT for_each:
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.metallb' \
  'module.metallb'

terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.dbaas' \
  'module.dbaas'

terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.cloudflared' \
  'module.cloudflared'

terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.infra-maintenance' \
  'module.infra-maintenance'

terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/platform/terraform.tfstate \
  'module.kubernetes_cluster.module.reverse-proxy["reverse-proxy"]' \
  'module.reverse-proxy'
```

Repeat for all platform services. Check whether each has `for_each` by looking at the state list:
```bash
terraform state list | grep 'module.kubernetes_cluster.module' | sort
```

Services with `for_each` have `["key"]` suffix; those without don't.

**Step 3: Also move null_resource.core_services**

```bash
# This resource can be dropped — don't move it, just remove it
terraform state rm 'module.kubernetes_cluster.null_resource.core_services'
```

**Step 4: Verify platform state**

Run:
```bash
cd stacks/platform && terragrunt plan
```
Expected: `No changes.` (or only expected diffs from removed for_each wrappers)

**Step 5: Remove platform services from modules/kubernetes/main.tf**

Remove the module blocks for all services that moved to the platform stack. Also remove `null_resource.core_services` and the `defcon_modules`/`active_modules` locals that reference these modules.

**Step 6: Verify legacy state**

Run:
```bash
terraform plan -var="kube_config_path=$(pwd)/config"
```
Expected: No changes for remaining services

**Step 7: Commit**

```bash
git add main.tf modules/kubernetes/main.tf stacks/platform/
git commit -m "[ci skip] Migrate platform stack (core services) to Terragrunt"
```

---

## Task 7: Create Simple Service Stack Template + Migrate First Service (blog)

**Files:**
- Create: `stacks/blog/terragrunt.hcl`
- Create: `stacks/blog/main.tf`

**Step 1: Write blog terragrunt.hcl**

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

**Step 2: Write blog main.tf**

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

**Step 3: Move blog state**

```bash
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/blog/terraform.tfstate \
  'module.kubernetes_cluster.module.blog["blog"]' \
  'module.blog'
```

**Step 4: Verify**

```bash
cd stacks/blog && terragrunt plan
```
Expected: `No changes.`

**Step 5: Remove blog from modules/kubernetes/main.tf**

Delete the `module "blog" { ... }` block (lines 197-205).

**Step 6: Commit**

```bash
git add stacks/blog/ modules/kubernetes/main.tf
git commit -m "[ci skip] Migrate blog to Terragrunt stack"
```

---

## Task 8: Batch-Migrate Remaining Simple Services

Simple services only need `tls_secret_name` (and possibly a few non-DB variables). These follow the exact same pattern as blog.

**Simple services to migrate** (one stack each):
- echo, privatebin, excalidraw, city-guesser, dashy, travel_blog, jsoncrack, cyberchef, stirling-pdf, networking-toolbox, meshcentral, ntfy, plotting-book, reloader, descheduler, homepage, tor-proxy, forgejo, freshrss, navidrome, audiobookshelf, ebook2audiobook, whisper, frigate, matrix, changedetection, isponsorblocktv

**Services with a few extra variables** (still no DB host refs):
- shadowsocks (password), kms, hackmd (db_password), drone (github creds, rpc_secret), diun (nfty_token, slack_url), calibre (homepage creds), owntracks (credentials), webhook_handler (many tokens), coturn (turn_secret, public_ip), wealthfolio (password_hash), actualbudget (credentials), servarr (aiostreams), onlyoffice (db_password, jwt_token), xray (reality vars), tuya-bridge (api keys), openclaw (ssh_key, api keys), f1-stream (turn_secret), paperless-ngx (db_password), freedify (credentials), netbox

For each service, create:
1. `stacks/<service>/terragrunt.hcl` — include root, dependency on platform, inputs from platform outputs
2. `stacks/<service>/main.tf` — variable declarations + module call with `source = "../../modules/kubernetes/<service>"`
3. `terraform state mv` from legacy state
4. Remove module block from `modules/kubernetes/main.tf`
5. Verify with `terragrunt plan`

**Automation script** (run for each simple service):
```bash
#!/bin/bash
# Usage: ./migrate-service.sh <service-name> <source-dir> <for-each-key> <tier>
# Example: ./migrate-service.sh echo echo echo 3-edge

SERVICE=$1
SOURCE_DIR=${2:-$1}
FOR_EACH_KEY=${3:-$1}
TIER=${4:-4-aux}

mkdir -p stacks/$SERVICE

cat > stacks/$SERVICE/terragrunt.hcl <<'TGEOF'
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path = "../platform"
}

inputs = {
  tls_secret_name = dependency.platform.outputs.tls_secret_name
}
TGEOF

cat > stacks/$SERVICE/main.tf <<EOF
variable "tls_secret_name" {}
variable "kube_config_path" { default = "~/.kube/config" }

module "$SERVICE" {
  source          = "../../modules/kubernetes/$SOURCE_DIR"
  tls_secret_name = var.tls_secret_name
  tier            = "$TIER"
}
EOF

# Move state
mkdir -p state/$SERVICE
terraform state mv \
  -state=terraform.tfstate \
  -state-out=state/$SERVICE/terraform.tfstate \
  "module.kubernetes_cluster.module.${SERVICE}[\"${FOR_EACH_KEY}\"]" \
  "module.${SERVICE}"

# Verify
cd stacks/$SERVICE && terragrunt plan && cd ../..
```

Services with extra variables need manual wrapper `main.tf` files (add the variable declarations and pass them to the module).

**Commit after each batch of ~5-10 services:**
```bash
git add stacks/*/
git commit -m "[ci skip] Migrate <service-list> to Terragrunt stacks"
```

---

## Task 9: Modify Service Modules to Accept Host Variables

**~20 modules need modification** to replace hardcoded DNS names with variables.

For each module, the change is mechanical:
1. Add `variable "redis_host" { type = string }` (and/or postgresql_host, etc.)
2. Replace the hardcoded string with `var.redis_host`

**Modules to modify and their needed variables:**

| Module | Add variables | Replace in |
|--------|-------------|-----------|
| affine | redis_host, postgresql_host, postgresql_port, smtp_host, smtp_port | main.tf:25,29,50-64 |
| immich | redis_host, postgresql_host | main.tf:80,96 |
| nextcloud | redis_host, mysql_host | chart_values.yaml:31,37 |
| grampsweb | redis_host, smtp_host, smtp_port | main.tf:37,41,45,57 |
| dawarich | redis_host, postgresql_host | main.tf:75,79,147 |
| send | redis_host | main.tf:75 |
| linkwarden | postgresql_host, postgresql_port | main.tf:67 |
| n8n | postgresql_host | main.tf:56 |
| health | postgresql_host, postgresql_port | main.tf:54 |
| tandoor | postgresql_host, smtp_host, smtp_port | main.tf:66,98 |
| rybbit | postgresql_host | main.tf:162 |
| netbox | postgresql_host | main.tf:73 |
| speedtest | mysql_host | main.tf:85 |
| real-estate-crawler | redis_host, mysql_host | main.tf:140,153,157,301,305,309,401,405,409 |
| ytdlp | redis_host, ollama_host | main.tf:241,255 |
| resume | smtp_host, smtp_port | main.tf:186 |
| monitoring | mysql_host, smtp_host | grafana_chart_values.yaml:51, prometheus_chart_values.tpl:35,37 |

**Example modification for affine:**

In `modules/kubernetes/affine/main.tf`, add variables:
```hcl
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "postgresql_port" { type = number }
variable "smtp_host" { type = string }
variable "smtp_port" { type = number }
```

Replace:
```hcl
# Before:
DATABASE_URL = "postgresql://postgres:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/affine"
# After:
DATABASE_URL = "postgresql://postgres:${var.postgresql_password}@${var.postgresql_host}:${var.postgresql_port}/affine"

# Before:
REDIS_SERVER_HOST = "redis.redis.svc.cluster.local"
# After:
REDIS_SERVER_HOST = var.redis_host
```

**Step: Commit each module modification**

```bash
git add modules/kubernetes/<service>/
git commit -m "[ci skip] Accept host variables in <service> module"
```

---

## Task 10: Migrate Database-Backed Services to Terragrunt Stacks

After modules are modified (Task 9), create stacks that wire platform outputs to module inputs.

**Example: stacks/affine/terragrunt.hcl**

```hcl
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

**stacks/affine/main.tf:**

```hcl
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

State migration follows the same pattern as Task 7.

Repeat for all DB-backed services from the table in Task 9.

---

## Task 11: Migrate Service-to-Service Dependencies

Services that depend on other non-platform services need multi-dependency stacks.

**Step 1: Create ollama stack with outputs**

```hcl
# stacks/ollama/main.tf
variable "tls_secret_name" {}
variable "kube_config_path" { default = "~/.kube/config" }
variable "ollama_api_credentials" {}

module "ollama" {
  source                 = "../../modules/kubernetes/ollama"
  tls_secret_name        = var.tls_secret_name
  tier                   = "2-gpu"
  ollama_api_credentials = var.ollama_api_credentials
}

output "ollama_host" {
  value = "ollama.ollama.svc.cluster.local"
}
```

**Step 2: Create openclaw stack with ollama dependency**

```hcl
# stacks/openclaw/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

dependency "platform" {
  config_path = "../platform"
}

dependency "ollama" {
  config_path = "../ollama"
}

inputs = {
  tls_secret_name = dependency.platform.outputs.tls_secret_name
  ollama_host     = dependency.ollama.outputs.ollama_host
}
```

**Step 3: Similarly for coturn → f1-stream and osm-routing → real-estate-crawler**

---

## Task 12: Final Cleanup

**Step 1: Remove legacy modules/kubernetes/main.tf**

After all services are migrated, this file should be empty (or contain only commented-out blocks). Delete it.

**Step 2: Remove kubernetes_cluster module call from root main.tf**

The root `main.tf` should now only contain provider blocks (which can also be removed since Terragrunt generates them) and the `variable` declarations for `terraform.tfvars` loading.

**Step 3: Archive legacy state**

```bash
mv terraform.tfstate terraform.tfstate.legacy
mv terraform.tfstate.backup-* state/backups/
```

**Step 4: Verify full DAG**

```bash
cd stacks && terragrunt run-all plan
```
Expected: All stacks show `No changes.`

**Step 5: Update CLAUDE.md**

Update the knowledge file to reflect the new Terragrunt architecture, commands, and workflow.

**Step 6: Final commit**

```bash
git add -A
git commit -m "[ci skip] Complete Terragrunt migration — remove legacy monolith"
```

---

## Task 13: Update CI/CD (Drone Pipeline)

**Files:**
- Modify: `.drone.yml`

Create a Drone pipeline that:
1. Detects changed files
2. Maps to affected stacks
3. Runs `terragrunt plan` (on PR) or `terragrunt apply` (on master merge)

See design doc section "CI/CD: Changed-Stack Detection" for the pipeline logic.

---

## Execution Order Summary

| Task | Phase | Risk | Reversible |
|------|-------|------|-----------|
| 1. Install + skeleton | 0 | None | Yes (delete dirs) |
| 2. Root terragrunt.hcl | 0 | None | Yes (delete file) |
| 3. Infra stack files | 1 | None | Yes (delete stack) |
| 4. Infra state migration | 1 | Medium | Yes (state mv back) |
| 5. Platform stack files | 2 | None | Yes (delete stack) |
| 6. Platform state migration | 2 | High | Yes (state mv back) |
| 7. First simple service (blog) | 3 | Low | Yes (state mv back) |
| 8. Batch simple services | 3 | Low | Yes (state mv back) |
| 9. Module host variable mods | 4 | Low | Yes (revert changes) |
| 10. DB service stacks | 4 | Low | Yes (state mv back) |
| 11. Service-to-service deps | 5 | Low | Yes (state mv back) |
| 12. Final cleanup | 6 | Medium | Harder to reverse |
| 13. CI/CD update | 6 | Low | Yes (revert .drone.yml) |
