variable "nfs_server" { type = string }

module "nfs-csi" {
  source     = "./modules/nfs-csi"
  tier       = local.tiers.cluster
  nfs_server = var.nfs_server
}
