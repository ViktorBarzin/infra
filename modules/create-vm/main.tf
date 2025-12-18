variable "vm_name" { type = string }
variable "vmid" {
  type    = number
  default = 0
}
variable "template_name" { type = string }
variable "vm_cpus" {
  type    = number
  default = 4
}
variable "vm_mem_mb" {
  type    = number
  default = 8192
}
variable "vm_disk_size" {
  type    = string
  default = "64G"
}
variable "vm_mac_address" {
  type    = string
  default = null
}
variable "cisnippet_name" { type = string }
variable "ssh_keys" {
  type    = string
  default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHLhYDfyx237eJgOGVoJRECpUS95+7rEBS9vacsIxtx devvm"
}
variable "bridge" { type = string }
variable "vlan_tag" {
  type    = string
  default = null
}

resource "proxmox_vm_qemu" "cloudinit-vm" {
  vmid             = var.vmid
  name             = var.vm_name
  target_node      = "pve"
  agent            = 0
  memory           = var.vm_mem_mb
  boot             = "order=scsi0"     # has to be the same as the OS disk of the template
  clone            = var.template_name # The name of the template
  scsihw           = "virtio-scsi-single"
  vm_state         = "running"
  automatic_reboot = true
  os_type          = "cloud-init"

  # Cloud-Init configuration
  cicustom           = "vendor=local:snippets/${var.cisnippet_name}"
  ciupgrade          = true
  nameserver         = "1.1.1.1 8.8.8.8"
  ipconfig0          = "ip=dhcp,ip6=dhcp"
  skip_ipv6          = true
  ciuser             = "root"
  cipassword         = "root"
  sshkeys            = var.ssh_keys
  searchdomain       = "viktorbarzin.lan"
  start_at_node_boot = true # start on node boot
  qemu_os            = "l26"

  cpu {
    cores = var.vm_cpus
    type  = "host" # emulate host cpu
  }

  # Most cloud-init images require a serial device for their display
  serial {
    id = 0
  }
  disks {
    scsi {
      scsi0 {
        # We have to specify the disk from our template, else Terraform will think it's not supposed to be there
        disk {
          storage = "local-lvm"
          # The size of the disk should be at least as big as the disk in the template. If it's smaller, the disk will be recreated
          size = var.vm_disk_size
        }
      }
    }
    ide {
      # Some images require a cloud-init disk on the IDE controller, others on the SCSI or SATA controller
      ide1 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }
  network {
    id      = 0
    bridge  = var.bridge
    model   = "virtio"
    macaddr = var.vm_mac_address
    tag     = var.vlan_tag
  }
}
