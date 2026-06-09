# =============================================================================
# NVIDIA Stack — GPU device plugin
# =============================================================================

variable "tls_secret_name" { type = string }

module "nvidia" {
  source          = "./modules/nvidia"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.gpu
}
