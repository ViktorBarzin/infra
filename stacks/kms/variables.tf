variable "image_tag" {
  type        = string
  default     = "latest"
  description = "kms-website image tag pushed to ghcr.io/viktorbarzin/kms-website (ADR-0002 off-infra builds). Use 8-char git SHA in CI."
}
