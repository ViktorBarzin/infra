# Infra stack — Proxmox VM templates and docker-registry VM
#
# Wraps the existing create-template-vm and create-vm modules with
# source paths adjusted for the stacks/infra/ working directory.

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "proxmox_host" { type = string }

variable "ssh_private_key" {
  type    = string
  default = ""
  sensitive = true
}

variable "ssh_public_key" {
  type    = string
  default = ""
}

variable "vm_wizard_password" {
  type = string
  sensitive = true
}

variable "k8s_join_command" { type = string }

variable "dockerhub_registry_password" {}

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
}

# ---------------------------------------------------------------------------
# K8s node template
# ---------------------------------------------------------------------------

module "k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.k8s_cloud_init_image_path
  template_id     = 2000
  template_name   = local.k8s_vm_template
  user_passwd     = var.vm_wizard_password

  is_k8s_template = true # provision cloud init file with k8s deps
  snippet_name    = local.k8s_cloud_init_snippet_name
  # Add mirror registry
  containerd_config_update_command = <<-EOF
  # Set up config_path for per-registry mirror configuration
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml

  # Create hosts.toml for docker.io (Docker Hub) — high traffic, rate-limited
  mkdir -p /etc/containerd/certs.d/docker.io
  printf 'server = "https://registry-1.docker.io"\n\n[host."http://10.0.20.10:5000"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/docker.io/hosts.toml

  # Create hosts.toml for ghcr.io — medium traffic
  mkdir -p /etc/containerd/certs.d/ghcr.io
  printf 'server = "https://ghcr.io"\n\n[host."http://10.0.20.10:5010"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/ghcr.io/hosts.toml

  # Low-traffic registries (registry.k8s.io, quay.io, reg.kyverno.io) pull directly.
  # Pull-through cache removed: caused corrupted images (truncated downloads)
  # breaking VPA certgen and Kyverno image pulls.

  sed -i 's/.*max_concurrent_downloads = 3/max_concurrent_downloads = 20/g' /etc/containerd/config.toml # Enable multiple concurrent downloads
  sudo sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml && \
  sudo sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml && \
  echo -e 'serializeImagePulls: false\nmaxParallelImagePulls: 50' | sudo tee -a /var/lib/kubelet/config.yaml

  # Memory reservation and eviction — prevent node OOM by reserving memory
  # for OS/kubelet and evicting pods before the node runs out of memory.
  sudo sed -i '/systemReserved:/d; /kubeReserved:/d; /evictionHard:/,/^[^ ]/{ /evictionHard:/d; /^  /d }; /evictionSoft:/,/^[^ ]/{ /evictionSoft:/d; /^  /d }; /evictionSoftGracePeriod:/,/^[^ ]/{ /evictionSoftGracePeriod:/d; /^  /d }' /var/lib/kubelet/config.yaml
  cat <<'KUBELET_PATCH' | sudo tee -a /var/lib/kubelet/config.yaml
systemReserved:
  memory: "512Mi"
kubeReserved:
  memory: "512Mi"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
evictionSoft:
  memory.available: "1Gi"
evictionSoftGracePeriod:
  memory.available: "30s"
KUBELET_PATCH
  EOF
  k8s_join_command                 = var.k8s_join_command
}

# ---------------------------------------------------------------------------
# Non-K8s node template
# ---------------------------------------------------------------------------

module "non-k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path
  template_id     = 1000
  template_name   = local.non_k8s_vm_template
  user_passwd     = var.vm_wizard_password

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

  ssh_private_key = var.ssh_private_key
  ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHLhYDfyx237eJgOGVoJRECpUS95+7rEBS9vacsIxtx devvm"

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.non_k8s_cloud_init_image_path # keke
  template_id     = 1001
  template_name   = "docker-registry-template"

  user_passwd = var.vm_wizard_password

  is_k8s_template = false # provision cloud init file without k8s deps
  snippet_name    = "docker-registry.yaml"

  # Setup registry config and start container
  provision_cmds = [
    # Install and enable QEMU guest agent for remote management
    "apt-get install -y qemu-guest-agent",
    "systemctl enable qemu-guest-agent",
    "systemctl start qemu-guest-agent",
    # Stop host nginx — we run nginx inside Docker instead
    "systemctl stop nginx || true",
    "systemctl disable nginx || true",
    # Create directory structure
    "mkdir -p /opt/registry/data/dockerhub /opt/registry/data/ghcr /opt/registry/data/quay /opt/registry/data/k8s /opt/registry/data/kyverno /opt/registry/data/private /opt/registry/tls",
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
          password = var.dockerhub_registry_password
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
  ]
}

# ---------------------------------------------------------------------------
# Docker registry VM
# ---------------------------------------------------------------------------

module "docker-registry-vm" {
  source = "../../modules/create-vm"
  vmid   = 220

  vm_cpus      = 4
  vm_mem_mb    = 4196
  vm_disk_size = "64G"

  template_name  = "docker-registry-template"
  vm_name        = "docker-registry"
  cisnippet_name = "docker-registry.yaml"
  agent          = 1

  vm_mac_address = "DE:AD:BE:EF:22:22" # mapped to 10.0.20.10 in dhcp
  bridge         = "vmbr1"
  vlan_tag       = "20"
  ipconfig0      = "ip=10.0.20.10/24,gw=10.0.20.1"
  # Active pull-through caches (docker.io + ghcr.io only):
  # 5000 -> nginx -> registry-dockerhub (docker.io proxy)
  # 5001 -> registry-dockerhub direct (Prometheus metrics)
  # 5010 -> nginx -> registry-ghcr (ghcr.io proxy)
  # Disabled caches (low-traffic, caused corrupted images):
  # 5020 -> registry-quay (quay.io) — DISABLED
  # 5030 -> registry-k8s (registry.k8s.io) — DISABLED, broke VPA certgen
  # 5040 -> registry-kyverno (reg.kyverno.io) — DISABLED
  # 5050 -> nginx -> registry-private (R/W registry for CI build cache)
  # 8080 -> registry-ui (joxit/docker-registry-ui)
}
