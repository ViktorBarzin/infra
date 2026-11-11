variable "name" {
  type        = string
  description = "VM and host name. A drill uses its own, e.g. devvm-drill."
}

variable "vm_id" {
  type        = number
  description = "Proxmox VMID. The live devvm is 102; drills use 9100-9109, the slots stacks/devvm's token is granted (playbooks/pve-host.yml)."
}

variable "ipv4_cidr" {
  type        = string
  description = "Static address with prefix, e.g. 10.0.10.11/24. VLAN 10's DHCP pool is .100-.254, so pick below it. The live devvm is 10.0.10.10."

  validation {
    condition     = can(cidrhost(var.ipv4_cidr, 0))
    error_message = "ipv4_cidr must be an address with a prefix length, e.g. 10.0.10.11/24."
  }
}

variable "admin_ssh_keys" {
  type        = list(string)
  description = "Authorized keys for the admin account at first boot. The playbook later installs the full list from Vault secret/devvm-authorized-keys."
}

variable "image_file_id" {
  type        = string
  description = "The Ubuntu cloud image as Proxmox import content, e.g. local:import/noble-server-cloudimg-amd64-20261017.qcow2."
}

variable "pve_endpoint" {
  type        = string
  description = "Proxmox API URL, for the guest-agent handoff."
}

variable "pve_api_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token (user@realm!id=uuid) with VM.GuestAgent.FileWrite on this VM, for the handoff."
}

variable "allow_live_identity" {
  type        = bool
  default     = false
  description = "Allow the live devvm's name, VMID, address or MAC. Only for building the replacement once VM 102 is gone."
}

variable "description" {
  type    = string
  default = "devvm workstation."
}

variable "node_name" {
  type    = string
  default = "pve"
}

variable "pool_id" {
  type        = string
  default     = "devvm"
  description = "Proxmox pool. stacks/devvm's token can only touch VMs in it."
}

variable "cores" {
  type    = number
  default = 32
}

variable "memory_mb" {
  type    = number
  default = 32768
}

variable "disk_gb" {
  type    = number
  default = 228
}

variable "disk_mbps" {
  type        = number
  default     = 60
  description = "Read and write cap in MB/s, the same as the live devvm's in scripts/apply-mbps-caps.sh."
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "bridge" {
  type    = string
  default = "vmbr1"
}

variable "vlan_id" {
  type    = number
  default = 10
}

variable "mac_address" {
  type        = string
  default     = null
  description = "NIC MAC. Null lets Proxmox pick one. The live devvm's is 00:0c:29:c0:89:ec, which its DHCP reservation keys on."
}

variable "ipv4_gateway" {
  type    = string
  default = "10.0.10.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["10.0.10.1"]
}

variable "dns_domain" {
  type    = string
  default = "viktorbarzin.lan"
}

variable "admin_user" {
  type    = string
  default = "wizard"
}

variable "on_boot" {
  type    = bool
  default = true
}

variable "vendor_data_file_id" {
  type        = string
  default     = "local:snippets/devvm_bootstrap.yaml"
  description = "The shared bootstrap snippet playbooks/pve-host.yml installs (tag snippets)."
}

variable "infra_ref" {
  type        = string
  default     = "master"
  description = "Branch of viktor/infra the guest clones and builds from."
}
