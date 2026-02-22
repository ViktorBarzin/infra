# Proxmox Inventory & Infrastructure

> Static reference for VMs, hardware, and network topology.

## Proxmox Host Hardware
- **CPU**: Intel Xeon E5-2699 v4 @ 2.20GHz (22 cores / 44 threads, single socket)
- **RAM**: 142 GB (Dell R730 server)
- **GPU**: NVIDIA Tesla T4 (PCIe passthrough to k8s-node1)
- **Disks**: 1.1TB + 931GB + 10.7TB (local storage)
- **Proxmox access**: `ssh root@192.168.1.127`

## Network Topology
```
10.0.10.0/24 - Management: Wizard (10.0.10.10), TrueNAS NFS (10.0.10.15)
10.0.20.0/24 - Kubernetes: pfSense GW (10.0.20.1), Registry (10.0.20.10),
               k8s-master (10.0.20.100), DNS (10.0.20.101), MetalLB (10.0.20.102-200)
192.168.1.0/24 - Physical: Proxmox (192.168.1.127)
```

## Network Bridges
- **vmbr0**: Physical bridge on `eno1`, IP `192.168.1.127/24` — physical/home network
- **vmbr1**: Internal-only bridge, VLAN-aware — VLAN 10 (management) and VLAN 20 (kubernetes)

## VM Inventory

| VMID | Name | Status | CPUs | RAM | Network | Disk | Notes |
|------|------|--------|------|-----|---------|------|-------|
| 101 | pfsense | running | 8 | 16GB | vmbr0, vmbr1:vlan10, vmbr1:vlan20 | 32G | Gateway/firewall |
| 102 | devvm | running | 16 | 8GB | vmbr1:vlan10 | 100G | Development VM |
| 103 | home-assistant | running | 8 | 16GB | vmbr0 | 32G | HA, net0(vlan10) disabled |
| 105 | pbs | stopped | 16 | 8GB | vmbr1:vlan10 | 32G | Proxmox Backup (unused) |
| 200 | k8s-master | running | 8 | 16GB | vmbr1:vlan20 | 64G | Control plane (10.0.20.100) |
| 201 | k8s-node1 | running | 16 | 24GB | vmbr1:vlan20 | 128G | GPU node, Tesla T4 |
| 202 | k8s-node2 | running | 8 | 16GB | vmbr1:vlan20 | 64G | Worker |
| 203 | k8s-node3 | running | 8 | 16GB | vmbr1:vlan20 | 64G | Worker |
| 204 | k8s-node4 | running | 8 | 16GB | vmbr1:vlan20 | 64G | Worker |
| 220 | docker-registry | running | 4 | 4GB | vmbr1:vlan20 | 64G | MAC DE:AD:BE:EF:22:22 (10.0.20.10) |
| 300 | Windows10 | running | 16 | 8GB | vmbr0 | 100G | Windows VM |
| 9000 | truenas | running | 16 | 16GB | vmbr1:vlan10 | 32G+7x256G+1T | NFS (10.0.10.15) |

## VM Templates
| VMID | Name | Purpose |
|------|------|---------|
| 1000 | ubuntu-2404-cloudinit-non-k8s-template | Base for non-K8s VMs |
| 1001 | docker-registry-template | Docker registry VM |
| 2000 | ubuntu-2404-cloudinit-k8s-template | Base for K8s nodes |

## GPU Node (k8s-node1)
- **VMID**: 201, **PCIe**: `0000:06:00.0` (NVIDIA Tesla T4)
- **Taint**: `nvidia.com/gpu=true:NoSchedule`, **Label**: `gpu=true`
- GPU workloads need: `node_selector = { "gpu": "true" }` + nvidia toleration
- Taint applied via `null_resource.gpu_node_taint` in `modules/kubernetes/nvidia/main.tf`
