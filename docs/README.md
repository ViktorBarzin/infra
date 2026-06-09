# Infrastructure Documentation

This repository contains the configuration and documentation for a homelab Kubernetes cluster running on Proxmox. The infrastructure hosts 70+ services managed declaratively with Terraform and Terragrunt.

## Quick Reference

### Network Ranges
- **Physical Network**: `192.168.1.0/24` - Physical devices and host network
- **Management VLAN 10**: `10.0.10.0/24` - Infrastructure VMs and management
- **Kubernetes VLAN 20**: `10.0.20.0/24` - Kubernetes cluster network

### Key URLs
- **Public**: `viktorbarzin.me`
- **Internal**: `viktorbarzin.lan`

## Architecture Documentation

| Document | Description |
|----------|-------------|
| [Overview](architecture/overview.md) | Infrastructure overview, hardware specs, VM inventory, and service catalog |
| [Networking](architecture/networking.md) | Network topology, VLANs, routing, and firewall rules |
| [VPN](architecture/vpn.md) | Headscale mesh VPN and Cloudflare Tunnel configuration |
| [Storage](architecture/storage.md) | Proxmox host NFS, Proxmox CSI (LVM-thin + LUKS2), and persistent volume management |
| [Authentication](architecture/authentication.md) | Authentik SSO, OIDC flows, and service integration |
| [Security](architecture/security.md) | CrowdSec IPS, Kyverno policies, and security controls |
| [Monitoring](architecture/monitoring.md) | Prometheus, Grafana, Loki, and observability stack |
| [Secrets Management](architecture/secrets.md) | HashiCorp Vault integration and secret rotation |
| [CI/CD](architecture/ci-cd.md) | Woodpecker CI pipeline and deployment automation |
| [Backup & DR](architecture/backup-dr.md) | Backup strategy, disaster recovery, and restore procedures |
| [Compute](architecture/compute.md) | Proxmox VMs, GPU passthrough, K8s resource management, and VPA |
| [Databases](architecture/databases.md) | PostgreSQL, MySQL, Redis, and database operators |
| [Multi-tenancy](architecture/multi-tenancy.md) | Namespace isolation, tier system, and resource quotas |

## Operations

- [Runbooks](../runbooks/) - Step-by-step operational procedures
- [Plans](../plans/) - Infrastructure change plans and rollout strategies

## Getting Started

1. Review the [Overview](architecture/overview.md) for a high-level understanding
2. Read the [Networking](architecture/networking.md) doc to understand connectivity
3. Check [Compute](architecture/compute.md) for resource management patterns
4. Explore individual architecture docs based on your area of interest
