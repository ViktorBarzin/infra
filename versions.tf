# terraform {
#   required_providers {
#     kubernetes = {
#       source = "hashicorp/kubernetes"
#     }
#     kubectl = {
#       source  = "gavinbunney/kubectl"
#       version = ">= 1.10.0"
#     }
#   }
#   required_version = ">= 0.13"
# }

# terraform {
#   required_providers {
#     proxmox = {
#       source  = "telmate/proxmox"
#       version = "2.9.14"
#     }
#   }
# }

# provides more resources
# terraform {
#   required_providers {
#     proxmox = {
#       source  = "bpg/proxmox"
#       version = "0.39.0"
#     }
#   }
# }

# terraform {
#   required_providers {
#     cloudflare = {
#       source  = "cloudflare/cloudflare"
#       version = "~> 4.0"
#     }
#   }
# }

terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}
