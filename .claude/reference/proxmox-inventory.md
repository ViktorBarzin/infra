# Proxmox Inventory & Infrastructure

> Static reference for VMs, hardware, and network topology.

## Proxmox Host Hardware
- **Model**: Dell R730
- **CPU**: Intel Xeon E5-2699 v4 @ 2.20GHz (22 cores / 44 threads, single socket, CPU2 unpopulated)
- **RAM**: 272 GB DDR4-2400 ECC RDIMM (10 DIMMs, see Memory Layout below)
- **GPU**: NVIDIA Tesla T4 (PCIe passthrough to k8s-node1)
- **iDRAC**: 192.168.1.4 (root/calvin)
- **Disks**: 1.1TB RAID1 SAS (backup) + 931GB Samsung SSD + 10.7TB RAID1 HDD
- **NFS server**: Proxmox host serves NFS directly. HDD NFS: `/srv/nfs` on ext4 LV `pve/nfs-data` (2TB). SSD NFS: `/srv/nfs-ssd` on ext4 LV `ssd/nfs-ssd-data` (100GB). Exports use `async` mode (safe with UPS + databases on block storage). TrueNAS (10.0.10.15) decommissioned.
- **Proxmox access**: `ssh root@192.168.1.127`

## Memory Layout (updated 2026-04-01)

### Physical DIMM Slot Map

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                          CPU1 DIMM SLOTS                                    ║
║                                                                              ║
║  ┌─── WHITE (1st per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A1  │ │  A2  │ │  A3  │ │  A4  │                                    ║
║  │  │ 32G  │ │ 32G  │ │ 32G  │ │ 32G  │  Samsung M393A4K40BB1-CRC (2R)    ║
║  │  │██████│ │██████│ │██████│ │██████│                                    ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  ┌─── BLACK (2nd per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A5  │ │  A6  │ │  A7  │ │  A8  │                                    ║
║  │  │ 32G  │ │ 32G  │ │ 32G  │ │ 32G  │  Samsung M393A4K40CB1-CRC (2R)    ║
║  │  │▓▓▓▓▓▓│ │▓▓▓▓▓▓│ │▓▓▓▓▓▓│ │▓▓▓▓▓▓│                                    ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  ┌─── GREEN (3rd per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A9  │ │  A10 │ │  A11 │ │  A12 │                                    ║
║  │  │      │ │      │ │  8G  │ │  8G  │  SK Hynix HMA81GR7AFR8N-UH (1R)   ║
║  │  │ empty│ │ empty│ │░░░░░░│ │░░░░░░│                                    ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  B1-B12: All empty (requires CPU2)                                           ║
║                                                                              ║
║  Legend:  ██ = Samsung BB1 32G    ▓▓ = Samsung CB1 32G    ░░ = Hynix 8G     ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

### Channel Summary

```
Channel 0:  A1 [32G] ──── A5 [32G]  ──── A9 [    ]     = 64 GB  ✓ matched
Channel 1:  A2 [32G] ──── A6 [32G]  ──── A10[    ]     = 64 GB  ✓ matched
Channel 2:  A3 [32G] ──── A7 [32G]  ──── A11[ 8G ]     = 72 GB  ~ +8G bonus
Channel 3:  A4 [32G] ──── A8 [32G]  ──── A12[ 8G ]     = 72 GB  ~ +8G bonus
            ─────────      ─────────      ──────────
             WHITE          BLACK          GREEN          TOTAL: 272 GB
```

### DIMM Details

- **A1-A4**: Samsung M393A4K40BB1-CRC 32GB DDR4-2400 ECC RDIMM (2-rank, original)
- **A5-A8**: Samsung M393A4K40CB1-CRC 32GB DDR4-2400 ECC RDIMM (2-rank, added 2026-04-01)
- **A11-A12**: SK Hynix HMA81GR7AFR8N-UH 8GB DDR4-2400 ECC RDIMM (1-rank, relocated from A5/A6)
- **A9-A10, B1-B12**: Empty (B-side requires CPU2)
- **Speed**: 2400 MHz (BIOS override — 3 DPC defaults to 1866 MHz, forced to 2400 via System BIOS > Memory Settings > Memory Frequency)

## Network Topology
```
10.0.10.0/24 - Management: Wizard (10.0.10.10)
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
| 101 | pfsense | running | 8 | 4GB | vmbr0, vmbr1:vlan10, vmbr1:vlan20 | 32G | Gateway/firewall |
| 102 | devvm | running | 16 | 8GB | vmbr1:vlan10 | 100G | Development VM |
| 103 | home-assistant | running | 8 | 8GB | vmbr0 | 64G | HA Sofia, net0(vlan10) disabled, SSH: vbarzin@192.168.1.8 |
| 105 | pbs | stopped | 16 | 8GB | vmbr1:vlan10 | 32G | Proxmox Backup (unused) |
| 200 | k8s-master | running | 8 | 16GB | vmbr1:vlan20 | 64G | Control plane (10.0.20.100) |
| 201 | k8s-node1 | running | 16 | 32GB | vmbr1:vlan20 | 256G | GPU node, Tesla T4 |
| 202 | k8s-node2 | running | 8 | 24GB | vmbr1:vlan20 | 256G | Worker |
| 203 | k8s-node3 | running | 8 | 24GB | vmbr1:vlan20 | 256G | Worker |
| 204 | k8s-node4 | running | 8 | 24GB | vmbr1:vlan20 | 256G | Worker |
| 220 | docker-registry | running | 4 | 4GB | vmbr1:vlan20 | 64G | MAC DE:AD:BE:EF:22:22 (10.0.20.10) |
| 300 | Windows10 | running | 16 | 8GB | vmbr0 | 100G | Windows VM |
| ~~9000~~ | ~~truenas~~ | **stopped/decommissioned** | — | — | — | — | NFS migrated to Proxmox host (192.168.1.127) at `/srv/nfs` and `/srv/nfs-ssd` |

**Total VM RAM allocated**: 180 GB of 272 GB (66%) — 92 GB free for future VMs

## VM Templates
| VMID | Name | Purpose |
|------|------|---------|
| 1000 | ubuntu-2404-cloudinit-non-k8s-template | Base for non-K8s VMs |
| 1001 | docker-registry-template | Docker registry VM |
| 2000 | ubuntu-2404-cloudinit-k8s-template | Base for K8s nodes |

## PVE Host Systemd Services (Custom)

| Unit | Type | Schedule | Purpose |
|------|------|----------|---------|
| `lvm-pvc-snapshot.timer` | Timer | Daily 03:00 | LVM thin snapshots of all PVCs (7-day retention) |
| `daily-backup.timer` | Timer | Daily 05:00 | PVC file backup, auto SQLite backup, pfSense, PVE config |
| `offsite-sync-backup.timer` | Timer | Daily 06:00 | Two-step rsync to Synology (sda + NFS via inotify) |
| `nfs-change-tracker.service` | Service | Continuous | inotifywait on `/srv/nfs` + `/srv/nfs-ssd`, logs to `/mnt/backup/.nfs-changes.log` |

## GPU Node (k8s-node1)
- **VMID**: 201, **PCIe**: `0000:06:00.0` (NVIDIA Tesla T4)
- **Taint**: `nvidia.com/gpu=true:NoSchedule`, **Label**: `gpu=true`
- GPU workloads need: `node_selector = { "gpu": "true" }` + nvidia toleration
- Taint applied via `null_resource.gpu_node_taint` in `modules/kubernetes/nvidia/main.tf`
