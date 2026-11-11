# One devvm VM on Proxmox, built from a bare Ubuntu cloud image into a working
# workstation at first boot. Used by stacks/devvm; runbook
# docs/runbooks/devvm-drill.md.
#
# The defaults are the live devvm's shape (VMID 102, read from `qm config 102`
# on 2026-11-11): 32 host cores, 32 GiB with no balloon, a 228 GiB scsi0 on
# local-lvm with discard, iothread, aio=threads and the same 60/60 MB/s and
# 400 read-IOPS caps scripts/apply-mbps-caps.sh holds it to, one virtio NIC on
# vmbr1 VLAN 10, serial console, guest agent. Name, VMID and address have no
# default, and the live identity (name devvm, VMID 102, 10.0.10.10, its MAC) is
# refused unless allow_live_identity is set: a second VM answering on the live
# devvm's address or MAC would take the box off the network.
#
# What happens at create:
#   1. the VM is created from image_file_id and booted; the Proxmox cloud-init
#      drive carries the name, a static address, the admin account and keys;
#   2. the vendor snippet (vendor_data_file_id, rendered by playbooks/pve-host.yml
#      from scripts/devvm-bootstrap) installs the guest agent and starts the
#      build, which waits for a Vault token;
#   3. terraform_data.handoff runs scripts/devvm-drill-handoff on the applier,
#      which hands the guest a wrapped token through the guest agent;
#   4. the guest runs playbooks/devvm.yml and the roster provisioner on itself
#      and writes "ok" or "failed: <step>" to /var/lib/devvm-bootstrap/status.
# The apply returns after step 3; the build takes a while longer.

terraform {
  required_providers {
    proxmoxbpg = {
      source = "bpg/proxmox"
    }
  }
}

locals {
  live_identity = (
    var.name == "devvm" ||
    var.vm_id == 102 ||
    split("/", var.ipv4_cidr)[0] == "10.0.10.10" ||
    lower(coalesce(var.mac_address, "-")) == "00:0c:29:c0:89:ec"
  )
}

resource "proxmox_virtual_environment_vm" "devvm" {
  provider    = proxmoxbpg
  name        = var.name
  node_name   = var.node_name
  vm_id       = var.vm_id
  pool_id     = var.pool_id
  description = "${var.description} Managed by stacks/devvm (modules/proxmox-devvm); build status in /var/lib/devvm-bootstrap/status."
  tags        = ["devvm", "terraform"]

  on_boot         = var.on_boot
  started         = true
  stop_on_destroy = true
  # Drills have no backup, replication or HA jobs for a purge to clean up.
  # Purge or not, PVE deletes the ACLs on /vms/<id> at every destroy
  # (remove_vm_access), which is where stacks/devvm's token holds its VMID
  # slot; pve-devvm-tf-acl.timer on the host puts the slot grant back within
  # a minute (playbooks/pve-host.yml, devvm-tf).
  purge_on_destroy = false

  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"

  cpu {
    cores   = var.cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.memory_mb
    floating  = 0
  }

  operating_system {
    type = "l26"
  }

  # Creation waits for the agent to report an address. cloud-init installs the
  # agent in its package step, a few minutes in, so give it room.
  agent {
    enabled = true
    trim    = true
    timeout = "25m"
  }

  serial_device {
    device = "socket"
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    import_from  = var.image_file_id
    size         = var.disk_gb
    discard      = "on"
    iothread     = true
    aio          = "threads"

    speed {
      read                = var.disk_mbps
      write               = var.disk_mbps
      iops_read           = 400
      iops_read_burstable = 800
    }
  }

  boot_order = ["scsi0"]

  network_device {
    bridge      = var.bridge
    vlan_id     = var.vlan_id
    mac_address = var.mac_address
    model       = "virtio"
    firewall    = false
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"
    # The playbook manages packages; a full upgrade at first boot only slows
    # the build down.
    upgrade = false

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ipv4_cidr
        gateway = var.ipv4_gateway
      }
    }

    user_account {
      username = var.admin_user
      keys     = var.admin_ssh_keys
    }

    vendor_data_file_id = var.vendor_data_file_id
  }

  lifecycle {
    # The image matters only at creation; later Ubuntu updates happen inside
    # the guest, not as a new disk.
    ignore_changes = [disk[0].import_from]

    precondition {
      condition     = var.allow_live_identity || !local.live_identity
      error_message = "This VM would take the live devvm's name, VMID 102, 10.0.10.10 or its MAC. Give it its own, or set allow_live_identity = true only when the live devvm (102) is gone and this VM replaces it (docs/runbooks/devvm-drill.md)."
    }
  }
}

# Hands the guest its wrapped Vault token once the guest agent is up. Replaced
# with the VM, so a recreated VM gets a fresh token and an unchanged one never
# gets a second.
resource "terraform_data" "handoff" {
  triggers_replace = [proxmox_virtual_environment_vm.devvm.id]

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/devvm-drill-handoff"
    environment = {
      PVE_ENDPOINT  = var.pve_endpoint
      PVE_NODE      = var.node_name
      VMID          = tostring(proxmox_virtual_environment_vm.devvm.vm_id)
      PVE_API_TOKEN = var.pve_api_token
      INFRA_REF     = var.infra_ref
    }
  }
}
