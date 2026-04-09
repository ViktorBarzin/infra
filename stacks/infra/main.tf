# Infra stack — Proxmox VM templates and docker-registry VM
#
# Wraps the existing create-template-vm and create-vm modules with
# source paths adjusted for the stacks/infra/ working directory.

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "proxmox_host" { type = string }

variable "ssh_public_key" {
  type    = string
  default = ""
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
}

# ---------------------------------------------------------------------------
# K8s node template
# ---------------------------------------------------------------------------

module "k8s-node-template" {
  source       = "../../modules/create-template-vm"
  proxmox_host = var.proxmox_host
  proxmox_user = "root" # SSH user on Proxmox host

  ssh_private_key = data.vault_kv_secret_v2.secrets.data["ssh_private_key"]
  ssh_public_key  = var.ssh_public_key

  cloud_image_url = local.cloud_init_image_url
  image_path      = local.k8s_cloud_init_image_path
  template_id     = 2000
  template_name   = local.k8s_vm_template
  user_passwd     = data.vault_kv_secret_v2.secrets.data["vm_wizard_password"]

  is_k8s_template = true # provision cloud init file with k8s deps
  snippet_name    = local.k8s_cloud_init_snippet_name
  # Add mirror registry
  containerd_config_update_command = <<-EOF
  # Set up config_path for per-registry mirror configuration
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml

  # Create hosts.toml for docker.io (Docker Hub) — high traffic, rate-limited
  mkdir -p /etc/containerd/certs.d/docker.io
  printf 'server = "https://registry-1.docker.io"\n\n[host."http://10.0.20.10:5000"]\n  capabilities = ["pull", "resolve"]\n\n[host."https://registry-1.docker.io"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/docker.io/hosts.toml

  # Create hosts.toml for ghcr.io — medium traffic
  mkdir -p /etc/containerd/certs.d/ghcr.io
  printf 'server = "https://ghcr.io"\n\n[host."http://10.0.20.10:5010"]\n  capabilities = ["pull", "resolve"]\n\n[host."https://ghcr.io"]\n  capabilities = ["pull", "resolve"]\n' > /etc/containerd/certs.d/ghcr.io/hosts.toml

  # Create hosts.toml for private registry — both IP and hostname entries
  # IP-based (10.0.20.10:5050): direct access, skip TLS verify (wildcard cert, no IP SAN)
  mkdir -p /etc/containerd/certs.d/10.0.20.10:5050
  printf 'server = "https://10.0.20.10:5050"\n\n[host."https://10.0.20.10:5050"]\n  capabilities = ["pull", "resolve", "push"]\n  skip_verify = true\n' > /etc/containerd/certs.d/10.0.20.10:5050/hosts.toml
  # Hostname-based (registry.viktorbarzin.me): redirects to LAN IP to avoid Traefik round-trip
  mkdir -p /etc/containerd/certs.d/registry.viktorbarzin.me
  printf 'server = "https://registry.viktorbarzin.me"\n\n[host."https://10.0.20.10:5050"]\n  capabilities = ["pull", "resolve", "push"]\n  skip_verify = true\n' > /etc/containerd/certs.d/registry.viktorbarzin.me/hosts.toml

  # Low-traffic registries (registry.k8s.io, quay.io, reg.kyverno.io) pull directly.
  # Pull-through cache removed: caused corrupted images (truncated downloads)
  # breaking VPA certgen and Kyverno image pulls.

  sed -i 's/.*max_concurrent_downloads = 3/max_concurrent_downloads = 20/g' /etc/containerd/config.toml # Enable multiple concurrent downloads
  
  # Configure aggressive garbage collection to prevent disk space exhaustion (node2 incident prevention)
  # Set up containerd GC for unused images and containers
  cat >> /etc/containerd/config.toml << 'CONTAINERD_GC'

[plugins."io.containerd.gc.v1.scheduler"]
  # Run GC every 30 minutes instead of default 1 hour
  pause_threshold = 0.02
  deletion_threshold = 0
  mutation_threshold = 100
  schedule_delay = "1800s"  # 30 minutes

[plugins."io.containerd.runtime.v2.task"]
  # More aggressive container cleanup
  exit_timeout = "5m"

[plugins."io.containerd.metadata.v1.bolt"]
  # Compact database more frequently 
  compact_threshold = 5242880  # 5MB instead of default 100MB
CONTAINERD_GC
  sudo sed -i '/serializeImagePulls:/d' /var/lib/kubelet/config.yaml && \
  sudo sed -i '/maxParallelImagePulls:/d' /var/lib/kubelet/config.yaml && \
  echo -e 'serializeImagePulls: false\nmaxParallelImagePulls: 50' | sudo tee -a /var/lib/kubelet/config.yaml

  # Memory and disk reservation and eviction — prevent node OOM/disk full
  # Aggressive disk eviction settings added after node2 containerd corruption incident (2026-03-13)
  # These settings prevent disk space exhaustion that can corrupt containerd image store
  sudo sed -i '/systemReserved:/d; /kubeReserved:/d; /evictionHard:/,/^[^ ]/{ /evictionHard:/d; /^  /d }; /evictionSoft:/,/^[^ ]/{ /evictionSoft:/d; /^  /d }; /evictionSoftGracePeriod:/,/^[^ ]/{ /evictionSoftGracePeriod:/d; /^  /d }' /var/lib/kubelet/config.yaml
  cat <<'KUBELET_PATCH' | sudo tee -a /var/lib/kubelet/config.yaml
systemReserved:
  memory: "512Mi"
  cpu: "200m"
kubeReserved:
  memory: "512Mi"
  cpu: "200m"
evictionHard:
  memory.available: "500Mi"
  nodefs.available: "15%"  # More aggressive: evict at 15% free (was 10%) 
  imagefs.available: "20%"  # Much more aggressive: evict at 20% free to prevent containerd corruption
evictionSoft:
  memory.available: "1Gi"
  nodefs.available: "20%"  # Start warnings at 20% free
  imagefs.available: "25%"  # Start warnings at 25% free for containerd safety
evictionSoftGracePeriod:
  memory.available: "30s"
  nodefs.available: "60s"  # Grace period for disk space warnings
  imagefs.available: "30s"  # Shorter grace for critical containerd space
memorySwap:
  swapBehavior: "LimitedSwap"
KUBELET_PATCH

  # Remove old 2-bucket shutdown config if present (replaced by priority-based)
  sudo sed -i '/^shutdownGracePeriod:/d; /^shutdownGracePeriodCriticalPods:/d' /var/lib/kubelet/config.yaml
  # Remove old shutdownGracePeriodByPodPriority block if present (idempotent re-apply)
  sudo python3 -c "
import yaml, sys
with open('/var/lib/kubelet/config.yaml') as f:
    cfg = yaml.safe_load(f)
cfg.pop('shutdownGracePeriod', None)
cfg.pop('shutdownGracePeriodCriticalPods', None)
cfg.pop('shutdownGracePeriodByPodPriority', None)
# Container log rotation limits — reduces root disk writes (~20-30 GB/day savings)
cfg['containerLogMaxSize'] = '10Mi'
cfg['containerLogMaxFiles'] = 3
cfg['shutdownGracePeriodByPodPriority'] = [
    {'priority': 0,          'shutdownGracePeriodSeconds': 20},
    {'priority': 200000,     'shutdownGracePeriodSeconds': 20},
    {'priority': 400000,     'shutdownGracePeriodSeconds': 30},
    {'priority': 600000,     'shutdownGracePeriodSeconds': 30},
    {'priority': 800000,     'shutdownGracePeriodSeconds': 90},
    {'priority': 1000000,    'shutdownGracePeriodSeconds': 30},
    {'priority': 1200000,    'shutdownGracePeriodSeconds': 30},
    {'priority': 2000000000, 'shutdownGracePeriodSeconds': 30},
    {'priority': 2000001000, 'shutdownGracePeriodSeconds': 30},
]
with open('/var/lib/kubelet/config.yaml', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
"

  # Systemd: increase InhibitDelayMaxSec so logind doesn't force-kill before kubelet finishes graceful shutdown
  # Total kubelet shutdown time: 310s. InhibitDelay must exceed this.
  mkdir -p /etc/systemd/logind.conf.d
  cat <<'LOGIND_CONF' | sudo tee /etc/systemd/logind.conf.d/kubelet-shutdown.conf
[Login]
InhibitDelayMaxSec=480
LOGIND_CONF
  sudo systemctl restart systemd-logind

  # Systemd: increase kubelet stop timeout to match total shutdown grace period (310s + buffer)
  mkdir -p /etc/systemd/system/kubelet.service.d
  cat <<'KUBELET_SHUTDOWN' | sudo tee /etc/systemd/system/kubelet.service.d/20-shutdown.conf
[Service]
TimeoutStopSec=420s
KUBELET_SHUTDOWN
  sudo systemctl daemon-reload

  # Tune controller-manager + apiserver for faster volume detach on node failure
  # Only on master node (has static pod manifests)
  if [ -f /etc/kubernetes/manifests/kube-controller-manager.yaml ]; then
    sudo python3 -c "
import yaml
# Controller-manager: faster attach-detach reconciliation (15s vs 1m default)
with open('/etc/kubernetes/manifests/kube-controller-manager.yaml') as f:
    m = yaml.safe_load(f)
args = m['spec']['containers'][0]['command']
for flag in ['--attach-detach-reconcile-sync-period=15s']:
    key = flag.split('=')[0]
    args = [a for a in args if not a.startswith(key)]
    args.append(flag)
m['spec']['containers'][0]['command'] = args
with open('/etc/kubernetes/manifests/kube-controller-manager.yaml', 'w') as f:
    yaml.dump(m, f, default_flow_style=False)
print('controller-manager: attach-detach-reconcile-sync-period=15s')
"
    sudo python3 -c "
import yaml
# API server: faster pod eviction from unreachable nodes (60s vs 300s default)
with open('/etc/kubernetes/manifests/kube-apiserver.yaml') as f:
    m = yaml.safe_load(f)
args = m['spec']['containers'][0]['command']
for flag in ['--default-unreachable-toleration-seconds=60', '--default-not-ready-toleration-seconds=60']:
    key = flag.split('=')[0]
    args = [a for a in args if not a.startswith(key)]
    args.append(flag)
m['spec']['containers'][0]['command'] = args
with open('/etc/kubernetes/manifests/kube-apiserver.yaml', 'w') as f:
    yaml.dump(m, f, default_flow_style=False)
print('apiserver: unreachable+not-ready toleration=60s')
"
  fi
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

  # Boot order: after TrueNAS (order=2), before k8s nodes (order=4)
  startup_order    = 3
  startup_delay    = 60
  shutdown_timeout = 120

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

# ---------------------------------------------------------------------------
# K8s node VMs (imported from existing Proxmox VMs)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# K8s node VMs — imported from existing Proxmox VMs
#
# NOTE: Nodes with iSCSI PVC disks (201, 203, 204) cannot be imported yet
# due to telmate/proxmox provider bug: it constructs wrong volume references
# for shared iSCSI disks on update, causing API 500 errors. These nodes will
# be importable after migrating to the bpg/proxmox provider.
# ---------------------------------------------------------------------------

module "k8s-master" {
  source = "../../modules/create-vm"
  vmid   = 200

  vm_name        = "k8s-master"
  vm_cpus        = 8
  vm_mem_mb      = 32768
  vm_disk_size   = "64G"
  balloon        = 0
  qemu_os        = "other"
  use_cloud_init = false
  boot           = "order=scsi0"
  vm_mac_address = "00:50:56:b0:a1:39"
  bridge         = "vmbr1"
  vlan_tag       = "20"

  startup_order    = 4
  startup_delay    = 45
  shutdown_timeout = 420
}

module "k8s-node2" {
  source = "../../modules/create-vm"
  vmid   = 202

  vm_name        = "k8s-node2"
  vm_cpus        = 8
  vm_mem_mb      = 32768
  vm_disk_size   = "256G"
  balloon        = 0
  qemu_os        = "other"
  use_cloud_init = false
  boot           = "c"
  boot_disk      = "scsi0"
  vm_mac_address = "00:50:56:b0:a1:36"
  bridge         = "vmbr1"
  vlan_tag       = "20"

  startup_order    = 5
  startup_delay    = 45
  shutdown_timeout = 420
}
