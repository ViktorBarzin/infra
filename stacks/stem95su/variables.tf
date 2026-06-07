variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "nfs_server" {
  type    = string
  default = "192.168.1.127"
}
