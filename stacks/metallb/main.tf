module "metallb" {
  source = "./modules/metallb"
  tier   = local.tiers.core
}
