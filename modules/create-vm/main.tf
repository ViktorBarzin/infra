# ---------------------------------------------------------------------------
# Variables — Required
# ---------------------------------------------------------------------------

variable "vm_name" { type = string }
variable "vmid" {
  type    = number
  default = 0
}
variable "cisnippet_name" {
  type    = string
  default = ""
}
variable "bridge" { type = string }

# ---------------------------------------------------------------------------
# Variables — VM sizing
# ---------------------------------------------------------------------------

variable "vm_cpus" {
  type    = number
  default = 4
}
variable "cpu_sockets" {
  type    = number
  default = 1
}
variable "vm_mem_mb" {
  type    = number
  default = 8192
}
variable "vm_disk_size" {
  type    = string
  default = "64G"
}
variable "balloon" {
  type    = number
  default = 0 # 0 = disabled (recommended for k8s nodes)
}

# ---------------------------------------------------------------------------
# Variables — VM identity & networking
# ---------------------------------------------------------------------------

variable "vm_mac_address" {
  type    = string
  default = null
}
variable "vlan_tag" {
  type    = string
  default = null
}
variable "ipconfig0" {
  type    = string
  default = "ip=dhcp,ip6=dhcp"
}

# ---------------------------------------------------------------------------
# Variables — Boot & hardware
# ---------------------------------------------------------------------------

variable "template_name" {
  type    = string
  default = "" # empty = no clone (for importing existing VMs)
}
variable "scsihw" {
  type    = string
  default = "virtio-scsi-pci"
}
variable "boot" {
  type    = string
  default = "order=scsi0"
}
variable "boot_disk" {
  type    = string
  default = "" # e.g., "scsi0" — only set if boot = "c" (legacy)
}
variable "disk_slot" {
  type    = string
  default = "scsi0" # which SCSI slot the OS disk is on
}
variable "agent" {
  type    = number
  default = 1
}
variable "qemu_os" {
  type    = string
  default = "l26"
}
variable "numa" {
  type    = bool
  default = false
}
variable "machine" {
  type    = string
  default = "" # empty = provider default. Use "q35" for GPU passthrough
}

# ---------------------------------------------------------------------------
# Variables — Startup/shutdown ordering
# ---------------------------------------------------------------------------

variable "startup_order" {
  type    = number
  default = -1
}
variable "startup_delay" {
  type    = number
  default = -1
}
variable "shutdown_timeout" {
  type    = number
  default = -1
}

# ---------------------------------------------------------------------------
# Variables — Cloud-Init (optional — disable for non-cloud-init VMs)
# ---------------------------------------------------------------------------

variable "use_cloud_init" {
  type    = bool
  default = true
}
variable "ssh_keys" {
  type    = string
  default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHLhYDfyx237eJgOGVoJRECpUS95+7rEBS9vacsIxtx devvm"
}

# ---------------------------------------------------------------------------
# Variables — GPU / PCI passthrough
# ---------------------------------------------------------------------------

variable "hostpci0" {
  type    = string
  default = "" # e.g., "0000:06:00.0" for Tesla T4 passthrough
}

# ---------------------------------------------------------------------------
# Resource
# ---------------------------------------------------------------------------

resource "proxmox_vm_qemu" "cloudinit-vm" {
  vmid             = var.vmid
  name             = var.vm_name
  target_node      = "pve"
  agent            = var.agent
  memory           = var.vm_mem_mb
  balloon          = var.balloon
  boot             = var.boot
  bootdisk         = var.boot_disk != "" ? var.boot_disk : null
  clone            = var.template_name != "" ? var.template_name : null
  full_clone       = var.template_name != "" ? true : false
  scsihw           = var.scsihw
  vm_state         = "running"
  automatic_reboot = false # never let Terraform reboot VMs — use /reboot-server skill instead
  os_type          = var.use_cloud_init ? "cloud-init" : null
  machine          = var.machine != "" ? var.machine : null

  # Cloud-Init configuration (only when use_cloud_init = true)
  cicustom     = var.use_cloud_init && var.cisnippet_name != "" ? "vendor=local:snippets/${var.cisnippet_name}" : null
  ciupgrade    = var.use_cloud_init ? true : null
  nameserver   = var.use_cloud_init ? "1.1.1.1 8.8.8.8" : null
  ipconfig0    = var.use_cloud_init ? var.ipconfig0 : null
  skip_ipv6    = var.use_cloud_init ? true : null
  ciuser       = var.use_cloud_init ? "root" : null
  cipassword   = var.use_cloud_init ? "root" : null
  sshkeys      = var.use_cloud_init ? var.ssh_keys : null
  searchdomain = var.use_cloud_init ? "viktorbarzin.lan" : null

  start_at_node_boot = true
  qemu_os            = var.qemu_os

  cpu {
    cores   = var.vm_cpus
    sockets = var.cpu_sockets
    type    = "host"
  }

  startup_shutdown {
    order            = var.startup_order
    shutdown_timeout = var.shutdown_timeout
    startup_delay    = var.startup_delay
  }

  serial {
    id = 0
  }

  disks {
    scsi {
      dynamic "scsi0" {
        for_each = var.disk_slot == "scsi0" ? [1] : []
        content {
          disk {
            storage  = "local-lvm"
            size     = var.vm_disk_size
            discard  = true # Enable TRIM passthrough to LVM thin pool — reduces CoW overhead
          }
        }
      }
      dynamic "scsi1" {
        for_each = var.disk_slot == "scsi1" ? [1] : []
        content {
          disk {
            storage  = "local-lvm"
            size     = var.vm_disk_size
            discard  = true
          }
        }
      }
    }
    dynamic "ide" {
      for_each = var.use_cloud_init ? [1] : []
      content {
        ide1 {
          cloudinit {
            storage = "local-lvm"
          }
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

  # Safety: ignore dynamically-attached iSCSI PVC disks (managed by democratic-csi)
  # and cloud-init changes that drift after initial provisioning
  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      # democratic-csi dynamically attaches/detaches iSCSI disks
      disks[0].scsi[0].scsi1,
      disks[0].scsi[0].scsi2,
      disks[0].scsi[0].scsi3,
      disks[0].scsi[0].scsi4,
      disks[0].scsi[0].scsi5,
      # cloud-init config may drift after first boot
      cicustom,
      ciupgrade,
      ciuser,
      cipassword,
      sshkeys,
      # SMBIOS UUID and vmgenid are auto-generated
      smbios,
      # Tags and description may be edited in Proxmox UI
      tags,
      desc,
      # Provider defaults that differ from imported state
      define_connection_info,
      full_clone,
    ]
  }
}
