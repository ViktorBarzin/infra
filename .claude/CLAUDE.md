# Infrastructure Repository Knowledge

## Instructions for Claude
- **When the user says "remember" something**: Always update this file (`.claude/CLAUDE.md`) with the information so it persists across sessions
- **When discovering new patterns or versions**: Add them to the appropriate section below
- **Use `/update-knowledge` command**: Or edit this file directly to add learnings

## Execution Environment (CRITICAL)
- **File operations** (Read, Edit, Write, Glob, Grep): Run locally at `/Volumes/wizard/code/infra`
- **Git commands**: Run locally (git status, git log, git diff, etc.)
- **ALL other commands**: Use the remote executor relay (kubectl, terraform, helm, python, etc.)

### Remote Command Execution (ALWAYS USE THIS)
For any command that is not file editing or git, use the file-based relay:

**To execute a remote command:**
```bash
# 1. Write command
echo "your-command-here" > /Volumes/wizard/code/infra/.claude/cmd_input.txt
# 2. Wait and check status
sleep 1 && cat /Volumes/wizard/code/infra/.claude/cmd_status.txt
# 3. Read output (when status is "done:*")
cat /Volumes/wizard/code/infra/.claude/cmd_output.txt
```

**Status values:** `ready` | `running` | `done:N` (N = exit code)

**Requires user to start executor in another terminal:**
```bash
.claude/remote-executor.sh wizard@10.0.10.10 /home/wizard/code/infra
```

---

## Overview
Terraform-based infrastructure repository managing a home Kubernetes cluster on Proxmox VMs. Uses git-crypt for secrets encryption.

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
- Ingress uses nginx-ingress with annotations for customization
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

## Common Variables
- `tls_secret_name` - TLS certificate secret name
- `tier` - Deployment tier label
- Service-specific passwords passed as variables

## Service Versions (as of 2025-01)
- Immich: v2.4.1
- Freedify: latest (music streaming, factory pattern)

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

### Kubernetes Services (under module.kubernetes_cluster.module.*)
Core (tier 0-1):
- `metallb`, `dbaas`, `technitium`, `nginx-ingress`, `crowdsec`, `cloudflared`
- `redis`, `metrics-server`, `authentik`, `nvidia`, `vaultwarden`, `reverse-proxy`
- `wireguard`, `headscale`, `xray`, `monitoring`

GPU (tier 2):
- `immich`, `frigate`, `ollama`, `ebook2audiobook`

Edge/Aux (tier 3-4):
- `blog`, `drone`, `hackmd`, `mailserver`, `privatebin`, `shadowsocks`
- `city-guesser`, `echo`, `url`, `webhook_handler`, `excalidraw`, `travel_blog`
- `dashy`, `send`, `ytdlp`, `uptime-kuma`, `calibre`, `audiobookshelf`
- `paperless-ngx`, `jsoncrack`, `servarr`, `ntfy`, `cyberchef`, `diun`
- `meshcentral`, `nextcloud`, `homepage`, `matrix`, `linkwarden`, `actualbudget`
- `owntracks`, `dawarich`, `changedetection`, `tandoor`, `n8n`, `real-estate-crawler`
- `tor-proxy`, `onlyoffice`, `forgejo`, `freshrss`, `navidrome`, `networking-toolbox`
- `tuya-bridge`, `stirling-pdf`, `isponsorblocktv`, `rybbit`, `wealthfolio`
- `kyverno`, `speedtest`, `freedify`, `netbox`, `f1-stream`, `kms`, `k8s-dashboard`
- `descheduler`, `reloader`, `infra-maintenance`

## CI/CD
- Drone CI (`.drone.yml`) for automated deployments
- Auto-updates TLS certificates
- **ALWAYS add `[ci skip]` to commit messages** when you've already run `terraform apply` to avoid triggering CI redundantly
- **After committing, run `git push origin master`** to sync changes

## Infrastructure
- Proxmox hypervisor for VMs
- Kubernetes cluster with GPU node
- NFS server at 10.0.10.15 for storage
- Redis shared service at `redis.redis.svc.cluster.local`
