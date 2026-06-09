module "pvc_autoresizer" {
  source = "./modules/pvc-autoresizer"
  tier   = local.tiers.cluster
}
