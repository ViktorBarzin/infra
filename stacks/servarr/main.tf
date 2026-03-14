variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "servarr"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "servarr" {
  metadata {
    name = "servarr"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.servarr.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# module "readarr" {
#   source          = "./readarr"
#   tls_secret_name = var.tls_secret_name
#   tier = local.tiers.aux
# }

module "prowlarr" {
  source               = "./prowlarr"
  tls_secret_name      = var.tls_secret_name
  tier                 = local.tiers.aux
  nfs_server           = var.nfs_server
  homepage_credentials = local.homepage_credentials
}

module "qbittorrent" {
  source               = "./qbittorrent"
  tls_secret_name      = var.tls_secret_name
  tier                 = local.tiers.aux
  nfs_server           = var.nfs_server
  homepage_credentials = local.homepage_credentials
}

module "flaresolverr" {
  source          = "./flaresolverr"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
}

# module "lidarr" {
#   source          = "./lidarr"
#   tls_secret_name = var.tls_secret_name
# tier            = local.tiers.aux
# }

# module "soulseek" {
#   source          = "./soulseek"
#   tls_secret_name = var.tls_secret_name
# tier            = local.tiers.aux
# }

module "listenarr" {
  source          = "./listenarr"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
  nfs_server      = var.nfs_server
}

module "aiostreams" {
  source                                = "./aiostreams"
  tls_secret_name                       = var.tls_secret_name
  aiostreams_database_connection_string = data.vault_kv_secret_v2.secrets.data["aiostreams_database_connection_string"]
  tier                                  = local.tiers.aux
  nfs_server                            = var.nfs_server
}
