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
| 102 | devvm | running | 16 | 24GB | vmbr1:vlan10 | 100G | Development VM + t3code Workstation host. 14G swap (8G /swapfile + 6G /swapfile2, grown 2026-06-10; swappiness=10). Capacity budget: ~4-5G RAM/active user, max ~3-4 concurrent active Claude sessions. NOT Terraform-managed. Disk controller: `virtio-scsi-single` + `scsi0 iothread=1,aio=threads` staged 2026-06-11 after the QEMU I/O stall (was `scsihw: lsi`, the only VM on the legacy path — see `docs/post-mortems/2026-06-11-devvm-qemu-io-stall.md`); applies at next cold stop→start. |
| 103 | home-assistant | running | 8 | 8GB | vmbr0 | 64G | HA Sofia, net0(vlan10) disabled, SSH: vbarzin@192.168.1.8 |
| 105 | pbs | stopped | 16 | 8GB | vmbr1:vlan10 | 32G | Proxmox Backup (unused) |
| 200 | k8s-master | running | 8 | 32GB | vmbr1:vlan20 | 64G | Control plane (10.0.20.100) |
| 201 | k8s-node1 | running | 16 | 48GB | vmbr1:vlan20 | 256G | GPU node, Tesla T4 |
| 202 | k8s-node2 | running | 8 | 32GB | vmbr1:vlan20 | 256G | Worker |
| 203 | k8s-node3 | running | 8 | 32GB | vmbr1:vlan20 | 256G | Worker |
| 204 | k8s-node4 | running | 8 | 32GB | vmbr1:vlan20 | 256G | Worker |
| 205 | k8s-node5 | running | 8 | 32GB | vmbr1:vlan20 | 256G | Worker (10.0.20.105, joined 2026-05-26) |
| ~~206~~ | ~~k8s-node6~~ | **destroyed** | — | — | — | — | Decommissioned 2026-07-01, but VM 206 was left stopped with `onboot=1` and **zombie-rejoined** on the 2026-07-18 power-outage reboot (stale kubelet config, no providerID → proxmox-csi crashloop). Drained + Node object deleted + `qm destroy 206 --purge` 2026-07-18. See `docs/post-mortems/2026-07-18-sofia-power-outage-unclean-shutdown.md`. |
| 220 | docker-registry | running | 4 | 4GB | vmbr1:vlan20 | 64G | MAC DE:AD:BE:EF:22:22 (10.0.20.10) |
| 300 | Windows10 | running | 16 | 8GB | vmbr0 | 100G | Windows VM |
| ~~9000~~ | ~~truenas~~ | **stopped/decommissioned** | — | — | — | — | NFS migrated to Proxmox host (192.168.1.127) at `/srv/nfs` and `/srv/nfs-ssd` |

**Total VM RAM allocated**: ~256 GB nominal across running VMs vs 272 GB physical — within physical since node6's 2026-07-18 removal freed 32 GB (previously ~288 GB / overcommitted; ballooning still enabled on K8s workers, see memory id=535/2543). K8s rows live-verified via `kubectl get nodes` capacity 2026-06-11 (master 32G, node1 48G, node2-5 32G; the old 16/32/24GB figures predated the 2026-04-02 resize). Cluster is 6 nodes: k8s-master + k8s-node1-5.

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

## GPU Node (currently k8s-node1)
- **VMID**: 201, **PCIe**: `0000:06:00.0` (NVIDIA Tesla T4) — physical passthrough, no Terraform pin
- **Taint**: `nvidia.com/gpu=true:PreferNoSchedule` (applied dynamically to every NFD-discovered GPU node)
- **Label**: `nvidia.com/gpu.present=true` (auto-applied by gpu-feature-discovery; also `feature.node.kubernetes.io/pci-10de.present=true` from NFD)
- GPU workloads need: `node_selector = { "nvidia.com/gpu.present" : "true" }` + nvidia toleration
- Taint applied via `null_resource.gpu_node_config` in `stacks/nvidia/modules/nvidia/main.tf`; node discovery keyed on the NFD `pci-10de.present` label so the taint follows the card to whichever host is carrying it
