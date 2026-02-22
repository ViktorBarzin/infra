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
}

variable "ssh_public_key" {
  type    = string
  default = ""
}

variable "vm_wizard_password" { type = string }

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

  # Create hosts.toml for docker.io (Docker Hub)
  mkdir -p /etc/containerd/certs.d/docker.io
  printf 'server = "https://registry-1.docker.io"\n\n[host."http://10.0.20.10:5000"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/docker.io/hosts.toml

  # Create hosts.toml for ghcr.io
  mkdir -p /etc/containerd/certs.d/ghcr.io
  printf 'server = "https://ghcr.io"\n\n[host."http://10.0.20.10:5010"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/ghcr.io/hosts.toml

  # Create hosts.toml for quay.io
  mkdir -p /etc/containerd/certs.d/quay.io
  printf 'server = "https://quay.io"\n\n[host."http://10.0.20.10:5020"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/quay.io/hosts.toml

  # Create hosts.toml for registry.k8s.io
  mkdir -p /etc/containerd/certs.d/registry.k8s.io
  printf 'server = "https://registry.k8s.io"\n\n[host."http://10.0.20.10:5030"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/registry.k8s.io/hosts.toml

  # Create hosts.toml for reg.kyverno.io
  mkdir -p /etc/containerd/certs.d/reg.kyverno.io
  printf 'server = "https://reg.kyverno.io"\n\n[host."http://10.0.20.10:5040"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/reg.kyverno.io/hosts.toml

  sed -i 's/.*max_concurrent_downloads = 3/max_concurrent_downloads = 20/g' /etc/containerd/config.toml # Enable multiple concurrent downloads
  sudo sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml && \
  sudo sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml && \
  echo -e 'serializeImagePulls: false\nmaxParallelImagePulls: 50' | sudo tee -a /var/lib/kubelet/config.yaml
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
    "mkdir -p /etc/docker-registry",
    format("echo %s | base64 -d > /etc/docker-registry/config.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config.yaml", {
          password = var.dockerhub_registry_password
          }
        )
      )
    ),
    "( crontab -l 2>/dev/null; echo '0 3 * * 0 /usr/bin/docker exec registry registry garbage-collect -m /etc/docker/registry/config.yml' ) | crontab -",
    # Hourly restart cron removed - it wiped the in-memory blobdescriptor cache every hour,
    # causing low cache hit rates on the pull-through proxy. Docker containers use --restart always.
    "docker run -p 5000:5000 -p 5001:5001 -d --restart always --name registry -v /etc/docker-registry/config.yml:/etc/docker/registry/config.yml registry:2",
    # ghcr.io proxy
    "mkdir -p /etc/docker-registry/ghcr",
    format("echo %s | base64 -d > /etc/docker-registry/ghcr/config.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "ghcr"
          remote_url = "https://ghcr.io"
        })
      )
    ),
    "docker run -p 5010:5000 -d --restart always --name registry-ghcr -v /etc/docker-registry/ghcr/config.yml:/etc/docker/registry/config.yml registry:2",
    "( crontab -l 2>/dev/null; echo '5 3 * * 0 /usr/bin/docker exec registry-ghcr registry garbage-collect -m /etc/docker/registry/config.yml' ) | crontab -",
    # quay.io proxy
    "mkdir -p /etc/docker-registry/quay",
    format("echo %s | base64 -d > /etc/docker-registry/quay/config.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "quay"
          remote_url = "https://quay.io"
        })
      )
    ),
    "docker run -p 5020:5000 -d --restart always --name registry-quay -v /etc/docker-registry/quay/config.yml:/etc/docker/registry/config.yml registry:2",
    "( crontab -l 2>/dev/null; echo '10 3 * * 0 /usr/bin/docker exec registry-quay registry garbage-collect -m /etc/docker/registry/config.yml' ) | crontab -",
    # registry.k8s.io proxy
    "mkdir -p /etc/docker-registry/k8s",
    format("echo %s | base64 -d > /etc/docker-registry/k8s/config.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "k8s"
          remote_url = "https://registry.k8s.io"
        })
      )
    ),
    "docker run -p 5030:5000 -d --restart always --name registry-k8s -v /etc/docker-registry/k8s/config.yml:/etc/docker/registry/config.yml registry:2",
    "( crontab -l 2>/dev/null; echo '15 3 * * 0 /usr/bin/docker exec registry-k8s registry garbage-collect -m /etc/docker/registry/config.yml' ) | crontab -",
    # reg.kyverno.io proxy
    "mkdir -p /etc/docker-registry/kyverno",
    format("echo %s | base64 -d > /etc/docker-registry/kyverno/config.yml",
      base64encode(
        templatefile("../../modules/docker-registry/config-proxy.yaml.tpl", {
          name       = "kyverno"
          remote_url = "https://reg.kyverno.io"
        })
      )
    ),
    "docker run -p 5040:5000 -d --restart always --name registry-kyverno -v /etc/docker-registry/kyverno/config.yml:/etc/docker/registry/config.yml registry:2",
    "( crontab -l 2>/dev/null; echo '20 3 * * 0 /usr/bin/docker exec registry-kyverno registry garbage-collect -m /etc/docker/registry/config.yml' ) | crontab -",
    # Setup the registry nginx config; We want clients to connect via the nginx to serialize requests for the same blobs
    # Otherwise race conditions lead to corrupt blobs
    "mkdir -p /var/cache/nginx/registry",
    format("echo %s | base64 -d > /etc/nginx/conf.d/registry.conf",
      base64encode(
        templatefile("${path.root}/../../modules/docker-registry/nginx_registry.conf", {})
      )
    ),
    "docker run -d --restart always --net host --name registry-ui -e NGINX_LISTEN_PORT=8080 -e NGINX_PROXY_PASS_URL=http://127.0.0.1:5000 -e DELETE_IMAGES=true -e SINGLE_REGISTRY=true -e SHOW_CONTENT_DIGEST=true -e SHOW_CATALOG_NB_TAGS=true -e CATALOG_ELEMENTS_LIMIT=1000 -e TAGLIST_PAGE_SIZE=100 -e REGISTRY_TITLE=viktorbarzin.me joxit/docker-registry-ui:latest",
    # Deploy tag cleanup script (keep last 10 tags per image) and schedule daily at 2am before weekly GC
    format("echo %s | base64 -d > /etc/docker-registry/cleanup-tags.sh && chmod +x /etc/docker-registry/cleanup-tags.sh",
      base64encode(file("${path.root}/../../modules/docker-registry/cleanup-tags.sh"))
    ),
    "( crontab -l 2>/dev/null; echo '0 2 * * * python3 /etc/docker-registry/cleanup-tags.sh 10 >> /var/log/registry-cleanup.log 2>&1' ) | crontab -",
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

  vm_mac_address = "DE:AD:BE:EF:22:22" # mapped to 10.0.20.10 in dhcp
  bridge         = "vmbr1"
  vlan_tag       = "20"
  ipconfig0      = "ip=10.0.20.10/24,gw=10.0.20.1"
  # ports:
  # 5000 -> registry (docker.io proxy)
  # 5001 -> metrics
  # 5002 -> nginx proxy <-- use this to prevent races on the same blobs
  # 5010 -> registry-ghcr (ghcr.io proxy)
  # 5020 -> registry-quay (quay.io proxy)
  # 5030 -> registry-k8s (registry.k8s.io proxy)
  # 5040 -> registry-kyverno (reg.kyverno.io proxy)
  # 8080 -> registry-ui (joxit/docker-registry-ui)
}
