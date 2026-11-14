# Enterprise SSDs for the R730: what to buy, what moves, what it buys

Status: brainstorm, no decision taken. Measured 2026-11-12 from Prometheus
(7-day window, 5-minute samples) and read-only checks on the Proxmox host and
iDRAC. Prices are asking prices from web listings, not quotes.

Builds on `docs/plans/2026-09-12-io-bottleneck-ssd-vs-spindles.md`,
`docs/plans/2026-09-15-remaining-read-iops.md` and the 2026-11-03 SAS pool
(`docs/architecture/storage.md`, "Second block pool").

## Summary

The host does not need more read IOPS: it averages about 170 reads/s and
5 MB/s across all disks. What an SSD tier changes is **per-read latency**, from
3 to 12 ms at the median and 13 to 54 ms at p95 today, to well under 1 ms.
That is a step change for anything that waits on a cold read: devvm sessions,
database queries that miss the buffer pool, pod starts, Grafana and Loki range
queries, and etcd waiting behind other tenants.

Recommended shape: **two used enterprise U.2 NVMe drives of about 4 TB, one per
free PCIe slot on simple x4 adapters, mirrored in software**, as a new VG and
thin pool beside `pve` and `sas`. Estimated $650 to $880 all-in. It uses no
drive bays, bypasses the PERC (whose single-SSD path measures 1.1 ms here), and
holds every hot workload including the k8s node root disks.

## What the disks do today

7 days to 2026-11-12, host `/proc/diskstats` via node-exporter.

| device | what | read IOPS avg / p95 | read ms p50 / p95 / p99 | util p95 |
|---|---|---|---|---|
| `sdc` | 2x 12 TB 7200 rpm RAID1, VG `pve` | 75 / 388 | 7.2 / 23.9 / 45.4 | 59% |
| `sdd` | 2x 600 GB 10k SAS RAID1, VG `sas` | 84 / 613 | 3.4 / 7.9 / 13.5 | 52% |
| `sda` | 2x 1.2 TB 10k SAS RAID1, `/mnt/backup` | 38 / 114 | 5.6 / 7.0 / 7.6 | 5% |
| `sdb` | 1x 850 EVO, single-drive RAID0 VD, VG `ssd` | 10 / 77 | 1.1 / 1.2 / 1.3 | 2% |

Host IO pressure averages 0.9%. devvm's own IO pressure averages 3.4% with a
p95 of 18.5%, so devvm is where people feel the disk.

The 850 EVO's 1.1 ms median is worth noting. A SATA SSD behind the H730 as a
RAID0 VD is roughly ten times slower per read than the same class of drive
attached directly, and TRIM does not reach it. That is the case for NVMe on
PCIe over SATA SSDs in the bays.

## Who reads, and how slowly

Top readers by 7-day average read IOPS, mapped through `dmsetup` and `kubectl get pv`.

| volume | pool | read IOPS avg / p95 | read ms p50 / p95 | used |
|---|---|---|---|---|
| `dbaas/pg-cluster-v18-2` | sas | 47.6 / 573 | 3.4 / 13.4 | 24 of 40 GB |
| `dbaas/pg-cluster-v18-1` | sas | 24.0 / 12.5 | 8.0 / 19.1 | 24 of 40 GB |
| devvm disk (VM 102) | pve | 19.3 / 119 | 11.8 / 35.5 | 185 of 228 GB |
| `/srv/nfs` media | pve | 15.9 / 1.1 | n/a / 43.8 | 3.3 of 4 TB |
| `dbaas/data-mysql-v26-0` | sas | 11.8 | n/a / 30.0 | 11 of 30 GB |
| k8s-node2 root | pve | 8.5 / 18 | 11.0 / 53.7 | 208 of 256 GB |
| host swap | pve | 6.8 / 24 | 11.1 / 30.3 | |
| Windows10 (VM 300) | pve | 5.9 / 20 | 5.4 / 26.6 | 99 of 100 GB |
| k8s-node3 root | pve | 5.6 / 22 | 5.5 / 51.7 | 206 of 256 GB |

Not in the top list but relevant: Prometheus (172 of 433 GB on `pve`), Loki
(49 of 50 GB on `pve`), k8s-master with etcd (64 GB on `pve`), the llama-cpp
models (30 GB on HDD NFS).

## What would move

| workload | size to plan for | why it benefits | verdict |
|---|---|---|---|
| Postgres v18, MySQL, Immich PG, Redis, claude-sessions | 155 GB allocated | every buffer-pool miss drops from 3-8 ms to sub-ms; nightly dumps finish faster | move |
| devvm disk | 228 GB | page-cache refaults become cheap; the IO stall users feel | move |
| k8s-master (etcd) | 64 GB | ends etcd queueing behind other tenants' reads, the root of past leader-election losses and the hotplug detach timeouts that poison LUN slots | move, needs your explicit OK (the 2026-10-19 decision kept it on `sdc`) |
| Prometheus, Loki | ~500 GB allocated | long-range Grafana queries and log searches read chunks cold | move |
| k8s node root disks | 1,280 GB allocated, ~875 GB used | image layers, container start, emptyDir | move if the drives are ~4 TB |
| 850 EVO contents (nfs-ssd, HA, caches) | ~300 GB | gains a mirror | optional; frees a bay and a single point of failure |
| llama-cpp models | 30 GB | cold model load | move, small |
| Immich library, anca-elements, media, Nextcloud data | 3+ TB | read once, sequentially; 0.05 re-reads/day measured in September | stay on `sdc` |
| Windows10, backups | | no one waits on them | stay |

Hot set without node roots is about 1.0 to 1.3 TB, which fits a 1.92 TB
mirror. With node roots it is about 2.5 TB, which needs ~4 TB drives. After the
move `sdc` holds only bulk media, Windows and the NFS share, and `sdd` becomes
spare.

## Options

| | A: 2x 1.92 TB SATA in bays | B: 2x ~4 TB U.2 NVMe on PCIe | C: no SSD, RAM for devvm |
|---|---|---|---|
| example parts | Samsung PM893, Intel D3-S4510 | Intel P4510 4 TB (Gen3), Samsung PM983/PM9A3 | 2x 32 GB DDR4 RDIMM into A9/A10 |
| asking price | $250-400 each, ~$500-800 | ~$300-400 each (estimate, see below) plus $20-40 per adapter, ~$650-880 | not priced |
| usable, mirrored | 1.92 TB | ~4 TB | n/a |
| read latency | likely ~1 ms behind the PERC, as `sdb` measures | ~0.1 ms class, not measured here | devvm only |
| mirror | PERC RAID1, BBU | mdadm or LVM raid1, drives carry their own PLP | |
| bays / slots used | bay 5 plus bay 4 (850 EVO retired), the last two bays | PCIe slots 6 and 7, no bays | 2 DIMM slots |
| holds node roots | no | yes | |
| risks | consumes every bay; no TRIM through the VD | software RAID needs its own alerting; Dell may ramp fans for third-party PCIe cards; no hot swap | fixes devvm refaults only; host page cache does not help VM disks (`cache=none`) |

**Price basis.** SATA figures are eBay asking prices for 1.92 TB PM893 and
S4510 units. For U.2, a buyback site lists the P4510 4 TB at $223-262 *paid to
sellers*, and used 3.84 TB PM9A3 units sold at $440-620; my $300-400 for a
P4510 assumes a buyer pays above payout, which is not measured. NAND prices rose
sharply through 2026, so all of these can move. A Gen4 drive buys nothing in
these Gen3 slots.

**Running cost.** Two U.2 drives add roughly 10 to 30 W, so about 90 to 260 kWh
a year, under EUR 35 at a typical Bulgarian tariff. Not measured on this PSU.

**Wear.** `sdc` absorbed ~420 GB/day of writes in September. If every byte
moved to the new pool that is ~155 TB a year, against ~6 PB rated endurance on
a 4 TB P4510. Wear is not a constraint; check the SMART percentage-used on
any used drive before accepting it.

## Recommendation

Option B. It costs roughly $80 to $150 more than A, gives twice the capacity, needs no
bays, reads directly over PCIe instead of through the PERC, and is the only
option that also takes the node root disks off `sdc`. Option C is the cheapest
lever for devvm alone and is not exclusive with B.

## Migration outline, if B goes ahead

Superseded in detail by `docs/research/2026-11-12-nvme-tier-vs-cache.md`, which compares tiering with a write-through cache and keeps the tier.

1. Fit the adapters and drives; confirm both enumerate in slots 6 and 7.
2. Mirror with LVM raid1 or mdadm, VG `nvme`, thin pool `nvme/data`, Proxmox storage `nvme-lvm`, via `playbooks/` or the host's existing config path.
3. StorageClasses `proxmox-lvm-nvme` and `proxmox-lvm-encrypted-nvme`, same as the SAS pair.
4. Add `nvme` to `LVM_SNAP_VGS` and `PVC_VGS`; extend `HDDReadLatencyHigh`-style alerts and add RAID-degraded alerting.
5. Databases by the 2026-11-03 copy-and-rebind pattern. VM disks (devvm, node roots, master if approved) by online `qm move-disk`.

## Open questions

- Riser 3 layout. iDRAC reports slots 6 and 7 present and empty, and Dell's manual lists 5, 6 and 7 as the single-CPU slots, but whether this chassis has the two-slot riser 3 was not confirmed physically.
- Whether the R730 ramps fans for these specific adapters, and whether the iDRAC third-party-card cooling override is needed.
- PSU rating and headroom were not read.
- Actual post-move latency is a vendor-class figure until a fio run on the new pool, with the same 4k QD1 and QD16 tests used on 2026-11-03.

## Sources

- Dell R730 single-CPU slots and BIOS bifurcation: [HighPoint R730 guide](https://download.highpoint-tech.com/www/HighPoint-Download/Document/Guide/SSD7000/User%20Guide/Using_HighPoint_NVMe_RAID_AICs_with_the_Dell_PowerEdge_R730_Server_v1.01_2023_10_26.pdf), [Dell community: 13G bifurcation](https://www.dell.com/community/PowerEdge-Hardware-General/13G-Poweredge-PCIE-Bifurcation/m-p/7311721), [Dell community: R730xd U.2 kit](https://www.dell.com:443/community/en/conversations/rack-servers/r730xd-u2-nvme-enablement-kit-installation/6627b2f9abffb86bf86f5ffb)
- Prices: [eBay PM893](https://www.ebay.com/shop/samsung-pm893?_nkw=samsung+pm893), [eBay enterprise SSD](https://www.ebay.com/shop/enterprise-ssd?_nkw=enterprise+ssd), [BuySellRam on 2026 used SSD prices](https://www.buysellram.com/blog/what-is-a-used-enterprise-ssd-worth-when-nand-prices-soar/), [Sell Used RAM payout table](https://www.sellusedram.com/sell/enterprise-ssd/)
