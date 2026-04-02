variable "tier" { type = string }
variable "proxmox_url" { type = string }
variable "proxmox_token_id" {
  type      = string
  sensitive = true
}
variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}
variable "proxmox_cluster_name" {
  type    = string
  default = "pve"
}
variable "kube_config_path" {
  type    = string
  default = ""
}
