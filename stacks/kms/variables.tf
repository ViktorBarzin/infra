variable "image_tag" {
  type        = string
  default     = "latest"
  description = "kms-website image tag pushed to forgejo.viktorbarzin.me/viktor/kms-website. Use 8-char git SHA in CI."
}
