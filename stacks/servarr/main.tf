variable "tls_secret_name" { type = string }
variable "aiostreams_database_connection_string" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
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
  source          = "./prowlarr"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
}

module "qbittorrent" {
  source          = "./qbittorrent"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
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
}

module "aiostreams" {
  source                                = "./aiostreams"
  tls_secret_name                       = var.tls_secret_name
  aiostreams_database_connection_string = var.aiostreams_database_connection_string
  tier                                  = local.tiers.aux
}
