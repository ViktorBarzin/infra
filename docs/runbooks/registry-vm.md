# Runbook: Registry VM (docker-registry, 10.0.20.10)

Last updated: 2026-04-19

The registry VM hosts `registry.viktorbarzin.me` (private Docker
registry, htpasswd-auth, NGINX → registry:2). It is an Ubuntu 24.04
VM on the cluster LAN subnet `10.0.20.0/24`, with a static netplan
config (no DHCP). Because it sits on a subnet that only has pfSense
as its gateway, its DNS must be statically configured.

## DNS configuration

Ubuntu ships `systemd-resolved` and uses netplan to declare per-link
`nameservers`. Netplan writes systemd-networkd or NetworkManager
configs that resolved reads at runtime. There is **no automatic
merging** of netplan DNS with the `[Resolve]` section of
`/etc/systemd/resolved.conf` — per-link settings override the global
ones. So both layers must be in sync:

| Layer | File | Role |
|---|---|---|
| Netplan | `/etc/netplan/50-cloud-init.yaml` | Per-link DNS servers that resolved reports on `Link 2 (eth0)` |
| Resolved global | `/etc/systemd/resolved.conf.d/10-internal-dns.conf` | `Global` scope `DNS=` / `FallbackDNS=` — also shown in `resolvectl status` |

### Current state

`/etc/systemd/resolved.conf.d/10-internal-dns.conf`:

```ini
[Resolve]
DNS=10.0.20.1
FallbackDNS=94.140.14.14
Domains=viktorbarzin.lan
```

`/etc/netplan/50-cloud-init.yaml` (eth0 block, simplified):

```yaml
nameservers:
  addresses:
  - 10.0.20.1
  - 94.140.14.14
  search:
  - viktorbarzin.lan
```

`resolvectl status` output after the change:

```
Global
  resolv.conf mode: stub
  Current DNS Server: 10.0.20.1
  DNS Servers: 10.0.20.1
  Fallback DNS Servers: 94.140.14.14
  DNS Domain: viktorbarzin.lan

Link 2 (eth0)
  Current Scopes: DNS
  Current DNS Server: 10.0.20.1
  DNS Servers: 10.0.20.1 94.140.14.14
  DNS Domain: viktorbarzin.lan
```

| Field | Value | Purpose |
|---|---|---|
| Primary | `10.0.20.1` | pfSense OPT1 interface (dnsmasq forwarder → Technitium LB) — resolves `.viktorbarzin.lan` |
| Fallback | `94.140.14.14` | AdGuard public DNS — used if pfSense unreachable (e.g., OPT1 flap) |
| Search | `viktorbarzin.lan` | Unqualified names resolve against the internal zone |

### Why this matters for the registry

Container builds on this VM reference `.lan` hostnames (Technitium,
NFS, etc.) and external hostnames (Docker Hub, GHCR). Before the
hardening the netplan had `1.1.1.1` / `8.8.8.8` only, which meant:

1. Internal hostname lookups silently failed (slow timeout) — the
   VM could not resolve `idrac.viktorbarzin.lan` or any internal
   helper.
2. If Cloudflare's 1.1.1.1 had an outage, the VM would lose DNS
   entirely.

With the new config the VM can resolve both zones and keeps working
if the primary DNS server is unreachable.

## Apply / re-apply

```sh
ssh root@10.0.20.10 '
  netplan generate
  netplan apply
  systemctl restart systemd-resolved
  resolvectl status | head -20
'
```

`netplan apply` is not disruptive when only `nameservers` change — it
does not bounce the link.

## Verification

```sh
ssh root@10.0.20.10 '
  dig +short idrac.viktorbarzin.lan       # 192.168.1.4
  dig +short github.com                   # GitHub A record
  dig +short registry.viktorbarzin.me     # 10.0.20.10 + external A
'
```

Fallback test — blackhole the primary and confirm external lookups
still succeed through 94.140.14.14:

```sh
ssh root@10.0.20.10 '
  ip route add blackhole 10.0.20.1
  dig +short +time=5 +tries=2 github.com   # should still answer
  ip route del blackhole 10.0.20.1
'
```

Internal lookups do fail during the blackhole (the fallback is a
public resolver and does not know about the internal zone), which is
expected — the fallback buys availability for external pulls, not
internal hostnames.

## Rollback

A pre-change backup of `/etc/resolv.conf`, `/etc/systemd/resolved.conf`,
and `/etc/netplan/` lives at
`/root/dns-backups/dns-config-backup-YYYYMMDD-HHMMSS.tar.gz` on the
VM. To roll back:

```sh
ssh root@10.0.20.10 '
  BACKUP=$(ls -t /root/dns-backups/dns-config-backup-*.tar.gz | head -1)
  tar -xzf "$BACKUP" -C /
  rm -f /etc/systemd/resolved.conf.d/10-internal-dns.conf
  netplan apply
  systemctl restart systemd-resolved
  resolvectl status | head -10
'
```

## Related docs

- `docs/architecture/dns.md` — resolver IP assignments per subnet.
- `.claude/CLAUDE.md` (at repo root) — notes on the private registry
  and `containerd` `hosts.toml` redirects.
