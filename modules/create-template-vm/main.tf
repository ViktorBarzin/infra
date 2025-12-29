variable "proxmox_host" { type = string }
variable "proxmox_user" { type = string }
variable "cloud_image_url" { type = string }
variable "image_path" { type = string }
variable "template_id" {
  type    = number
  default = 8000
}
variable "template_name" { type = string }
variable "snippet_name" { type = string }
variable "user_passwd" { type = string } # hashed pw
variable "k8s_join_command" {
  type    = string
  default = ""
}
variable "containerd_config_update_command" {
  type        = string
  default     = ""
  description = "Command to execute to update containerd config.toml; e.g add mirror"
}
variable "is_k8s_template" { type = bool }
variable "provision_cmds" {
  type    = list(string)
  default = []
}

# SSH connection to Proxmox
resource "null_resource" "create_template_remote" {
  connection {
    type        = "ssh"
    user        = var.proxmox_user
    host        = var.proxmox_host
    private_key = file("~/.ssh/id_ed25519")
  }

  # Commands executed *on Proxmox host*
  provisioner "remote-exec" {
    inline = [
      "set -e",
      # download the cloud image if missing
      "if [ ! -f ${var.image_path} ]; then wget -O ${var.image_path} ${var.cloud_image_url}; fi",
      # create template only if not existing
      "if ! qm status ${var.template_id} >/dev/null 2>&1; then",
      "  echo 'Creating cloud-init template...';",
      "  qm create ${var.template_id} --name ${var.template_name} --memory 8192 --cores 8 --net0 virtio,bridge=vmbr0;",
      "  qm importdisk ${var.template_id} ${var.image_path} local-lvm;",
      "  qm set ${var.template_id} --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-${var.template_id}-disk-0;",
      "  qm set ${var.template_id} --ide2 local-lvm:cloudinit;",
      "  qm set ${var.template_id} --boot c --bootdisk scsi0;",
      "  qm set ${var.template_id} --serial0 socket --vga serial0;",
      "  qm template ${var.template_id};",
      "else",
      "  echo 'Template ${var.template_id} already exists — skipping.';",
      "fi"
    ]
  }
}

resource "null_resource" "upload_cloud_init" {
  connection {
    type        = "ssh"
    host        = var.proxmox_host
    user        = var.proxmox_user
    private_key = file("~/.ssh/id_ed25519")
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /var/lib/vz/snippets"]
  }

  provisioner "file" {
    destination = "/var/lib/vz/snippets/${var.snippet_name}"
    content = templatefile("${path.module}/cloud_init.yaml", {
      is_k8s_template                  = var.is_k8s_template,
      authorized_ssh_key               = file("~/.ssh/id_ed25519.pub"),
      passwd                           = var.user_passwd,
      provision_cmds                   = var.provision_cmds,
      k8s_join_command                 = var.k8s_join_command,
      containerd_config_update_command = var.containerd_config_update_command
      }
    )
  }

  # Force recreate when the below changes
  triggers = {
    file_hash                        = filesha256("${path.module}/cloud_init.yaml")
    provision_cmds                   = join(", ", var.provision_cmds)
    is_k8s_template                  = var.is_k8s_template,
    passwd                           = var.user_passwd,
    k8s_join_command                 = var.k8s_join_command,
    containerd_config_update_command = var.containerd_config_update_command
  }
}
