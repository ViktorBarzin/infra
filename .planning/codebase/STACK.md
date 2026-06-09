# Technology Stack

**Analysis Date:** 2026-02-23

## Languages

**Primary:**
- HCL (HashiCorp Configuration Language) - Terraform/Terragrunt infrastructure definitions
- Bash - Scripting and cluster management (`scripts/` directory)
- YAML - Kubernetes resource definitions and configuration
- Python - Monitoring and utility scripts in `stacks/platform/modules/`
- TypeScript/JavaScript - k8s-portal frontend and webhook-handler (`stacks/platform/modules/k8s-portal/`, `stacks/webhook_handler/`)

**Secondary:**
- Go - Various utilities
- Dockerfile - Container image definitions across stacks

## Runtime

**Environment:**
- Kubernetes v1.34.2 (5 nodes: k8s-master + k8s-node1-4)
- Linux (Ubuntu cloud images on Proxmox VMs)
- Bash shell for automation

**Package Manager:**
- npm (Node.js) - for k8s-portal web UI development
  - Lockfile: `package-lock.json` present
- pip (Python) - for utility scripts
- Terraform/Terragrunt - manages all infrastructure dependencies

## Frameworks

**Core:**
- Terraform 1.x - Infrastructure-as-Code orchestration
- Terragrunt - State isolation wrapper around Terraform (`terragrunt.hcl` in each stack)
- Kubernetes - Container orchestration (kubectl, Helm, kustomize patterns)

**Testing:**
- Playwright ^1.58.2 - E2E testing framework (root `package.json`)

**Build/Dev:**
- Helm 3.1.1 - Kubernetes package manager (provider version via Terraform)
- Svelte - Frontend framework for k8s-portal (`stacks/platform/modules/k8s-portal/files/` Node.js project)

## Key Dependencies

**Critical:**
- hashicorp/terraform (Kubernetes 3.0.1) - Kubernetes API provider
- hashicorp/helm (3.1.1) - Helm release management
- telmate/proxmox (3.0.2-rc07) - Proxmox VM management (`stacks/infra/`)
- cloudflare/cloudflare (4.52.5) - DNS and tunnel management (`stacks/platform/modules/cloudflared/`)
- hashicorp/null (3.2.4) - Utility provider for local operations
- hashicorp/random (3.8.1) - Random value generation

**Infrastructure:**
- MySQL 9.2.0 - Relational database (`stacks/platform/modules/dbaas/`)
- PostgreSQL 16.4-bullseye - Primary database with PostGIS/PGVector (`stacks/platform/modules/dbaas/`)
- Redis/redis-stack:latest - In-memory cache and broker (`stacks/platform/modules/redis/`)
- Headscale 0.23.0 - WireGuard control plane (`stacks/platform/modules/headscale/`)

**Observability:**
- Prometheus - Metrics collection and alerting
- Grafana - Metrics visualization and dashboards
- Loki 3.6.5 - Log aggregation (from user instructions)
- Alloy v1.13.0 - Log collector (from user instructions)

**API Gateway & Ingress:**
- Traefik 3.x - Ingress controller and reverse proxy (`stacks/platform/modules/traefik/`)
- MetalLB - Load balancer for Kubernetes service IPs (`stacks/platform/modules/metallb/`)

**Security:**
- Authentik - Identity Provider/OIDC (`stacks/platform/modules/authentik/`)
- Vaultwarden 1.35.2 - Password manager (`stacks/platform/modules/vaultwarden/`)
- CrowdSec - Intrusion detection and IP reputation (`stacks/platform/modules/crowdsec/`)
- Kyverno - Policy enforcement and governance (`stacks/platform/modules/kyverno/`)

**Container Images Registry:**
- docker.io - Docker Hub public images
- ghcr.io - GitHub Container Registry (Headscale UI, Immich, etc.)
- quay.io - Quay.io registry (inferred from mirror config)
- registry.k8s.io - Kubernetes images
- Local pull-through cache at `10.0.20.10` (ports 5000/5010/5020/5030/5040)

## Configuration

**Environment:**
- `terraform.tfvars` (git-crypt encrypted) - All secrets, API keys, DNS records, passwords
- Environment variables injected into Kubernetes pods via ConfigMap/Secret
- Kubeconfig: `config` file in repo root (referenced as `$PWD/config` in terragrunt)

**Build:**
- `terragrunt.hcl` (root) - DRY Terraform provider and backend configuration
- `stacks/<service>/terragrunt.hcl` - Per-stack overrides
- `stacks/<service>/main.tf` - Kubernetes/Proxmox resource definitions
- `.terraform.lock.hcl` - Provider version lock (Terraform 1.x)
- `.terraform/` - Downloaded providers cached locally

**Secrets:**
- `secrets/` directory (git-crypt encrypted)
- TLS certificates and keys in `secrets/` (symlinked from stacks)
- OpenDKIM keys for mailserver
- NFS export configuration in `secrets/nfs_directories.txt`

## Platform Requirements

**Development:**
- Terraform 1.x CLI
- Terragrunt CLI (uses `terragrunt apply --non-interactive`)
- kubectl configured with kubeconfig at `$PWD/config`
- git-crypt for secret decryption
- curl, bash, standard Unix utilities

**Production:**
- Kubernetes 1.34.2+ cluster (5 nodes, 192 GB+ total memory)
- Proxmox 8.x hypervisor (`stacks/infra/` provisions VMs)
- NFS storage: TrueNAS at `10.0.10.15` with exports at `/mnt/main/`
- Docker registry pull-through cache at `10.0.20.10`
- Cloudflare DNS (public domain `viktorbarzin.me`)
- Technitium DNS (internal domain `viktorbarzin.lan`)

**Networking:**
- Kubernetes pod CIDR: managed by cluster
- Service IPs: 10.0.20.200-10.0.20.220 (MetalLB layer 2)
- Internal DNS: Technitium at cluster IP
- External DNS: Cloudflare tunnel + traditional DNS records

---

*Stack analysis: 2026-02-23*
