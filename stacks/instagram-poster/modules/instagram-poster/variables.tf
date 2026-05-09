variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "instagram-poster image tag. Use 8-char git SHA in CI; :latest only for local trials."
}

variable "tier" {
  type    = string
  default = "4-aux"
}
