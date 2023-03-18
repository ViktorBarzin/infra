variable "vsphere_user" {
  default = "Administrator@viktorbarzin.lan"
}
variable "vsphere_password" {}
variable "vsphere_server" {
  default = "vcenter"
}
variable "vm_name" {
  default = "terraform-test"
}
variable "vm_cpus" {
  type    = number
  default = 4
}

variable "vm_mem" {
  type    = number
  default = 4096
}

variable "vm_guest_id" {
  default = "ubuntu64Guest"
}

variable "vm_disk_size" {
  type    = number
  default = 64
}

variable "provisioner_command" {
  description = "Additional provisioning commands to run"
  default     = "#"
  type        = string
}

variable "network" {
  description = "Network to attach the vm guest to"
}

variable "ceph_disk_size" {
  type    = number
  default = 0
}

variable "cdrom_path" {
  type    = string
  default = ""
}

variable "vsphere_datastore" {
  type    = string
  default = "r730-datastore"
}

variable "vsphere_resource_pool" {
  type    = string
  default = "R730"
}

variable "vm_mac_address" {
  type    = string
  default = ""
}

provider "vsphere" {
  user           = var.vsphere_user
  password       = var.vsphere_password
  vsphere_server = var.vsphere_server

  # If you have a self-signed cert
  allow_unverified_ssl = true
}

data "vsphere_datacenter" "dc" {
  name = "Home"
}

data "vsphere_datastore" "datastore" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_resource_pool" "pool" {
  name          = var.vsphere_resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  name             = var.vm_name
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id

  num_cpus = var.vm_cpus
  memory   = var.vm_mem
  guest_id = var.vm_guest_id

  # If mac address is set create NIC with that MAC
  dynamic "network_interface" {
    for_each = var.vm_mac_address != "" ? [1] : []
    content {
      network_id     = data.vsphere_network.network.id
      use_static_mac = true
      mac_address    = var.vm_mac_address
    }
  }

  # Else create a NIC with random MAC
  dynamic "network_interface" {
    for_each = var.vm_mac_address == "" ? [1] : []
    content {
      network_id = data.vsphere_network.network.id
    }
  }

  disk {
    label = "disk0"
    size  = var.vm_disk_size
  }

  dynamic "disk" {
    for_each = var.ceph_disk_size > 0 ? [1] : []
    content {
      label       = "ceph-disk0"
      size        = var.ceph_disk_size
      unit_number = 1
    }
  }

  dynamic "cdrom" {
    for_each = var.cdrom_path != "" ? [1] : []
    content {
      datastore_id = data.vsphere_datastore.datastore.id
      path         = var.cdrom_path
    }
  }
  wait_for_guest_net_timeout = 600

  provisioner "local-exec" {
    # for_each = var.provisioner_command != "" ? [1] : []
    # content {
    command = "${var.provisioner_command} -e 'host=${vsphere_virtual_machine.vm.default_ip_address}'"
    # }
  }
}

output "guest_ip" {
  value = vsphere_virtual_machine.vm.default_ip_address
}
