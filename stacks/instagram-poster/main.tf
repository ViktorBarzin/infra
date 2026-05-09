variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "instagram-poster image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

module "instagram_poster" {
  source          = "./modules/instagram-poster"
  tier            = local.tiers.aux
  tls_secret_name = var.tls_secret_name
  image_tag       = var.image_tag
}
