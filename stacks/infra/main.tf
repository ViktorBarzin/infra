# Infra stack — Proxmox VM templates and docker-registry VM
#
# Wraps the existing create-template-vm and create-vm modules with
# source paths adjusted for the stacks/infra/ working directory.

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "proxmox_host" { type = string }

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "DEPRECATED: was a tfvars input. Now read from Vault secret/viktor.ssh_public_key directly (see locals.k8s_ssh_public_key) so no apply-time argument can leave the snippet's authorized_keys empty."
}

variable "k8s_join_command" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "infra"
}

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  k8s_vm_template             = "ubuntu-2404-cloudinit-k8s-template"
  k8s_cloud_init_snippet_name = "k8s_cloud_init.yaml"
  k8s_cloud_init_image_path   = "/var/lib/vz/template/iso/noble-server-cloudimg-amd64-k8s.img"

  non_k8s_vm_template             = "ubuntu-2404-cloudinit-non-k8s-template"
  non_k8s_cloud_init_snippet_name = "non_k8s_cloud_init.yaml"
  non_k8s_cloud_init_image_path   = "/var/lib/vz/template/iso/noble-server-cloudimg-amd64-non-k8s.img"

  cloud_init_image_url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

  # Source of truth for the wizard user's SSH key on every cloud-init
  # generated VM. Lives in Vault so we never apply with an empty value
  # (which silently locked the wizard account on the node5 v1 boot —
  # 2026-05-26). Falls back to var.ssh_public_key for backward compat.
  k8s_ssh_public_key = try(data.vault_kv_secret_v2.viktor.data["ssh_public_key"], var.ssh_public_key)
}

# ---------------------------------------------------------------------------
# K8s node template
# ---------------------------------------------------------------------------

module "k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = data.vault_kv_secret_v2.secrets.data["ssh_private_key"]
  ssh_public_key  = local.k8s_ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.k8s_cloud_init_image_path
  template_id     = 2000
  template_name   = local.k8s_vm_template
  user_passwd     = data.vault_kv_secret_v2.secrets.data["vm_wizard_password"]

  is_k8s_template = true # provision cloud init file with k8s deps
  snippet_name    = local.k8s_cloud_init_snippet_name
  # containerd setup script now bundled in the module
  # (k8s-node-containerd-setup.sh); the deprecated variable is
  # ignored when is_k8s_template=true.
  containerd_config_update_command = ""
  k8s_join_command                 = var.k8s_join_command
}

# ---------------------------------------------------------------------------
# Non-K8s node template
# ---------------------------------------------------------------------------

module "non-k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = data.vault_kv_secret_v2.secrets.data["ssh_private_key"]
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path
  template_id     = 1000
  template_name   = local.non_k8s_vm_template
  user_passwd     = data.vault_kv_secret_v2.secrets.data["vm_wizard_password"]

  is_k8s_template = false # provision cloud init file without k8s deps
  snippet_name    = local.non_k8s_cloud_init_snippet_name
}

# ---------------------------------------------------------------------------
# Docker registry template
# ---------------------------------------------------------------------------

module "docker-registry-template" {
  source = "../../modules/create-template-vm"

  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = data.vault_kv_secret_v2.secrets.data["ssh_private_key"]
  ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHLhYDfyx237eJgOGVoJRECpUS95+7rEBS9vacsIxtx devvm"

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path # keke
  template_id     = 1001
  template_name   = "docker-registry-template"

  user_passwd = data.vault_kv_secret_v2.secrets.data["vm_wizard_password"]

  is_k8s_template = false # provision cloud init file without k8s deps
  snippet_name    = "docker-registry.yaml"

  # Setup registry config and start container
  provision_cmds = [
    # Install dependencies (QEMU guest agent + htpasswd for registry auth)
    "apt-get install -y qemu-guest-agent apache2-utils",
    "systemctl enable qemu-guest-agent",
    "systemctl start qemu-guest-agent",
    # Stop host nginx — we run nginx inside Docker instead
    "systemctl stop nginx || true",
    "systemctl disable nginx || true",
    # Create directory structure
    "mkdir -p /opt/registry/data/dockerhub /opt/registry/data/ghcr /opt/registry/data/quay /opt/registry/data/k8s /opt/registry/data/kyverno /opt/registry/data/private /opt/registry/tls",
    # Generate htpasswd file for private registry authentication
    format("htpasswd -Bbn %s %s > /opt/registry/htpasswd",
      data.vault_kv_secret_v2.viktor.data["registry_user"],
      data.vault_kv_secret_v2.viktor.data["registry_password"]
    ),
    # Write Docker Compose file
    format("echo %s | base64 -d > /opt/registry/docker-compose.yml",
      base64encode(file("${path.root}/../../modules/docker-registry/docker-compose.yml"))
    ),
    # Write nginx config
    format("echo %s | base64 -d > /opt/registry/nginx.conf",
      base64encode(file("${path.root}/../../modules/docker-registry/nginx_registry.conf"))
    ),
    # Write TLS certificate for private registry (*.viktorbarzin.me wildcard)
    format("echo %s | base64 -d > /opt/registry/tls/fullchain.pem",
      base64encode(file("${path.root}/../../secrets/fullchain.pem"))
    ),
    format("echo %s | base64 -d > /opt/registry/tls/privkey.pem && chmod 600 /opt/registry/tls/privkey.pem",
      base64encode(file("${path.root}/../../secrets/privkey.pem"))
    ),
    # Write Docker Hub registry config (with auth)
    format("echo %s | base64 -d > /opt/registry/config-dockerhub.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config.yaml", {
          password = data.vault_kv_secret_v2.secrets.data["dockerhub_registry_password"]
        })
      )
    ),
    # Write GHCR registry config
    format("echo %s | base64 -d > /opt/registry/config-ghcr.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "ghcr"
          remote_url = "https://ghcr.io"
        })
      )
    ),
    # Write Quay registry config
    format("echo %s | base64 -d > /opt/registry/config-quay.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "quay"
          remote_url = "https://quay.io"
        })
      )
    ),
    # Write registry.k8s.io registry config
    format("echo %s | base64 -d > /opt/registry/config-k8s.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "k8s"
          remote_url = "https://registry.k8s.io"
        })
      )
    ),
    # Write reg.kyverno.io registry config
    format("echo %s | base64 -d > /opt/registry/config-kyverno.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "kyverno"
          remote_url = "https://reg.kyverno.io"
        })
      )
    ),
    # Write private R/W registry config (no proxy = accepts pushes)
    format("echo %s | base64 -d > /opt/registry/config-private.yml",
      base64encode(file("${path.root}/../../modules/docker-registry/config-private.yml"))
    ),
    # Write tag cleanup script
    format("echo %s | base64 -d > /opt/registry/cleanup-tags.sh && chmod +x /opt/registry/cleanup-tags.sh",
      base64encode(file("${path.root}/../../modules/docker-registry/cleanup-tags.sh"))
    ),
    # Write blob integrity checker
    format("echo %s | base64 -d > /opt/registry/fix-broken-blobs.sh && chmod +x /opt/registry/fix-broken-blobs.sh",
      base64encode(file("${path.root}/../../modules/docker-registry/fix-broken-blobs.sh"))
    ),
    # Create systemd unit for docker compose
    format("echo %s | base64 -d > /etc/systemd/system/docker-compose-registry.service",
      base64encode(<<-UNIT
[Unit]
Description=Docker Compose Registry Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/registry
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
      )
    ),
    # Enable and start the registry stack
    "systemctl daemon-reload",
    "systemctl enable docker-compose-registry.service",
    "systemctl start docker-compose-registry.service",
    # Cron: garbage collection (weekly, Sunday 3am, staggered per registry)
    "( crontab -l 2>/dev/null; echo '0 3 * * 0 /usr/bin/docker exec registry-dockerhub registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '5 3 * * 0 /usr/bin/docker exec registry-ghcr registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '10 3 * * 0 /usr/bin/docker exec registry-quay registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '15 3 * * 0 /usr/bin/docker exec registry-k8s registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '20 3 * * 0 /usr/bin/docker exec registry-kyverno registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '25 3 * * 0 /usr/bin/docker exec registry-private registry garbage-collect -m /etc/docker/registry/config.yml >> /var/log/registry-gc.log 2>&1' ) | crontab -",
    # Cron: tag cleanup (daily 2am, keep last 10 tags per image)
    "( crontab -l 2>/dev/null; echo '0 2 * * * python3 /opt/registry/cleanup-tags.sh 10 >> /var/log/registry-cleanup.log 2>&1' ) | crontab -",
    # Cron: blob integrity check (after GC on Sunday, and daily 2:30am after tag cleanup)
    "( crontab -l 2>/dev/null; echo '30 3 * * 0 python3 /opt/registry/fix-broken-blobs.sh >> /var/log/registry-fix-blobs.log 2>&1' ) | crontab -",
    "( crontab -l 2>/dev/null; echo '30 2 * * 1-6 python3 /opt/registry/fix-broken-blobs.sh >> /var/log/registry-fix-blobs.log 2>&1' ) | crontab -",
  ]
}

# ---------------------------------------------------------------------------
# Docker registry VM (220) — INTENTIONALLY NOT MANAGED BY TERRAFORM.
#
# Same telmate/proxmox provider defect as the K8s VMs below: the
# provider doesn't refresh `mbps_*_concurrent` fields back from live
# state, so state perma-shows 0 even when live has 40. Every plan
# then proposes to "fix" mbps from 0 → 40, and the apply errors with
# "the QEMU guest needs to be rebooted" — even though the proxmox API
# call ends up being a no-op (live values already match). Pulling
# docker-registry out of TF for the same reason as the K8s VMs:
# bootstrap is reproducible via the docker-registry-template above
# + the cisnippet; VM lifecycle stays in the Proxmox UI.
#
# Pull-through cache port map (for reference; lives on the VM):
#   5000 -> nginx -> registry-dockerhub (docker.io proxy)
#   5001 -> registry-dockerhub direct (Prometheus metrics)
#   5010 -> nginx -> registry-ghcr (ghcr.io proxy)
#   5020 -> registry-quay (quay.io) — DISABLED (low traffic, corrupt images)
#   5030 -> registry-k8s (registry.k8s.io) — DISABLED (broke VPA certgen)
#   5040 -> registry-kyverno (reg.kyverno.io) — DISABLED
#   5050 -> nginx -> registry-private (R/W cache) — decom 2026-05-07
#   8080 -> registry-ui (joxit/docker-registry-ui)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# K8s node VMs — INTENTIONALLY NOT MANAGED BY TERRAFORM.
#
# The telmate/proxmox v3.0.2-rc07 provider's `disks{}` block cannot
# represent dynamically-attached disks: on every update it rewrites
# the entire disk list, and `lifecycle.ignore_changes` does NOT stop
# it. We hit this twice: id=539 (iSCSI, 2026-04-02) and the 2026-05-26
# import attempt where every `vm-9999-pvc-*` slot on k8s-node2 +
# k8s-node3 got rewritten to point at the boot disk. Recovered via the
# /mnt/backup/pve-config/etc-pve/nodes/pve/qemu-server/<vmid>.conf
# nightly backup — no reboots, no data loss, K8s CSI reconciled.
#
# Decision (2026-05-26): k8s-master (200) and k8s-node1-4 (201-204)
# stay out of TF indefinitely. Their cloud-init bootstrap IS in TF
# (via k8s-node-template + non-k8s-node-template above), so a fresh
# node still clones the template and runs the same bootstrap. The VM
# lifecycle itself (create / shutdown / config tweak) stays in the
# Proxmox UI. devvm (102), home-assistant (103), pfSense (101), and
# Windows10 (300) are also hand-managed for the same reason / out of
# scope (BSD, Windows).
#
# I/O caps for all 8 Linux VMs live in /tmp/apply-mbps-caps.sh on the
# PVE host (idempotent qm-set script — beads code-9v2j). The bpg/
# proxmox provider migration (beads code-75ds) would unblock full TF
# adoption, but it's a multi-hour project and the cloud-init coverage
# above already captures the bootstrap-reproducibility goal.
# ---------------------------------------------------------------------------
