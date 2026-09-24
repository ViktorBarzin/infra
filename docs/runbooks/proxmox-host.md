# Runbook: Proxmox host (pve, 192.168.1.127)

Last updated: 2026-09-24

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
| journald in RAM (`Storage=volatile`) | The on-disk journal wrote about 4.5 GB/day to sdc |
| `xfs_scrub_all.timer` and `xfs_scrub_all.service` masked | The host has no XFS filesystems, and the scrub deadlocks here on its own `lsblk` output, which kept systemd reporting "starting" from 2026-07-18 to 2026-09-24 |
| Fan actuator (`scripts/fan-control.sh` and its unit) | Replaces the old scp deploy. The script passes the Home Assistant token through a file descriptor, so it no longer appears in the host's command audit |
| promtail config (`scripts/pve-promtail.yaml`) | Redacts secret-shaped values before the journal reaches Loki |
| LVM metadata archive kept 7 days (`/etc/lvm/lvmlocal.conf`) | The default 30 days held 9,810 files and 1.9 GB for the `pve` volume group |

The measurements and reasoning for each item sit next to its task in
the playbook.

## Related docs

- `docs/architecture/dns.md` — where each resolver IP lives and which
  subnet it serves.
- `docs/runbooks/nfs-prerequisites.md` — other operations on this
  host; read before adding new NFS exports.
