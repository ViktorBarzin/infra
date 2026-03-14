terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

variable "vault_root_token" {
  type      = string
  sensitive = true
}

provider "vault" {
  address = "https://vault.viktorbarzin.me"
  token   = var.vault_root_token
}
