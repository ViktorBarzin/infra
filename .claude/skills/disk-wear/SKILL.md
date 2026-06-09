---
name: disk-wear
description: |
  Analyze disk write patterns on the PVE host to assess wear and identify
  top writers by VM, k8s app, and PVC. Use when:
  (1) User asks about disk wear, disk writes, or storage health,
  (2) User says "what's wearing the disk", "disk analysis", "I/O analysis",
  (3) User wants to check write rates by VM, k8s namespace, or PVC,
  (4) Periodic quarterly disk health review.
  Combines PVE host I/O stats (SSH), Prometheus metrics (PromQL), and
  k8s PVC-to-pod mapping for a full breakdown.
author: Claude Code
version: 1.0.0
date: 2026-04-17
---

# Disk Wear Analysis

## Infrastructure

| Resource | Address | Notes |
|----------|---------|-------|
| PVE host | `root@192.168.1.127` (SSH) | Dell R730, PERC H730 RAID |
| Prometheus | `prometheus-server.monitoring.svc:80` | Query via alertmanager pod (wget) |
| SSD | Slot 4, Samsung 850 EVO 1TB | Rated 150 TBW |
| HDD sdc | RAID1 (2x 11.7TB SAS 7200RPM) | Main data disk, enterprise rated ~550 TB/yr |
| HDD sda | 1.2TB SAS 10K RPM | Backup only |

## Step 1: Physical Disk Overview + SSD Health

```bash
ssh root@192.168.1.127 'echo "=== UPTIME ===" && uptime && echo "" && \
echo "=== PHYSICAL DISK CUMULATIVE (since boot) ===" && iostat -d -k sda sdb sdc 2>/dev/null && echo "" && \
echo "=== SSD SMART (Samsung 850 EVO, slot 4) ===" && \
smartctl -d sat+megaraid,4 -A /dev/sda 2>/dev/null | grep -iE "power_on|reallocat|written|wear|pending|uncorrect"'
```

**Interpret SSD health:**
- `Wear_Leveling_Count`: 100 = new, 0 = dead. Calculate `(100 - value)%` wear used.
- `Total_LBAs_Written`: multiply by 512 bytes for total TB written. Compare against 150 TBW rating.
- Estimate remaining life: `(150 TBW - current TBW) / annual write rate`.

## Step 2: Real-Time Snapshot (30 seconds)

SSH to PVE host and take two reads of block device stats 30 seconds apart. This gives instantaneous write rates independent of Prometheus scrape intervals.

```bash
ssh root@192.168.1.127 'bash -s' << 'SCRIPT'
echo "=== 30-SECOND SNAPSHOT ($(date)) ==="
declare -A snap1
for dm in /sys/block/dm-*; do
  name=$(basename $dm)
  snap1[$name]=$(cat $dm/stat 2>/dev/null | awk '{print $7}')
done
for d in sda sdb sdc; do
  snap1[$d]=$(cat /sys/block/$d/stat 2>/dev/null | awk '{print $7}')
done

sleep 30

printf "%-12s %10s %10s  %s\n" "DEVICE" "kB/s" "GB/day" "NAME"
echo "-------------------------------------------------------------------"
results=""
for dm in /sys/block/dm-*; do
  name=$(basename $dm)
  s2=$(cat $dm/stat 2>/dev/null | awk '{print $7}')
  s1=${snap1[$name]:-0}
  diff=$((s2 - s1))
  if [ "$diff" -gt 100 ]; then
    kbps=$((diff / 2 / 30))
    gbday=$(echo "scale=1; $kbps * 86400 / 1048576" | bc)
    lvm=$(dmsetup info --columns --noheadings -o name /dev/$name 2>/dev/null)
    results="$results\n$name $kbps $gbday $lvm"
  fi
done
for d in sda sdb sdc; do
  s2=$(cat /sys/block/$d/stat 2>/dev/null | awk '{print $7}')
  s1=${snap1[$d]:-0}
  diff=$((s2 - s1))
  kbps=$((diff / 2 / 30))
  gbday=$(echo "scale=1; $kbps * 86400 / 1048576" | bc)
  results="$results\n$d $kbps $gbday (physical)"
done
echo -e "$results" | sort -k2 -rn | head -30 | while read dev kbps gbday name; do
  printf "%-12s %8s kB/s %8s GB/day  %s\n" "$dev" "$kbps" "$gbday" "$name"
done
SCRIPT
```

## Step 3: Prometheus — Per-App Write Attribution

Query Prometheus from inside the cluster (alertmanager pod has wget).

### 3a. Top PVC Writers (1h rate)

```bash
kubectl exec -n monitoring prometheus-alertmanager-0 -- wget -qO- 'http://prometheus-server/api/v1/query' \
  --post-data='query=topk(20,rate(node_disk_written_bytes_total{instance=~"pve.*"}[1h])*on(device)group_left(lv_name,vg_name)node_disk_device_mapper_info{instance=~"pve.*",lv_name=~"vm-9999-pvc-.*"})' \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
    m = r['metric']
    val = float(r['value'][1])
    gb_day = val * 86400 / 1073741824
    if gb_day > 0.05:
        lv = m.get('lv_name','?').replace('vm-9999-','')
        print(f'{gb_day:8.1f} GB/day  {lv}')
"
```

Then enrich PVC UUIDs with names:
```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace | grep "pvc-<UUID>"
```

### 3b. Top VM Writers (1h rate)

```bash
kubectl exec -n monitoring prometheus-alertmanager-0 -- wget -qO- 'http://prometheus-server/api/v1/query' \
  --post-data='query=topk(10,rate(node_disk_written_bytes_total{instance=~"pve.*"}[1h])*on(device)group_left(lv_name,vg_name)node_disk_device_mapper_info{instance=~"pve.*",lv_name!~"vm-9999-.*|root|swap|data.*|nfs.*|backup.*|ssd.*"})' \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
    m = r['metric']
    val = float(r['value'][1])
    gb_day = val * 86400 / 1073741824
    print(f'{gb_day:8.1f} GB/day  {m.get(\"lv_name\",\"?\")}')
"
```

Enrich VM IDs with names:
```bash
ssh root@192.168.1.127 'qm list' 2>/dev/null
```

### 3c. Aggregate PVC Writes by K8s Namespace

After collecting the top PVC writers from 3a, map each PVC UUID to its namespace using `kubectl get pv`, then sum by namespace. Present as a table:

| Namespace | GB/day | Top PVC |
|-----------|--------|---------|
| dbaas | ... | mysql-standalone, pg-cluster |
| monitoring | ... | prometheus-data |

### 3d. Historical Trend (7-day total)

```bash
kubectl exec -n monitoring prometheus-alertmanager-0 -- wget -qO- 'http://prometheus-server/api/v1/query' \
  --post-data='query=topk(10,increase(node_disk_written_bytes_total{instance=~"pve.*",device=~"sda|sdb|sdc"}[7d]))' \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d['data']['result']:
    m = r['metric']
    val = float(r['value'][1])
    tb = val / 1099511627776
    print(f'{tb:8.2f} TB/7d  device={m.get(\"device\",\"?\")}')
"
```

## Step 4: Interpretation

### Baselines

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| sdc (HDD RAID1) annualized | <200 TB/yr | 200-400 TB/yr | >400 TB/yr |
| sdb (SSD) wear used | <50% | 50-80% | >80% |
| Single PVC write rate | <20 GB/day | 20-50 GB/day | >50 GB/day |
| Single VM write rate | <50 GB/day | 50-100 GB/day | >100 GB/day |
| NFS volume total | <20 GB/day | 20-50 GB/day | >50 GB/day |

### Known Write Sources (expected baseline, April 2026)

| Source | Expected GB/day | Notes |
|--------|----------------|-------|
| MySQL standalone | 5-10 | uptimekuma heartbeats + phpipam. `skip-log-bin`, no GR |
| PostgreSQL cluster | 5-15 | Technitium DNS query logs (90-day retention) + app DBs |
| k8s-master etcd | 30-50 | etcd WAL + snapshot compaction |
| k8s-node VMs | 10-30 each | containerd layers, kubelet journals, ephemeral storage |
| Prometheus | 3-5 | TSDB compaction |
| home-assistant | 10-15 | Recorder database (SQLite/MariaDB) |
| NFS volume | 5-10 | Minimal after TrueNAS deprecation |

### Red Flags (investigate immediately)

- Any single PVC >50 GB/day
- MySQL `log_bin` = ON (should be OFF — `skip-log-bin` in standalone config)
- Technitium MySQL or SQLite query log plugins re-installed (should be uninstalled)
- NFS writes >30 GB/day (media ingestion or backup churn)
- SSD wear >80% or projected life <2 years
- k8s node VM writes >100 GB/day (something writing heavily to ephemeral storage)

## Step 5: Report Format

Present findings as three tables:

**1. Physical Disks**
| Disk | Type | 7d Total | Rate GB/day | Annualized | Status |
|------|------|----------|-------------|------------|--------|

**2. Top Writers (VMs + PVCs combined, sorted by rate)**
| Rank | Name | Type | GB/day | Status | Notes |
|------|------|------|--------|--------|-------|

**3. By K8s Namespace**
| Namespace | PVC Writes GB/day | Top Contributor |
|-----------|-------------------|-----------------|

End with:
- Annualized wear projections
- Comparison with previous run (if user provides one)
- Action items for any WARNING/CRITICAL findings
