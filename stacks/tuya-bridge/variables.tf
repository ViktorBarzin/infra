variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "tuya_bridge image tag pushed to forgejo.viktorbarzin.me/viktor/tuya_bridge. Each Woodpecker run does `kubectl set image` to the 8-char git SHA; this variable is only used on initial create / TF recreate (image is in lifecycle.ignore_changes)."
}
