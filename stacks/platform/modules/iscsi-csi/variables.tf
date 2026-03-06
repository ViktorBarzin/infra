variable "tier" { type = string }
variable "truenas_host" { type = string }
variable "truenas_api_key" {
  type      = string
  sensitive = true
}
variable "truenas_ssh_private_key" {
  type      = string
  sensitive = true
}
