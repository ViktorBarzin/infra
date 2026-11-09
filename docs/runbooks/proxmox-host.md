# Runbook: Proxmox host (pve, 192.168.1.127)

Last updated: 2026-10-21

The Proxmox host is a baremetal hypervisor on the storage LAN
(192.168.1.0/24) with a single IP `192.168.1.127`. It hosts every
Kubernetes node VM and the NFS exports that back PVCs. It does **not**
receive DHCP — its network config is static in
`/etc/network/interfaces` (ifupdown). Because of that, DNS must be
configured manually and stays out of the scope of Kea/DHCP-DDNS.

## DNS configuration

The host uses a plain `/etc/resolv.conf` with two nameservers. No
`systemd-resolved`, no `resolvconf`, no NetworkManager — nothing
manages `/etc/resolv.conf`; it is a regular file owned by root.

### Why plain `/etc/resolv.conf` and not systemd-resolved

1. Installing `systemd-resolved` on an active Proxmox node during
   business hours is the kind of change that risks breaking the NFS
   server or VM networking. PVE's Debian base does not ship
   `systemd-resolved` by default.
2. The ifupdown `/etc/network/interfaces` file does not manage
   `/etc/resolv.conf` here — ifupdown's resolvconf integration is
   only active if the `resolvconf` package is installed, which it is
   not (`dpkg -l resolvconf` returns `un`).
3. A plain file is the simplest mental model and avoids a second
   layer of "which tool is running now" confusion during an incident.

If you ever want to migrate to `systemd-resolved`, install the
package, enable the service, symlink `/etc/resolv.conf` to
`/run/systemd/resolve/stub-resolv.conf`, and drop the config in
`/etc/systemd/resolved.conf.d/10-internal-dns.conf` — but do this
during a maintenance window, not reactively.

### Current state

```
# /etc/resolv.conf
search viktorbarzin.lan
nameserver 192.168.1.2
nameserver 94.140.14.14
options timeout:2 attempts:2
```

| Field | Value | Purpose |
|---|---|---|
| Primary | `192.168.1.2` | pfSense LAN interface (dnsmasq forwarder → Technitium LB) — resolves `.viktorbarzin.lan` |
| Fallback | `94.140.14.14` | AdGuard public DNS — recursive only, used if pfSense LAN IP unreachable |
| `search` | `viktorbarzin.lan` | Unqualified names (`technitium`, `idrac`, etc.) resolve against the internal zone |
| `timeout:2 attempts:2` | — | Cap glibc resolver at 2s per server, 2 tries — reasonable fallback latency |

### Verification commands

```sh
ssh root@192.168.1.127 '
  cat /etc/resolv.conf                           # should show the two nameservers
  dig +short idrac.viktorbarzin.lan              # expect an A record (192.168.1.4)
  dig +short github.com                          # expect an A record
'
```

Simulated failover — force the primary unreachable and verify the
fallback answers:

```sh
ssh root@192.168.1.127 '
  ip route add blackhole 192.168.1.2
  dig +short +time=3 github.com      # glibc times out on primary, tries 94.140.14.14 → A record returned
  ip route del blackhole 192.168.1.2 # cleanup
'
```

Expected behaviour: the first `dig` prints a warning about the UDP
setup failing for 192.168.1.2 and then prints the GitHub A record
(answered by 94.140.14.14).

## Rollback

A pre-change backup of `/etc/resolv.conf`, `/etc/network/interfaces`,
and `/etc/network/interfaces.d/` lives at
`/root/dns-backups/dns-config-backup-YYYYMMDD-HHMMSS.tar.gz` on the
host. To roll back:

```sh
ssh root@192.168.1.127 '
  # pick the backup you want (there may be multiple if this runbook has been applied more than once)
  BACKUP=$(ls -t /root/dns-backups/dns-config-backup-*.tar.gz | head -1)
  tar -xzf "$BACKUP" -C /
  cat /etc/resolv.conf
'
```

No service restart is needed — glibc re-reads `/etc/resolv.conf` per
lookup.

## Host configuration managed by Ansible

`playbooks/pve-host.yml` declares the host state that is not VM
lifecycle. A `--check` run against the live host should be a no-op, so
run it first:

```sh
ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml --check --diff
ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml
```

| Declared | Why |
|---|---|
| Per-VM disk I/O caps (`apply-mbps-caps` script, service and timer) | Keeps one VM's reads out of the queue that etcd's fsyncs wait in on sdc |
| cgroup io delegation and no swap for k8s-master (`pve-cgroup-io` script, service and timer) | Per-VM io.stat for attribution, and `memory.swap.max=0` on `200.scope` so etcd's VM is never swapped onto sdc |
| `vm.swappiness=10` (`/etc/sysctl.d/90-swappiness.conf`) | The swap LV is on sdc. At 60 it filled, and swap-in reads showed up in daytime etcd stalls (2026-11-05) |
| journald in RAM (`Storage=volatile`) | The on-disk journal wrote about 4.5 GB/day to sdc |
| `xfs_scrub_all.timer` and `xfs_scrub_all.service` masked | The host has no XFS filesystems, and the scrub deadlocks here on its own `lsblk` output, which kept systemd reporting "starting" from 2026-07-18 to 2026-09-24 |
| Fan actuator (`scripts/fan-control.sh` and its unit) | Replaces the old scp deploy. The script passes the Home Assistant token through a file descriptor, so it no longer appears in the host's command audit |
| promtail config (`scripts/pve-promtail.yaml`) | Redacts secret-shaped values before the journal reaches Loki |
| LVM metadata archive kept 7 days (`/etc/lvm/lvmlocal.conf`) | The default 30 days held 9,810 files and 1.9 GB for the `pve` volume group |
| unattended-upgrades, Debian-Security origin only, no automatic reboot (tag `patching`) | Nothing installed updates on the host until 2026-10-19, when 29 security updates were waiting. Proxmox packages (kernel, QEMU, pve-manager) and Debian point releases are still upgraded by hand, because they need a reboot or a VM stop/start to take effect. Kernel autoremoval is off, after the first run removed the fallback kernel 6.14.11-3 |
| `host-patch-status` (script, service, hourly timer) and the node_exporter textfile collector (tag `patching`) | Reports how many Proxmox packages are waiting and since when, and whether the running kernel is older than the newest installed one. `ProxmoxHostUpdatesWaiting` and `ProxmoxHostRebootWaiting` fire after 30 days, `ProxmoxHostPatchStatusStale` when the script stops running |
| `csi-leak-reconcile` (script, service, 5-minute timer, tag `csi-leak`) | Clears Proxmox CSI disk slots a timed-out detach left poisoned (see `docs/runbooks/proxmox-csi-wedged-attach.md`). Acts only on a slot that has a throttle object, no config entry and no attached device on two runs in a row, under the same per-VM lock `qm set` takes. Exports `pve_csi_leaked_slots`, `pve_csi_leak_cleaned_total` and `pve_csi_leak_reconcile_errors` through the textfile collector |
| `disk-smart-status` (script, service, 5-minute timer, tag `smart`) | Reads SMART data and the Seagate FARM log from every physical drive behind the PERC and exports `smart_*` metrics through the textfile collector. The "R730 Drives" alert group reads them. See "Drive health" below |
| Monthly Proxmox upgrade (tag `pve-upgrade`, runs only when asked for) | `apt full-upgrade` with no reboot. See below |

The measurements and reasoning for each item sit next to its task in
the playbook.

## Drive health

The PERC H730 presents virtual disks (sda to sdd), so each physical
drive is read with `smartctl -d megaraid,<bay> /dev/bus/0`. The bay
number is the megaraid number:

| Bay | Drive | Virtual disk |
|---|---|---|
| 0, 1 | Seagate Exos X24 ST12000NM007H 12 TB SAS | sdc, RAID1 (VG `pve`, `/srv/nfs`) |
| 2, 3 | Seagate ST1200MM0099 1.2 TB 10K SAS | sda, RAID1 (VG `backup`) |
| 4 | Samsung 850 EVO 1 TB SATA SSD | sdb, single-drive RAID-0 (VG `ssd`) |
| 5 | empty | |
| 6, 7 | Seagate ST600MM0069 600 GB 10K SAS | sdd, RAID1 (VG `sas`) |

`disk-smart-status` exports, per drive, with labels `bay`, `model` and
`serial`: `smart_healthy`, `smart_read_ok`, `smart_temperature_celsius`,
`smart_temperature_trip_celsius`, `smart_power_on_hours`,
`smart_grown_defects`, `smart_pending_defects` (Exos only),
`smart_uncorrected_errors_total{op}`, `smart_corrected_errors_total{op}`,
`smart_processed_bytes_total{op}`, `smart_logical_written_bytes_total`,
`smart_logical_read_bytes_total`, `smart_ata_attribute_raw{attribute}`,
`smart_ata_attribute_normalized{attribute}` and load/unload cycle
counts. `smart_collector_last_run_timestamp_seconds` and
`smart_collector_drives` describe the run itself.

Two workload counters disagree, and the logical one is the one to use.
The SCSI error counter log's "Gigabytes processed"
(`smart_processed_bytes_total`) runs 2.4 to 2.7 times above the data
the host transferred on the Exos pair. The FARM log's logical sectors
(`smart_logical_*_bytes_total{source="farm"}`) match the host-side
counters, and the two RAID1 mirrors agree within 0.004%. On 2026-11-09
each Exos had 176 TB written and 82 TB read over 9,597 power-on hours,
about 236 TB a year against Seagate's 550 TB/year workload rating. Only
the Exos drives carry a FARM log; the SSD's figure comes from
`Total_LBAs_Written`, and the older SAS drives have only the processed
counter.

Alerts (group "R730 Drives", plus two in "Server Health"):

| Alert | Severity | Fires when |
|---|---|---|
| `DiskSmartHealthFailed` | critical | the drive's own SMART verdict is not OK for 10 minutes |
| `DiskUncorrectedErrors` | critical | an uncorrected read, write or verify error was logged in the last 24 hours |
| `DiskGrownDefectsIncreased` | critical | the grown defect list grew in the last 24 hours |
| `DiskSSDMediaErrors` | critical | an SSD reallocation, reserved-block, program/erase fail, uncorrectable or CRC counter rose in the last 24 hours |
| `DiskTemperatureCritical` | critical | a drive is at or above its own trip temperature (Exos 50 C, older SAS 60 C; the SSD reports none and uses 70 C) for 5 minutes |
| `DiskTemperatureHigh` | warning | within 5 C of that limit (SSD: 60 C) for 15 minutes |
| `DiskPendingDefects` | warning | sectors are waiting to be reassigned |
| `DiskSSDWearHigh` | warning | the SSD's `Wear_Leveling_Count` normalized value is below 20 |
| `DiskSmartUnreadable` | warning | smartctl cannot read a drive the controller still lists |
| `DiskSmartDriveMissing` | warning | fewer drives answer smartctl than the iDRAC reports |
| `DiskSmartCollectorStale` | warning | the collector has not run for 30 minutes |
| `iDRACStorageUnhealthy` | critical | the iDRAC storage roll-up is not OK: a degraded virtual disk, the PERC or its battery |
| `iDRACBatteryUnhealthy` | critical | the iDRAC battery roll-up (PERC and CMOS) is not OK |

No SMART self-tests are scheduled. The drives run their own background
media scans, the PERC runs patrol reads, and a long test on an Exos
would read 12 TB from sdc, which is already 67-71% busy at p95. To read
one drive by hand:

```sh
ssh root@192.168.1.127 smartctl -a -d megaraid,0 /dev/bus/0          # health, errors, defects
ssh root@192.168.1.127 smartctl -l farm -d megaraid,0 /dev/bus/0     # Seagate FARM (Exos only)
```

## Monthly Proxmox updates

Debian security updates install themselves every day. Proxmox packages
(pve-manager, QEMU, kernels, firmware) need `apt full-upgrade`, so they
are installed in a supervised run about once a month (Viktor, 2026-10-21).
`ProxmoxHostUpdatesWaiting` is the reminder: it fires when the host has
not been fully up to date for 30 days.

```sh
ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml --tags pve-upgrade
```

The task upgrades everything and does not reboot. Running VMs keep the
QEMU binary they started with until they are stopped and started; the
`pveproxy`, `pvedaemon` and `pvestatd` services restart on their own, so
the web UI and API drop for a few seconds. Afterwards check
`pveversion`, `qm list` (every VM still `running`) and
`host_apt_upgrades_pending{job="proxmox-host"}` back at 0.

A new kernel takes effect only at a reboot, which stops every VM, so it
is scheduled with Viktor. `ProxmoxHostRebootWaiting` fires when a newer
kernel has been installed for 30 days. `host_reboot_required` carries the
`running` and `newest` kernel versions as labels. The host boots the
newest installed kernel because none is pinned (`proxmox-boot-tool
kernel list`); kernel autoremoval is off, so the previous kernels stay
in the boot menu as a fallback.

## Related docs

- `docs/architecture/dns.md` — where each resolver IP lives and which
  subnet it serves.
- `docs/runbooks/nfs-prerequisites.md` — other operations on this
  host; read before adding new NFS exports.
