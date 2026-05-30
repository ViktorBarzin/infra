variable "image_tag" {
  type        = string
  default     = "latest"
  description = "travel-agent image tag. Use 8-char git SHA in CI; :latest only for local trials."
}
