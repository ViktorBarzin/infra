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

# Load config.tfvars (plaintext) + secrets.auto.tfvars.json (SOPS-decrypted).
# Run `scripts/tg` instead of raw `terragrunt` — it decrypts secrets first.
# Falls back to terraform.tfvars if it exists (migration compatibility).
terraform {
  extra_arguments "common_vars" {
    commands = get_terraform_commands_that_need_vars()
    required_var_files = [
      "${get_repo_root()}/config.tfvars"
    ]
    optional_var_files = [
      "${get_repo_root()}/terraform.tfvars",
      "${get_repo_root()}/secrets.auto.tfvars.json"
    ]
  }

  extra_arguments "kube_config" {
    commands = get_terraform_commands_that_need_vars()
    arguments = [
      "-var", "kube_config_path=${get_repo_root()}/config"
    ]
  }

  # Safety: fail if neither secrets source exists
  before_hook "check_secrets" {
    commands = ["apply", "plan", "destroy"]
    execute  = ["sh", "-c", "test -f ${get_repo_root()}/secrets.auto.tfvars.json || test -f ${get_repo_root()}/terraform.tfvars || (echo 'ERROR: No secrets file found. Run scripts/tg instead of terragrunt directly.' && exit 1)"]
  }
}

# Generate kubernetes + helm providers for K8s stacks.
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
  }
}

variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

variable "vault_root_token" {
  type      = string
  sensitive = true
  default   = ""
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
  token            = var.vault_root_token
  skip_child_token = true
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
