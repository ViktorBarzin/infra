variable "public_ip" {
  description = "Homelab WAN IP (from config.tfvars) — allowlisted for the VM's metrics port and, later, the pfSense drain-source restriction."
  type        = string
}
