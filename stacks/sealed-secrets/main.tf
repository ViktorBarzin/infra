module "sealed-secrets" {
  source = "./modules/sealed-secrets"
  tier   = local.tiers.cluster
}
