variable "public_ip" {
  description = "Homelab WAN IP (from config.tfvars) — allowlisted for the VM's metrics port and, later, the pfSense drain-source restriction."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "viktorbarzin.me zone (from config.tfvars) — holds the immich-cdn A record."
  type        = string
}
