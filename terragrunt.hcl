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

# Load config.tfvars (plaintext). Secrets come from Vault KV — authenticate via `vault login -method=oidc`.
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = [
      "${get_repo_root()}/config.tfvars"
    ]
  }

  extra_arguments "no_backup" {
    commands = ["apply", "plan", "destroy", "import"]
    arguments = ["-backup=-"]
  }

  extra_arguments "kube_config" {
    commands = get_terraform_commands_that_need_vars()
    arguments = [
      "-var", "kube_config_path=${get_repo_root()}/config"
    ]
  }
}

# Generate kubernetes + helm + cloudflare providers for all stacks.
# The infra stack overrides this to add the proxmox provider.
generate "k8s_providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
  }
}

variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

provider "kubernetes" {
  config_path = var.kube_config_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kube_config_path
  }
}

provider "vault" {
  address          = "https://vault.viktorbarzin.me"
  skip_child_token = true
}
EOF
}

# Generate Cloudflare provider config (separate file to avoid conflicts
# with stacks that override providers.tf, e.g. infra stack).
# DNS records are created per-service via ingress_factory's dns_type param.
generate "cloudflare_provider" {
  path      = "cloudflare_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
data "vault_kv_secret_v2" "cf_platform" {
  mount = "secret"
  name  = "platform"
}

provider "cloudflare" {
  api_key = data.vault_kv_secret_v2.cf_platform.data["cloudflare_api_key"]
  email   = "vbarzin@gmail.com"
}
EOF
}

# Generate shared tiers locals for all stacks.
# Previously duplicated in 67+ stacks; now defined once here.
generate "tiers" {
  path      = "tiers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}
EOF
}
