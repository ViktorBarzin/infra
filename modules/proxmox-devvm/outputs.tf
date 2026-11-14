output "vm_id" {
  value = proxmox_virtual_environment_vm.devvm.vm_id
}

output "address" {
  value = split("/", var.ipv4_cidr)[0]
}

output "mac_address" {
  value = proxmox_virtual_environment_vm.devvm.network_device[0].mac_address
}

output "live_host_keys" {
  description = "Whether the guest installs the live devvm's SSH host keys at first boot."
  value       = local.live_host_keys
}
