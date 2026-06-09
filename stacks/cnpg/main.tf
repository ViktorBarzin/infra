module "cnpg" {
  source = "./modules/cnpg"
  tier   = local.tiers.cluster
}
