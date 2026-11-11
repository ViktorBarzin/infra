# terraform test, offline (the provider is mocked). From the module directory:
#   terraform init -backend=false && terraform test
# Checks that a drill renders the live devvm's shape with its own identity, and
# that the live devvm's identity is refused unless asked for.
mock_provider "proxmoxbpg" {}

variables {
  name           = "devvm-drill"
  vm_id          = 9102
  ipv4_cidr      = "10.0.10.11/24"
  admin_ssh_keys = ["ssh-ed25519 AAAA test"]
  image_file_id  = "local:import/noble.qcow2"
  pve_endpoint   = "https://pve.test:8006/"
  pve_api_token  = "terraform-devvm@pve!tf=x"
}

run "drill_has_the_live_shape" {
  command = plan
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.cpu[0].cores == 32 && proxmox_virtual_environment_vm.devvm.cpu[0].type == "host"
    error_message = "cpu differs from the live devvm"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.memory[0].dedicated == 32768 && proxmox_virtual_environment_vm.devvm.memory[0].floating == 0
    error_message = "memory differs from the live devvm"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.disk[0].size == 228 && proxmox_virtual_environment_vm.devvm.disk[0].speed[0].write == 60
    error_message = "disk differs from the live devvm"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.network_device[0].bridge == "vmbr1" && proxmox_virtual_environment_vm.devvm.network_device[0].vlan_id == 10
    error_message = "network differs from the live devvm"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.pool_id == "devvm"
    error_message = "the VM must sit in the pool the stack's token is scoped to"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.initialization[0].ip_config[0].ipv4[0].address == "10.0.10.11/24"
    error_message = "static address not passed to cloud-init"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.initialization[0].vendor_data_file_id == "local:snippets/devvm_bootstrap.yaml"
    error_message = "bootstrap snippet not attached"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.devvm.initialization[0].user_account[0].username == "wizard"
    error_message = "admin account"
  }
}

run "live_address_refused" {
  command = plan
  variables {
    ipv4_cidr = "10.0.10.10/24"
  }
  expect_failures = [proxmox_virtual_environment_vm.devvm]
}

run "live_vmid_refused" {
  command = plan
  variables {
    vm_id = 102
  }
  expect_failures = [proxmox_virtual_environment_vm.devvm]
}

run "live_mac_refused" {
  command = plan
  variables {
    mac_address = "00:0C:29:C0:89:EC"
  }
  expect_failures = [proxmox_virtual_environment_vm.devvm]
}

run "live_identity_allowed_when_asked" {
  command = plan
  variables {
    name                = "devvm"
    vm_id               = 102
    ipv4_cidr           = "10.0.10.10/24"
    mac_address         = "00:0c:29:c0:89:ec"
    allow_live_identity = true
  }
}
