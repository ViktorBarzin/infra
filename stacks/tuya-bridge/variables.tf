variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "tuya_bridge image tag at ghcr.io/viktorbarzin/tuya_bridge (built by GHA, ADR-0002). The GHA deploy job drives a Woodpecker `kubectl set image` to the 8-char git SHA; this variable is only used on initial create / TF recreate (image is in lifecycle.ignore_changes)."
}
