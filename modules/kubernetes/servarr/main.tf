variable "tls_secret_name" {}
variable "tier" { type = string }
variable "aiostreams_database_connection_string" { type = string }

resource "kubernetes_namespace" "servarr" {
  metadata {
    name = "servarr"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.servarr.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# module "readarr" {
#   source          = "./readarr"
#   tls_secret_name = var.tls_secret_name
#   tier = var.tier
# }

module "prowlarr" {
  source          = "./prowlarr"
  tls_secret_name = var.tls_secret_name
  tier            = var.tier
}

module "qbittorrent" {
  source          = "./qbittorrent"
  tls_secret_name = var.tls_secret_name
  tier            = var.tier
}

module "flaresolverr" {
  source          = "./flaresolverr"
  tls_secret_name = var.tls_secret_name
  tier            = var.tier
}

# module "lidarr" {
#   source          = "./lidarr"
#   tls_secret_name = var.tls_secret_name
# tier            = var.tier
# }

# module "soulseek" {
#   source          = "./soulseek"
#   tls_secret_name = var.tls_secret_name
# tier            = var.tier
# }

module "listenarr" {
  source          = "./listenarr"
  tls_secret_name = var.tls_secret_name
  tier            = var.tier
}

module "aiostreams" {
  source                                = "./aiostreams"
  tls_secret_name                       = var.tls_secret_name
  aiostreams_database_connection_string = var.aiostreams_database_connection_string
  tier                                  = var.tier
}
