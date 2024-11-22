variable "tls_secret_name" {}

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
