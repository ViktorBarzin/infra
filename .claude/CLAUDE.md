# Infrastructure Repository Knowledge

## Instructions for Claude
- **When the user says "remember" something**: Always update this file (`.claude/CLAUDE.md`) with the information so it persists across sessions
- **When discovering new patterns or versions**: Add them to the appropriate section below
- **When making infrastructure changes**: Always update this file to reflect the current state (new services, removed services, version changes, config changes)
- **After every significant change**: Proactively update this file (`.claude/CLAUDE.md`) to reflect what changed — new services, config changes, version bumps, new patterns, etc. This ensures knowledge persists across sessions automatically.
- **After updating any `.claude/` files**: Always commit them immediately (`git add .claude/ && git commit -m "[ci skip] update claude knowledge"`) to avoid building up unstaged changes.
- **Skills available**: Check `.claude/skills/` directory for specialized workflows (e.g., `setup-project.md` for deploying new services)
- **CRITICAL: All infrastructure changes must go through Terraform**. NEVER modify cluster resources directly (e.g., via kubectl apply/edit/patch, helm install, docker run). Always make changes in the Terraform `.tf` files and apply with `terraform apply`.

## Execution Environment
- **File operations**: Read, Edit, Write, Glob, Grep tools
- **Git commands**: git status, git log, git diff, git add, git commit, git reset, etc.
- **Shell commands**: All tools (terraform, kubectl, helm, python, etc.) are available locally
- **CRITICAL: Always run terraform locally**, never on the remote server via SSH. Use `-var="kube_config_path=$(pwd)/config"` when applying:
  ```bash
  terraform apply -target=module.kubernetes_cluster.module.<service> -var="kube_config_path=$(pwd)/config" -auto-approve
  ```
- **kubectl**: Use `kubectl --kubeconfig $(pwd)/config` for cluster access

---

## Overview
Terraform-based infrastructure repository managing a home Kubernetes cluster on Proxmox VMs. Uses git-crypt for secrets encryption.

## Static File Paths (NEVER CHANGE)
- **Main config**: `terraform.tfvars` - All secrets, DNS, Cloudflare config, WireGuard peers
- **Root terraform**: `main.tf` - Proxmox provider, VM templates, kubernetes_cluster module
- **K8s services**: `modules/kubernetes/main.tf` - All service module definitions
- **Secrets**: `secrets/` - git-crypt encrypted TLS certs and keys

## Network Topology (Static IPs)
```
┌─────────────────────────────────────────────────────────────────┐
│ 10.0.10.0/24 - Management Network                               │
├─────────────────────────────────────────────────────────────────┤
│ 10.0.10.10  - Wizard (main server)                               │
│ 10.0.10.15  - NFS Server (TrueNAS) - /mnt/main/*                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 10.0.20.0/24 - Kubernetes Network                               │
├─────────────────────────────────────────────────────────────────┤
│ 10.0.20.1   - pfSense Gateway                                   │
│ 10.0.20.10  - Docker Registry VM (MAC: DE:AD:BE:EF:22:22)       │
│ 10.0.20.100 - k8s-master                                        │
│ 10.0.20.101 - Technitium DNS                                    │
│ 10.0.20.102 - MetalLB IP Pool Start                             │
│ 10.0.20.200 - MetalLB IP Pool End                               │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 192.168.1.0/24 - Physical Network                               │
├─────────────────────────────────────────────────────────────────┤
│ 192.168.1.127 - Proxmox Hypervisor                              │
└─────────────────────────────────────────────────────────────────┘
```

## Domains
- **Public**: `viktorbarzin.me` (Cloudflare-managed)
- **Internal**: `viktorbarzin.lan` (Technitium DNS)

## Directory Structure
- `main.tf` - Main Terraform entry point, imports all modules
- `modules/kubernetes/` - Kubernetes service deployments (one folder per service)
- `modules/create-vm/` - Proxmox VM creation module
- `secrets/` - Encrypted secrets (TLS certs, keys) via git-crypt
- `cli/` - Go CLI tool for infrastructure management
- `scripts/` - Helper scripts (cluster management, node updates)
- `playbooks/` - Ansible playbooks for node configuration
- `diagram/` - Infrastructure diagrams (Python-based)

## Key Patterns
- Each service in `modules/kubernetes/<service>/main.tf` defines its own namespace, deployments, services, and ingress
- NFS storage from `10.0.10.15` for persistent data
- TLS secrets managed via `setup_tls_secret` module
- Ingress uses Traefik (Helm chart, 3 replicas) with HTTP/3 (QUIC) enabled, Middleware CRDs for rate limiting, auth, CSP headers, CrowdSec bouncer, and analytics injection
- HTTP/3 enabled on Traefik (`http3.enabled=true`, `advertisedPort=443` on websecure entrypoint) and Cloudflare (`cloudflare_zone_settings_override` with `http3="on"`)
- GPU workloads use `node_selector = { "gpu": "true" }`
- Services expose to `*.viktorbarzin.me` domains

### NFS Volume Pattern
**Prefer inline NFS volumes** over separate PV/PVC resources. Use the `nfs {}` block directly in pod/deployment/cronjob specs:
```hcl
volume {
  name = "data"
  nfs {
    server = "10.0.10.15"
    path   = "/mnt/main/<service>"
  }
}
```
Only use PV/PVC when the Helm chart requires `existingClaim` (like the Nextcloud Helm chart).

### Adding NFS Exports
To add a new NFS exported directory:
1. Edit `nfs_directories.txt` - add the new directory path, keep the list sorted
2. Run `nfs_exports.sh` to create the NFS export

### Factory Pattern (for multi-user services)
Used when a service needs one instance per user. Structure:
```
modules/kubernetes/<service>/
├── main.tf           # Namespace, TLS secret, user module calls
└── factory/
    └── main.tf       # Deployment, service, ingress templates with ${var.name}
```
Examples: `actualbudget`, `freedify`

To add a new user:
1. Export NFS share at `/mnt/main/<service>/<username>` in TrueNAS
2. Add Cloudflare route in tfvars
3. Add module block in main.tf calling factory

### Init Container Pattern (for database migrations)
Use when a service needs to run database migrations before starting:
```hcl
init_container {
  name    = "migration"
  image   = "service-image:tag"
  command = ["sh", "-c", "migration-command"]

  dynamic "env" {
    for_each = local.common_env
    content {
      name  = env.value.name
      value = env.value.value
    }
  }
}
```
Example: AFFiNE runs `node ./scripts/self-host-predeploy.js` in init container.

### SMTP/Email Configuration
When configuring services to use the mailserver:
- **Use public hostname**: `mail.viktorbarzin.me` (for TLS cert validation)
- **Do NOT use**: `mailserver.mailserver.svc.cluster.local` (TLS cert mismatch)
- **Port**: 587 (STARTTLS)
- **Credentials**: Use existing accounts from `mailserver_accounts` in tfvars
- **Common email**: `info@viktorbarzin.me` for service notifications

## Common Variables
- `tls_secret_name` - TLS certificate secret name
- `tier` - Deployment tier label
- Service-specific passwords passed as variables

## Service Versions (as of 2025-01)
- Immich: v2.4.1
- Freedify: latest (music streaming, factory pattern)
- AFFiNE: stable (visual canvas, uses PostgreSQL + Redis)

## Useful Commands
```bash
# ALWAYS use -target for terraform apply (speeds up execution)
terraform apply -target=module.kubernetes_cluster.module.<service_name>
terraform plan -target=module.kubernetes_cluster.module.<service_name>
terraform fmt -recursive
kubectl get pods -A
```

**Terraform target examples:**
- `terraform apply -target=module.kubernetes_cluster.module.monitoring` - Apply monitoring
- `terraform apply -target=module.kubernetes_cluster.module.immich` - Apply immich
- `terraform apply -target=module.docker-registry-vm` - Apply docker registry VM
- Only skip `-target` when explicitly told to apply everything

## Module Structure
Top-level modules in `main.tf`:
- `module.k8s-node-template` - K8s node VM template
- `module.non-k8s-node-template` - Non-k8s VM template
- `module.docker-registry-template` - Docker registry template
- `module.docker-registry-vm` - Docker registry VM
- `module.kubernetes_cluster` - Main K8s cluster (contains all services)

---

## Complete Service Catalog

### DEFCON Level 1 (Critical - Network & Auth)
| Service | Description | Tier |
|---------|-------------|------|
| wireguard | VPN server | core |
| technitium | DNS server (10.0.20.101) | core |
| headscale | Tailscale control server | core |
| traefik | Ingress controller (Helm) | core |
| xray | Proxy/tunnel | core |
| authentik | Identity provider (SSO) | core |
| cloudflared | Cloudflare tunnel | core |
| authelia | Auth middleware | core |
| monitoring | Prometheus/Grafana stack | core |

### DEFCON Level 2 (Storage & Security)
| Service | Description | Tier |
|---------|-------------|------|
| vaultwarden | Bitwarden-compatible password manager | cluster |
| redis | Shared Redis at `redis.redis.svc.cluster.local` | cluster |
| immich | Photo management (GPU) | gpu |
| nvidia | GPU device plugin | gpu |
| metrics-server | K8s metrics | cluster |
| uptime-kuma | Status monitoring | cluster |
| crowdsec | Security/WAF | cluster |
| kyverno | Policy engine | cluster |

### DEFCON Level 3 (Admin)
| Service | Description | Tier |
|---------|-------------|------|
| k8s-dashboard | Kubernetes dashboard | edge |
| reverse-proxy | Generic reverse proxy | edge |

### DEFCON Level 4 (Active Use)
| Service | Description | Tier |
|---------|-------------|------|
| mailserver | Email (docker-mailserver) | edge |
| shadowsocks | Proxy | edge |
| webhook_handler | Webhook processing | edge |
| tuya-bridge | Smart home bridge | edge |
| dawarich | Location history | edge |
| owntracks | Location tracking | edge |
| nextcloud | File sync/share | edge |
| calibre | E-book management | edge |
| onlyoffice | Document editing | edge |
| f1-stream | F1 streaming | edge |
| rybbit | Analytics | edge |
| isponsorblocktv | SponsorBlock for TV | edge |
| actualbudget | Budgeting (factory pattern) | aux |

### DEFCON Level 5 (Optional)
| Service | Description | Tier |
|---------|-------------|------|
| blog | Personal blog | aux |
| descheduler | Pod descheduler | aux |
| drone | CI/CD | aux |
| hackmd | Collaborative markdown | aux |
| kms | Key management | aux |
| privatebin | Encrypted pastebin | aux |
| vault | HashiCorp Vault | aux |
| reloader | ConfigMap/Secret reloader | aux |
| city-guesser | Game | aux |
| echo | Echo server | aux |
| url | URL shortener | aux |
| excalidraw | Whiteboard | aux |
| travel_blog | Travel blog | aux |
| dashy | Dashboard | aux |
| send | Firefox Send | aux |
| ytdlp | YouTube downloader | aux |
| wealthfolio | Finance tracking | aux |
| audiobookshelf | Audiobook server | aux |
| paperless-ngx | Document management | aux |
| jsoncrack | JSON visualizer | aux |
| servarr | Media automation (Sonarr/Radarr/etc) | aux |
| ntfy | Push notifications | aux |
| cyberchef | Data transformation | aux |
| diun | Docker image update notifier | aux |
| meshcentral | Remote management | aux |
| homepage | Dashboard/startpage | aux |
| matrix | Matrix chat server | aux |
| linkwarden | Bookmark manager | aux |
| changedetection | Web change detection | aux |
| tandoor | Recipe manager | aux |
| n8n | Workflow automation | aux |
| real-estate-crawler | Property crawler | aux |
| tor-proxy | Tor proxy | aux |
| forgejo | Git forge | aux |
| freshrss | RSS reader | aux |
| navidrome | Music streaming | aux |
| networking-toolbox | Network tools | aux |
| stirling-pdf | PDF tools | aux |
| speedtest | Speed testing | aux |
| freedify | Music streaming (factory pattern) | aux |
| netbox | Network documentation | aux |
| infra-maintenance | Maintenance jobs | aux |
| ollama | LLM server (GPU) | gpu |
| frigate | NVR/camera (GPU) | gpu |
| ebook2audiobook | E-book to audio (GPU) | gpu |
| affine | Visual canvas/whiteboard (PostgreSQL + Redis) | aux |

---

## Cloudflare Domains

### Proxied (CDN + WAF enabled)
```
blog, hackmd, privatebin, url, echo, f1tv, excalidraw, send,
audiobookshelf, jsoncrack, ntfy, cyberchef, homepage, linkwarden,
changedetection, tandoor, n8n, stirling-pdf, dashy, city-guesser,
travel, netbox
```

### Non-Proxied (Direct DNS)
```
mail, wg, headscale, immich, calibre, vaultwarden, drone,
mailserver-antispam, mailserver-admin, webhook, uptime,
owntracks, dawarich, tuya, meshcentral, nextcloud, actualbudget,
onlyoffice, forgejo, freshrss, navidrome, ollama, openwebui,
isponsorblocktv, speedtest, freedify, rybbit, paperless,
servarr, prowlarr, bazarr, radarr, sonarr, flaresolverr,
jellyfin, jellyseerr, tdarr, affine
```

### Special Subdomains
- `*.viktor.actualbudget` - Actualbudget factory instances
- `*.freedify` - Freedify factory instances
- `mailserver.*` - Mail server components (antispam, admin)

---

## CI/CD
- Drone CI (`.drone.yml`) for automated deployments
- Auto-updates TLS certificates
- **ALWAYS add `[ci skip]` to commit messages** when you've already run `terraform apply` to avoid triggering CI redundantly
- **After committing, run `git push origin master`** to sync changes

## Infrastructure
- Proxmox hypervisor for VMs (192.168.1.127)
- Kubernetes cluster with GPU node (5 nodes: k8s-master + k8s-node1-4, running v1.34.2)
- NFS server at 10.0.10.15 for storage
- Redis shared service at `redis.redis.svc.cluster.local`
- Docker registry at 10.0.20.10

### Proxmox Host Hardware
- **CPU**: Intel Xeon E5-2699 v4 @ 2.20GHz (22 cores / 44 threads, single socket)
- **RAM**: 142 GB (Dell R730 server)
- **GPU**: NVIDIA Tesla T4 (PCIe passthrough to k8s-node1)
- **Disks**: 1.1TB + 931GB + 10.7TB (local storage)
- **Proxmox access**: `ssh root@192.168.1.127`

### Proxmox Network Bridges
- **vmbr0**: Physical bridge on `eno1`, IP `192.168.1.127/24` — connects to physical/home network (192.168.1.0/24)
- **vmbr1**: Internal-only bridge (no physical port), VLAN-aware — carries VLAN 10 (management 10.0.10.0/24) and VLAN 20 (kubernetes 10.0.20.0/24)

### Proxmox VM Inventory

| VMID | Name | Status | CPUs | RAM | Network | Disk | Notes |
|------|------|--------|------|-----|---------|------|-------|
| 101 | pfsense | running | 8 | 16GB | vmbr0, vmbr1:vlan10, vmbr1:vlan20 | 32G | Gateway/firewall, routes between all networks |
| 102 | devvm | running | 16 | 8GB | vmbr1:vlan10 | 100G | Development VM on management network |
| 103 | home-assistant | running | 8 | 16GB | vmbr1:vlan10(down), vmbr0 | 32G | Home Assistant, net0 link disabled, uses vmbr0 |
| 105 | pbs | stopped | 16 | 8GB | vmbr1:vlan10 | 32G | Proxmox Backup Server (not in use) |
| 200 | k8s-master | running | 8 | 16GB | vmbr1:vlan20 | 64G | Kubernetes control plane (10.0.20.100) |
| 201 | k8s-node1 | running | 16 | 24GB | vmbr1:vlan20 | 128G | GPU node, Tesla T4 passthrough (hostpci0) |
| 202 | k8s-node2 | running | 8 | 16GB | vmbr1:vlan20 | 64G | K8s worker node |
| 203 | k8s-node3 | running | 8 | 16GB | vmbr1:vlan20 | 64G | K8s worker node |
| 204 | k8s-node4 | running | 8 | 16GB | vmbr1:vlan20 | 64G | K8s worker node |
| 220 | docker-registry | running | 4 | 4GB | vmbr1:vlan20 | 64G | Terraform-managed, MAC DE:AD:BE:EF:22:22 (10.0.20.10) |
| 300 | Windows10 | running | 16 | 8GB | vmbr0 | 100G | Windows VM on physical network |
| 9000 | truenas | running | 16 | 16GB | vmbr1:vlan10 | 32G+7×256G+1T | NFS server (10.0.10.15), multiple data disks |

#### VM Templates (stopped, used for cloning)
| VMID | Name | Purpose |
|------|------|---------|
| 1000 | ubuntu-2404-cloudinit-non-k8s-template | Base template for non-K8s VMs |
| 1001 | docker-registry-template | Template for docker registry VM |
| 2000 | ubuntu-2404-cloudinit-k8s-template | Base template for K8s nodes |

#### Network Connectivity Summary
- **pfSense (101)** bridges all three networks: physical (vmbr0), management VLAN 10, and kubernetes VLAN 20
- **K8s cluster** (200-204) + **docker-registry** (220) are all on VLAN 20 (kubernetes network)
- **TrueNAS** (9000) + **devvm** (102) + **PBS** (105) are on VLAN 10 (management network)
- **Home Assistant** (103) is on physical network (vmbr0), with a disabled VLAN 10 interface
- **Windows10** (300) is on physical network (vmbr0) only

### GPU Node (k8s-node1)
- **VMID**: 201
- **PCIe Passthrough**: `0000:06:00.0` (NVIDIA Tesla T4)
- **Taint**: `nvidia.com/gpu=true:NoSchedule` - Only GPU workloads can run here
- **Label**: `gpu=true`
- GPU workloads must have both:
  - `node_selector = { "gpu": "true" }`
  - `toleration { key = "nvidia.com/gpu", operator = "Equal", value = "true", effect = "NoSchedule" }`
- Taint is applied via `null_resource.gpu_node_taint` in `modules/kubernetes/nvidia/main.tf`

## Git Operations (IMPORTANT)
- **Git is slow** on this repo due to many files - commands can take 30+ seconds
- Use `GIT_OPTIONAL_LOCKS=0` prefix if git hangs
- Always commit only specific files you changed, not everything
- **ALWAYS ask user before pushing to remote** - never push without explicit confirmation

## Prometheus Alerts
- Alert rules are in `modules/kubernetes/monitoring/prometheus_chart_values.tpl`
- Under `serverFiles.alerting_rules.yml.groups`
- Groups: "R730 Host", "Nvidia Tesla T4 GPU", "Power", "Cluster"
- kube-state-metrics provides: `kube_deployment_*`, `kube_statefulset_*`, `kube_daemonset_*`

## Tier System
- **0-core**: Critical infrastructure (ingress, DNS, VPN, auth)
- **1-cluster**: Cluster services (Redis, metrics, security)
- **2-gpu**: GPU workloads (Immich, Ollama, Frigate)
- **3-edge**: User-facing services
- **4-aux**: Optional/auxiliary services

---

## User Preferences

### Calendar
- **Default calendar**: Nextcloud (always use unless otherwise specified)
- **Nextcloud URL**: `https://nextcloud.viktorbarzin.me`
- **CalDAV endpoint**: `https://nextcloud.viktorbarzin.me/remote.php/dav/calendars/<username>/<calendar-name>/`

### Home Assistant
- **Default smart home**: Home Assistant (always use for smart home control)
- **Two deployments**:
  - **ha-london** (default): `https://ha-london.viktorbarzin.me` | Script: `.claude/home-assistant.py`
  - **ha-sofia**: `https://ha-sofia.viktorbarzin.me` | Script: `.claude/home-assistant-sofia.py` | SSH: `ssh vbarzin@192.168.1.8`, config at `/config/`
- **Aliases**: "ha" or "HA" = ha-london. "ha sofia" or "ha-sofia" = ha-sofia.

### Development
- **Frontend framework**: Svelte (user is learning it, so use Svelte for all new web apps)

---

## Skills & Workflows

Skills are specialized workflows for common tasks. Located in `.claude/skills/`.

### Available Skills

**setup-project** (`.claude/skills/setup-project.md`)
- Deploy new self-hosted services from GitHub repos
- Automated workflow: Docker image → Terraform module → Deploy
- Handles database setup, ingress, DNS configuration
- **When to use**: User provides GitHub URL or wants to deploy a new service
- **Example**: "Deploy [GitHub repo] to the cluster"

---

## Service-Specific Notes

### AFFiNE (Visual Canvas)
- **Image**: `ghcr.io/toeverything/affine:stable`
- **Port**: 3010
- **Requires**: PostgreSQL + Redis
- **Migration**: Init container runs `node ./scripts/self-host-predeploy.js`
- **Storage**: NFS at `/mnt/main/affine` mounted to `/root/.affine/storage` and `/root/.affine/config`
- **Key env vars**:
  - `AFFINE_SERVER_EXTERNAL_URL` - Public URL (e.g., `https://affine.viktorbarzin.me`)
  - `AFFINE_SERVER_HTTPS` - Set to `true` behind TLS ingress
  - `DATABASE_URL` - PostgreSQL connection string
  - `REDIS_SERVER_HOST` - Redis hostname
  - `MAILER_*` - SMTP configuration for email invites
- **Local-first**: Data stored in browser by default; syncs to server when user creates account
- **Docs**: https://docs.affine.pro/self-host-affine
