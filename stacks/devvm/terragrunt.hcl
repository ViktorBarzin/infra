# Terraform-built devvm VMs: drills now, the replacement devvm later
# (docs/runbooks/devvm-drill.md, docs/plans/2026-11-11-disposable-devvm.md).
#
# Standalone on purpose: it does not include the root terragrunt.hcl. The root
# generates one providers.tf for every stack, which already declares the local
# name "proxmox" for telmate/proxmox, and a module may hold only one
# required_providers block. Adding bpg/proxmox there would be a global change
# (CI then re-applies every platform stack) for the sake of this stack. So this
# stack carries the same PG state backend as every Tier 1 stack and generates
# only the two providers it uses, the same way stacks/opnsense does.

remote_state {
  backend = "pg"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    conn_str    = get_env("PG_CONN_STR", "")
    schema_name = "devvm"
  }
}

terraform {
  extra_arguments "no_backup" {
    commands  = ["apply", "plan", "destroy", "import"]
    arguments = ["-backup=-"]
  }
}

generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<PROVIDERS
terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
      # renovate: datasource=terraform-provider depName=hashicorp/vault
      version = "5.13.0"
    }
    proxmoxbpg = {
      source = "bpg/proxmox"
      # renovate: datasource=terraform-provider depName=bpg/proxmox
      version = "0.121.0"
    }
  }
}

provider "vault" {
  address          = "${get_env("VAULT_ADDR", "https://vault.viktorbarzin.me")}"
  skip_child_token = true
}
PROVIDERS
}
