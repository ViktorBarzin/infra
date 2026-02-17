# Infrastructure Repository Knowledge

## Instructions for Claude
- **When the user says "remember" something**: Always update this file (`.claude/CLAUDE.md`) with the information so it persists across sessions
- **When discovering new patterns or versions**: Add them to the appropriate section below
- **When making infrastructure changes**: Always update this file to reflect the current state (new services, removed services, version changes, config changes)
- **After every significant change**: Proactively update this file (`.claude/CLAUDE.md`) to reflect what changed — new services, config changes, version bumps, new patterns, etc. This ensures knowledge persists across sessions automatically.
- **After updating any `.claude/` files**: Always commit them immediately (`git add .claude/ && git commit -m "[ci skip] update claude knowledge"`) to avoid building up unstaged changes.
- **Skills available**: Check `.claude/skills/` directory for specialized workflows (e.g., `setup-project.md` for deploying new services)
- **CRITICAL: All infrastructure changes must go through Terraform**. NEVER modify cluster resources directly (e.g., via kubectl apply/edit/patch, helm install, docker run). Always make changes in the Terraform `.tf` files and apply with `terraform apply`. The real cluster state must never deviate from what's defined in Terraform — if a manual change is unavoidable (e.g., containerd config on running nodes), document it and ensure the Terraform templates match so future provisioning is consistent. Use `kubectl` only for read-only operations (get, describe, logs) and ephemeral debugging (run --rm, delete stuck pods), never for persistent state changes.
- **CRITICAL: NEVER put sensitive data (API keys, passwords, tokens, credentials) into committed files** unless they are encrypted (e.g., via git-crypt). Secrets belong in `terraform.tfvars` (which is git-crypt encrypted) or in the `secrets/` directory. Never hardcode credentials in `.tf` files, scripts, `.claude/` files, or any other unencrypted committed file. Always pass secrets through the Terraform variable chain (`terraform.tfvars` → `main.tf` → module variables).

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
1. Edit `secrets/nfs_directories.txt` - add the new directory path, keep the list sorted
2. Run `secrets/nfs_exports.sh` from the `secrets/` directory to update the NFS share via TrueNAS API

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
- Wyoming Whisper: latest (STT for Home Assistant, CPU on GPU node)
- Health: latest (Apple Health data dashboard, Svelte + FastAPI + Caddy, uses PostgreSQL)
- Gramps Web: latest (genealogy, uses Redis + Celery)
- Loki: 3.6.5 (log aggregation, single binary, 6Gi RAM, 24h in-memory chunks)
- Alloy: v1.13.0 (log collector DaemonSet, forwards to Loki)

## Useful Commands
```bash
# Cluster health check — ALWAYS use this to check cluster status
bash scripts/cluster_healthcheck.sh            # Full color report
bash scripts/cluster_healthcheck.sh --quiet    # Only WARN/FAIL
bash scripts/cluster_healthcheck.sh --json     # Machine-readable
bash scripts/cluster_healthcheck.sh --fix      # Auto-delete evicted pods

# ALWAYS use -target for terraform apply (speeds up execution)
terraform apply -target=module.kubernetes_cluster.module.<service_name>
terraform plan -target=module.kubernetes_cluster.module.<service_name>
terraform fmt -recursive
kubectl get pods -A
```

**Cluster Health Check** (`scripts/cluster_healthcheck.sh`):
- **ALWAYS use this script** to check cluster health — whether the user asks explicitly, after deploying/updating services, or whenever you need to verify cluster state. Never use ad-hoc kubectl commands to assess overall cluster health; use the script instead.
- Runs 14 checks: nodes, resources, conditions, pods, evicted, DaemonSets, deployments, PVCs, HPAs, CronJobs, CrowdSec, ingress, Prometheus alerts, Uptime Kuma
- **When adding new healthchecks or monitoring**: Always update this script to validate the new component

**Terraform target examples:**
- `terraform apply -target=module.kubernetes_cluster.module.monitoring` - Apply monitoring
- `terraform apply -target=module.kubernetes_cluster.module.immich` - Apply immich
- `terraform apply -target=module.docker-registry-vm` - Apply docker registry VM
- Only skip `-target` when explicitly told to apply everything

**IMPORTANT: When deploying a new service**, you must ALSO apply the `cloudflared` module to create the Cloudflare DNS record:
```bash
terraform apply -target=module.kubernetes_cluster.module.cloudflared -var="kube_config_path=$(pwd)/config" -auto-approve
```
Adding a name to `cloudflare_non_proxied_names` or `cloudflare_proxied_names` in `terraform.tfvars` only defines the record — it won't be created until the `cloudflared` module is applied.

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
| monitoring | Prometheus/Grafana/Loki stack | core |

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
| health | Apple Health data dashboard (PostgreSQL) | aux |
| whisper | Wyoming Faster Whisper STT (CPU on GPU node) | gpu |
| grampsweb | Genealogy web app (Gramps Web) | aux |

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
jellyfin, jellyseerr, tdarr, affine, health, family
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
- Docker registry pull-through cache at 10.0.20.10 (static IP via cloud-init)
  - Port 5000: docker.io (Docker Hub, with auth)
  - Port 5010: ghcr.io
  - Port 5020: quay.io
  - Port 5030: registry.k8s.io
  - Port 5040: reg.kyverno.io
  - Worker nodes use `config_path = "/etc/containerd/certs.d"` with per-registry `hosts.toml` files
  - k8s-master does NOT use pull-through cache (containerd 1.6.x incompatibility with config_path + mirrors)

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

### Future: Terraform State Splitting (TODO)
The current monolithic architecture (826 resources, 14MB state, 85 modules in one root) makes `terraform plan/apply` slow. Plan to split into separate root modules ("stacks") with independent state files:

**Why it's slow:**
- Single state file (14MB) loaded on every plan/apply
- 85 service modules evaluated even when changing one service
- `null_resource.core_services` creates serial dependency bottleneck blocking parallelism
- 3 providers (kubernetes, helm, proxmox) all initialize on every run
- DEFCON `contains()` evaluated on all 85 module blocks

**Proposed split** (separate root modules, each with own state):
- `stacks/infra/` — Proxmox VMs, docker-registry, templates
- `stacks/core/` — traefik, metallb, calico, technitium, wireguard (~12 modules)
- `stacks/auth/` — authentik, authelia, crowdsec, kyverno
- `stacks/storage/` — redis, dbaas, vaultwarden
- `stacks/media/` — immich, navidrome, calibre, audiobookshelf, servarr
- `stacks/gpu/` — ollama, frigate, immich-ml, whisper
- `stacks/apps/` — blog, hackmd, nextcloud, dashy, excalidraw, etc.

**Cross-stack refs** via `terraform_remote_state` data source (local backend). No Terragrunt needed — plain Terraform + shell script for multi-stack operations. Migration via `terraform state mv` one tier at a time.

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

### Resource Governance (Kyverno-based)
Four layers of noisy-neighbor protection, all defined in `modules/kubernetes/kyverno/resource-governance.tf`:

1. **PriorityClasses**: `tier-0-core` (1M) through `tier-4-aux` (200K). `tier-4-aux` uses `preemption_policy=Never`.
2. **LimitRange defaults** (Kyverno generate): Auto-creates `tier-defaults` LimitRange in namespaces based on tier label. Only affects containers without explicit resources.
3. **ResourceQuotas** (Kyverno generate): Auto-creates `tier-quota` ResourceQuota in namespaces with tier labels. Excludes namespaces with `resource-governance/custom-quota=true` label.
4. **Priority injection** (Kyverno mutate): Sets `priorityClassName` on Pods based on namespace tier label.

**Custom quota override**: Add label `resource-governance/custom-quota: "true"` to namespace, then define a custom `kubernetes_resource_quota` in the service's Terraform module. Currently used by: monitoring, crowdsec.

**LimitRange defaults by tier**:
| Tier | Default Req | Default Limit | Max |
|------|------------|--------------|-----|
| 0-core | 100m/128Mi | 2/4Gi | 8/16Gi |
| 1-cluster | 100m/128Mi | 2/4Gi | 4/8Gi |
| 2-gpu | 100m/256Mi | 4/8Gi | 8/16Gi |
| 3-edge | 50m/128Mi | 1/2Gi | 4/8Gi |
| 4-aux | 25m/64Mi | 500m/1Gi | 2/4Gi |

---

## User Preferences

### Calendar
- **Default calendar**: Nextcloud (always use unless otherwise specified)
- **Nextcloud URL**: `https://nextcloud.viktorbarzin.me`
- **CalDAV endpoint**: `https://nextcloud.viktorbarzin.me/remote.php/dav/calendars/<username>/<calendar-name>/`

### Home Assistant
- **Default smart home**: Home Assistant (always use for smart home control)
- **Two deployments**:
  - **ha-london** (default): `https://ha-london.viktorbarzin.me` | Script: `.claude/home-assistant.py` | SSH: `ssh pi@192.168.8.103`, config at `/home/pi/docker/homeAssistant/`
  - **ha-sofia**: `https://ha-sofia.viktorbarzin.me` | Script: `.claude/home-assistant-sofia.py` | SSH: `ssh vbarzin@192.168.1.8`, config at `/config/`
- **Aliases**: "ha" or "HA" = ha-london. "ha sofia" or "ha-sofia" = ha-sofia.

### Development
- **Frontend framework**: Svelte (user is learning it, so use Svelte for all new web apps)

### Pod Monitoring After Updates
- **Never use `sleep` to wait for pods** — instead, spawn a background subagent (Task tool with `run_in_background: true`) that continuously checks pod state (e.g., `kubectl get pods -n <namespace> -w`) and reports back when the pod is ready or if errors occur. This catches CrashLoopBackOff, ImagePullBackOff, and other failures much sooner than periodic sleep-based polling.

---

## Skills & Workflows

Skills are specialized workflows for common tasks. Located in `.claude/skills/`.

### Available Skills

**setup-project** (`.claude/skills/setup-project/SKILL.md`)
- Deploy new self-hosted services from GitHub repos
- Automated workflow: Docker image → Terraform module → Deploy
- Handles database setup, ingress, DNS configuration
- **When to use**: User provides GitHub URL or wants to deploy a new service
- **Example**: "Deploy [GitHub repo] to the cluster"

**extend-vm-storage** (`.claude/skills/extend-vm-storage/SKILL.md`)
- Extend disk storage on K8s node VMs (Proxmox-hosted)
- Automates: drain → shutdown → resize → boot → expand filesystem → uncordon
- **When to use**: A k8s node needs more disk space
- **Example**: "Extend storage on k8s-node2 by 64G"

---

## Service-Specific Notes

### Authentik (Identity Provider)
- **Helm Chart**: `authentik` v2025.10.3 from `https://charts.goauthentik.io/`
- **URL**: `https://authentik.viktorbarzin.me`
- **API**: `https://authentik.viktorbarzin.me/api/v3/`
- **API Token**: Stored as "Claude API" token in Authentik UI (Directory → Tokens)
- **Namespace**: `authentik` (tier: cluster)
- **Architecture**: 3 server replicas + 3 worker replicas + 3 PgBouncer replicas + 1 embedded outpost
- **Database**: PostgreSQL via `postgresql.dbaas:5432`, pooled through PgBouncer at `pgbouncer.authentik:6432`
- **Redis**: Shared at `redis.redis.svc.cluster.local`
- **Terraform**: `modules/kubernetes/authentik/main.tf` (Helm), `pgbouncer.tf` (connection pooling)

#### Authentik API Management
To call the API, use:
```bash
curl -s -H "Authorization: Bearer <TOKEN>" "https://authentik.viktorbarzin.me/api/v3/<endpoint>/"
```

Key API endpoints:
- `core/users/` — List/create/update/delete users
- `core/groups/` — List/create/update/delete groups
- `core/applications/` — List/create applications
- `providers/all/` — List all providers (OAuth2, Proxy, etc.)
- `providers/oauth2/` — OAuth2/OIDC providers specifically
- `providers/proxy/` — Proxy providers (forward auth)
- `flows/instances/` — List flows
- `stages/all/` — List stages
- `sources/all/` — List sources (Google, GitHub, etc.)
- `outposts/instances/` — List outposts
- `propertymappings/all/` — List property mappings
- `rbac/roles/` — List roles

#### Current Applications (8)
| Application | Provider Type | Auth Flow |
|-------------|--------------|-----------|
| Cloudflare Access | OAuth2/OIDC | explicit consent |
| Domain wide catch all | Proxy (forward auth) | implicit consent |
| Grafana | OAuth2/OIDC | implicit consent |
| Headscale | OAuth2/OIDC | explicit consent |
| Immich | OAuth2/OIDC | explicit consent |
| linkwarden | OAuth2/OIDC | explicit consent |
| Matrix | OAuth2/OIDC | implicit consent |
| wrongmove | OAuth2/OIDC | implicit consent |

#### Current Groups (6)
| Group | Parent | Superuser | Purpose |
|-------|--------|-----------|---------|
| Allow Login Users | — | No | Parent group for login-permitted users |
| authentik Admins | — | Yes | Full admin access |
| authentik Read-only | — | No | Read-only access (has role) |
| Headscale Users | Allow Login Users | No | VPN access |
| Home Server Admins | Allow Login Users | No | Server admin access |
| Wrongmove Users | Allow Login Users | No | Real-estate app access |

#### Current Users (7 real users)
| Username | Name | Type | Groups |
|----------|------|------|--------|
| akadmin | authentik Default Admin | internal | authentik Admins, Home Server Admins, Headscale Users |
| vbarzin@gmail.com | Viktor Barzin | internal | authentik Admins, Home Server Admins, Wrongmove Users, Headscale Users |
| emil.barzin@gmail.com | Emil Barzin | internal | Home Server Admins, Headscale Users |
| ancaelena98@gmail.com | Anca Milea | external | Wrongmove Users, Headscale Users |
| vabbit81@gmail.com | GHEORGHE Milea | external | Headscale Users |
| valentinakolevabarzina@gmail.com | Валентина Колева-Барзина | internal | Headscale Users |
| anca.r.cristian10@gmail.com | — | internal | Wrongmove Users |
| kadir.tugan@gmail.com | Kadir | internal | Wrongmove Users |

#### Login Sources (Social Login)
- **Google** (OAuth) — user matching by identifier
- **GitHub** (OAuth) — user matching by email_link
- **Facebook** (OAuth) — user matching by email_link
- All use the same authentication flow (`1a779f24`) and enrollment flow (`87572804`)

#### Authorization Flows
- **Explicit consent** (`default-provider-authorization-explicit-consent`): Shows consent screen before redirecting — used for Immich, Linkwarden, Headscale, Cloudflare
- **Implicit consent** (`default-provider-authorization-implicit-consent`): Auto-redirects without consent — used for Grafana, Matrix, Domain catch-all, Wrongmove

#### Traefik Integration
- Forward auth middleware: `authentik-forward-auth` in Traefik namespace
- Outpost endpoint: `http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik`
- Services opt in via `protected = true` in `ingress_factory`
- Response headers: `X-authentik-username`, `X-authentik-uid`, `X-authentik-email`, `X-authentik-name`, `X-authentik-groups`, `Set-Cookie`

#### OIDC for Kubernetes API
- Issuer: `https://authentik.viktorbarzin.me/application/o/kubernetes/`
- Client ID: `kubernetes`
- Username claim: `email`, Groups claim: `groups`
- Configured via SSH to kube-apiserver manifest (`modules/kubernetes/rbac/apiserver-oidc.tf`)

#### Common Management Tasks
**Add a new OAuth2 application:**
1. Create OAuth2 provider: `POST /api/v3/providers/oauth2/` with client_id, client_secret, redirect_uris, authorization_flow, etc.
2. Create application: `POST /api/v3/core/applications/` with name, slug, provider pk
3. (Optional) Bind to group policy for access control

**Add a user to a group:**
```bash
# Get group pk, then PATCH with updated users list
curl -X PATCH -H "Authorization: Bearer <TOKEN>" -H "Content-Type: application/json" \
  "https://authentik.viktorbarzin.me/api/v3/core/groups/<group-pk>/" \
  -d '{"users": [<existing_user_pks>, <new_user_pk>]}'
```

**Protect a service with forward auth:**
Set `protected = true` in the service's `ingress_factory` call in Terraform.

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

### Wyoming Whisper (STT for Home Assistant)
- **Image**: `rhasspy/wyoming-whisper:latest`
- **Port**: 10300/TCP (Wyoming protocol)
- **Model**: `small-int8` (CPU-optimized, no CUDA variant available from upstream)
- **Runs on**: GPU node (node_selector gpu=true + nvidia toleration) but uses CPU only
- **Storage**: NFS at `/mnt/main/whisper` → `/data` (model cache)
- **Exposure**: Internal only via Traefik TCP entrypoint `whisper-tcp` → IngressRouteTCP
- **Access**: `10.0.20.202:10300` (Traefik LB IP, no public DNS)
- **HA Integration**: Wyoming Protocol integration in ha-london, host `10.0.20.202`, port `10300`
- **No GPU acceleration**: Official image is CPU-only (Debian + PyTorch CPU). The `mib1185/wyoming-faster-whisper-cuda` image exists but requires self-build.

### Gramps Web (Genealogy)
- **Image**: `ghcr.io/gramps-project/grampsweb:latest`
- **Port**: 5000
- **URL**: `https://family.viktorbarzin.me`
- **Components**: Web app + Celery worker (2 containers in 1 pod)
- **Requires**: Shared Redis (DB 2 for Celery broker/backend, DB 3 for rate limiting)
- **Storage**: NFS at `/mnt/main/grampsweb` with sub_paths: users, indexdir, thumbnail_cache, cache, secret, grampsdb, media, tmp
- **Key env vars**:
  - `GRAMPSWEB_SECRET_KEY` - Flask secret key (generated via `random_password`)
  - `GRAMPSWEB_TREE` - Tree name
  - `GRAMPSWEB_BASE_URL` - Public URL
  - `GRAMPSWEB_CELERY_CONFIG__broker_url` / `result_backend` - Redis connection
  - `GRAMPSWEB_REGISTRATION_DISABLED` - Set to `True`
  - `GRAMPSWEB_EMAIL_*` - SMTP configuration
  - `GRAMPSWEB_LLM_*` - Ollama AI integration
- **Celery command**: `celery -A gramps_webapi.celery worker --loglevel=INFO --concurrency=2`
- **Registration**: Disabled; first user created via UI setup wizard

### Loki + Alloy (Centralized Log Collection)
- **Loki image**: `grafana/loki:3.6.5` (Helm chart, single binary mode)
- **Alloy image**: `grafana/alloy:v1.13.0` (Helm chart, DaemonSet)
- **Config files**: `modules/kubernetes/monitoring/loki.tf`, `loki.yaml`, `alloy.yaml`
- **Port**: 3100/TCP (Loki API)
- **Storage**: NFS PV at `/mnt/main/loki/loki` (15Gi), WAL on tmpfs (2Gi in-memory)
- **Memory**: Loki 6Gi limit, Alloy 128Mi per pod (4 worker nodes)
- **Disk-friendly tuning**: `max_chunk_age: 24h`, `chunk_idle_period: 12h` — holds chunks in memory, flushes ~once/day
- **Retention**: 7 days (`retention_period: 168h`), compactor enforces deletion
- **Crash policy**: WAL on tmpfs — up to 24h log loss on crash (alerts still fire in real-time)
- **Ruler**: Evaluates LogQL alert rules, fires to `http://prometheus-alertmanager.monitoring.svc.cluster.local:9093`
- **Alert rules**: HighErrorRate, PodCrashLoopBackOff, OOMKilled (ConfigMap `loki-alert-rules`)
- **Grafana**: Datasource UID `P8E80F9AEF21F6940`, dashboard "Loki Kubernetes Logs" (stored in MySQL, not file-provisioned)
- **Sysctl DaemonSet**: `sysctl-inotify` sets `fs.inotify.max_user_watches=1048576` on all nodes (required for Alloy fsnotify)
- **Disabled components**: gateway, chunksCache, resultsCache (not needed for single binary)
- **Key paths**: Compactor at `/var/loki/compactor`, ruler scratch at `/var/loki/scratch` (must be under `/var/loki` — root FS is read-only)
- **Querying**: Grafana Explore with LogQL, e.g. `{namespace="monitoring"} |= "error"`
- **Troubleshooting**: If "entry too far behind" errors on first start, restart Alloy DaemonSet (`kubectl rollout restart ds -n monitoring alloy`) — Alloy reads historical logs on first boot, which Loki rejects; clears after restart
