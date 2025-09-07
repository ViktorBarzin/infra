variable "tls_secret_name" {}

resource "kubernetes_namespace" "servarr" {
  metadata {
    name = "servarr"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "servarr"
  tls_secret_name = var.tls_secret_name
}


# module "readarr" {
#   source          = "./readarr"
#   tls_secret_name = var.tls_secret_name
# }

module "prowlarr" {
  source          = "./prowlarr"
  tls_secret_name = var.tls_secret_name
}

module "qbittorrent" {
  source          = "./qbittorrent"
  tls_secret_name = var.tls_secret_name
}

module "flaresolverr" {
  source          = "./flaresolverr"
  tls_secret_name = var.tls_secret_name
}

module "lidarr" {
  source          = "./lidarr"
  tls_secret_name = var.tls_secret_name
}

module "soulseek" {
  source          = "./soulseek"
  tls_secret_name = var.tls_secret_name
}
