# RAM Upgrade — Dell R730 Proxmox Host (Completed 2026-04-01)

**Host**: Dell R730 @ 192.168.1.127 (Proxmox)
**CPU**: Single Xeon E5-2699 v4 (CPU2 unpopulated — B-side slots unavailable)
**Before**: 144 GB (4x32G Samsung BB1 + 2x8G SK Hynix) @ 2400 MHz
**After**: 272 GB (4x32G Samsung BB1 + 4x32G Samsung CB1 + 2x8G SK Hynix) @ 2400 MHz

## Lessons Learned

1. **3 DPC downclock**: Adding DIMMs to the 3rd slot per channel (A11/A12) caused automatic downclocking to 1866 MHz. Dell R730 BIOS allows manual override back to 2400 MHz via **System BIOS > Memory Settings > Memory Frequency > Max Performance**.
2. **MySQL InnoDB Cluster CR recreation**: Deleting and recreating the InnoDBCluster CR generates new admin secrets that don't match the existing data on PVCs. Fix: manually create the new admin user in MySQL and configure GR recovery channel credentials.
3. **CNPG primary label**: After restarting the CNPG operator, it may not immediately label the primary pod with `role=primary`. Deleting the pod forces the operator to recreate it with the correct labels.
4. **LimitRange blocks MySQL**: The `dbaas` namespace LimitRange (4Gi max) blocks MySQL pods that need 5Gi. Kyverno policy resets LimitRange patches. Fix: reduce MySQL memory limit in CR to 4Gi.

## Physical DIMM Slot Map (looking down at motherboard, front of server at bottom)

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                          CPU1 DIMM SLOTS                                    ║
║                                                                              ║
║  ┌─── WHITE (1st per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A1  │ │  A2  │ │  A3  │ │  A4  │                                    ║
║  │  │ 32G  │ │ 32G  │ │ 32G  │ │ 32G  │  ◄── KEEP (existing Samsung 32G)  ║
║  │  │██████│ │██████│ │██████│ │██████│                                    ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  ┌─── BLACK (2nd per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A5  │ │  A6  │ │  A7  │ │  A8  │                                    ║
║  │  │ 32G  │ │ 32G  │ │ 32G  │ │ 32G  │  ◄── INSTALL NEW 32G Samsung     ║
║  │  │▓▓▓▓▓▓│ │▓▓▓▓▓▓│ │▓▓▓▓▓▓│ │▓▓▓▓▓▓│      (remove old 8G from A5/A6)  ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  ┌─── GREEN (3rd per channel) ───┐                                          ║
║  │                                │                                          ║
║  │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐                                    ║
║  │  │  A9  │ │  A10 │ │  A11 │ │  A12 │                                    ║
║  │  │      │ │      │ │  8G  │ │  8G  │  ◄── MOVE old 8G Hynix here       ║
║  │  │ empty│ │ empty│ │░░░░░░│ │░░░░░░│      (from A5 → A11, A6 → A12)    ║
║  │  └──────┘ └──────┘ └──────┘ └──────┘                                    ║
║  │   Ch 0     Ch 1     Ch 2     Ch 3                                        ║
║  └────────────────────────────────┘                                          ║
║                                                                              ║
║  Legend:  ██ = existing 32G (keep in place)                                  ║
║           ▓▓ = NEW 32G Samsung M393A4K40BB1-CRC (install)                    ║
║           ░░ = relocated 8G SK Hynix HMA81GR7AFR8N-UH (moved from A5/A6)   ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## Channel Summary After Install

```
Channel 0:  A1 [32G] ──── A5 [32G]  ──── A9 [    ]     = 64 GB  ✓ matched
Channel 1:  A2 [32G] ──── A6 [32G]  ──── A10[    ]     = 64 GB  ✓ matched
Channel 2:  A3 [32G] ──── A7 [32G]  ──── A11[ 8G ]     = 72 GB  ~ +8G bonus
Channel 3:  A4 [32G] ──── A8 [32G]  ──── A12[ 8G ]     = 72 GB  ~ +8G bonus
            ─────────      ─────────      ──────────
             WHITE          BLACK          GREEN          TOTAL: 272 GB
            (keep)         (new 32G)      (moved 8G)
```

**Performance**: ~1-2% bandwidth penalty on Ch2/Ch3 due to mixed DIMM sizes. Ch0/Ch1 fully matched.

## Shutdown Sequence

### Phase 0: Gracefully Stop Stateful Services

Scale down databases, caches, and secrets engines before draining nodes to ensure clean shutdown with no data loss.

```bash
export KUBECONFIG=/path/to/config

# 1. Vault — seal all instances (flushes WAL, closes connections)
kubectl -n vault exec vault-0 -- vault operator step-down 2>/dev/null
kubectl -n vault exec vault-0 -- vault operator seal
kubectl -n vault exec vault-1 -- vault operator seal
kubectl -n vault exec vault-2 -- vault operator seal

# 2. MySQL InnoDB Cluster — set super_read_only, scale router to 0
kubectl -n dbaas scale deploy mysql-cluster-router --replicas=0
kubectl -n dbaas exec mysql-cluster-0 -- mysql -e "SET GLOBAL innodb_fast_shutdown=0; SET GLOBAL super_read_only=ON;"
kubectl -n dbaas exec mysql-cluster-1 -- mysql -e "SET GLOBAL innodb_fast_shutdown=0; SET GLOBAL super_read_only=ON;"
kubectl -n dbaas exec mysql-cluster-2 -- mysql -e "SET GLOBAL innodb_fast_shutdown=0; SET GLOBAL super_read_only=ON;"
# innodb_fast_shutdown=0 forces full purge + change buffer merge on stop

# 3. PostgreSQL CNPG — trigger checkpoint on primaries
kubectl -n dbaas exec pg-cluster-2 -- psql -U postgres -c "CHECKPOINT;"
kubectl -n dbaas exec pg-cluster-4 -- psql -U postgres -c "CHECKPOINT;"
kubectl -n immich exec deploy/immich-postgresql -- psql -U postgres -c "CHECKPOINT;"

# 4. Redis — trigger BGSAVE then scale down
kubectl -n redis exec redis-node-0 -- redis-cli BGSAVE
kubectl -n redis exec redis-node-1 -- redis-cli BGSAVE
sleep 5  # wait for RDB flush
kubectl -n redis scale deploy redis-haproxy --replicas=0

# 5. ClickHouse — flush
kubectl -n rybbit exec deploy/clickhouse -- clickhouse-client --query "SYSTEM FLUSH LOGS"

# 6. Scale down stateful workloads
kubectl -n dbaas scale sts mysql-cluster --replicas=0
kubectl -n redis scale sts redis-node --replicas=0
kubectl -n vault scale sts vault --replicas=0

# 7. Verify all stateful pods terminated
kubectl get pods -A | grep -iE 'mysql-cluster-[0-9]|pg-cluster|redis-node|vault-[0-9]|clickhouse'
```

### Phase 1: Drain K8s Nodes

```bash
# Drain workers (reverse order)
kubectl drain k8s-node4 --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl drain k8s-node3 --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl drain k8s-node2 --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
kubectl drain k8s-node1 --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

# Cordon master
kubectl cordon k8s-master
```

### Phase 2: Shutdown VMs (via Proxmox)

```bash
ssh root@192.168.1.127

# K8s workers
for VMID in 201 202 203 204; do qm shutdown $VMID && echo "Shutdown VMID $VMID"; done
sleep 30

# K8s master
qm shutdown 200; sleep 15

# Docker registry
qm shutdown 220; sleep 10

# Secondary VMs
for VMID in 102 300 103; do qm shutdown $VMID; done
sleep 20

# TrueNAS (decommissioned 2026-04-13 — VM 9000 should already be stopped; skip if absent)
qm shutdown 9000 2>/dev/null || true

# pfSense (last — network gateway)
qm shutdown 101; sleep 15

# Verify all VMs stopped
qm list
```

### Phase 3: Shutdown Proxmox Host

```bash
shutdown -h now
```

## Physical RAM Installation

| Step | Action | Slot(s) | DIMM |
|------|--------|---------|------|
| 1 | Power off host | — | Completed via Phase 3 above |
| 2 | **Remove** | A5 (black clip) | Take out 8G Hynix, set aside |
| 3 | **Remove** | A6 (black clip) | Take out 8G Hynix, set aside |
| 4 | **Install NEW** | A5 (black clip) | Insert 32G Samsung |
| 5 | **Install NEW** | A6 (black clip) | Insert 32G Samsung |
| 6 | **Install NEW** | A7 (black clip) | Insert 32G Samsung |
| 7 | **Install NEW** | A8 (black clip) | Insert 32G Samsung |
| 8 | **Install MOVED** | A11 (green clip) | Insert 8G Hynix (was in A5) |
| 9 | **Install MOVED** | A12 (green clip) | Insert 8G Hynix (was in A6) |
| 10 | Power on | — | — |

## Post-Boot Verification

```bash
# Verify all 10 DIMMs detected
ssh root@192.168.1.127 'dmidecode -t memory | grep -E "Locator:|Size:" | grep -v Bank'

# Verify total RAM (~268 GiB usable)
ssh root@192.168.1.127 'free -h'
```
