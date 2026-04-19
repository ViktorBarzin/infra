# pfSense Unbound DNS Resolver

Last updated: 2026-04-19

## Overview

pfSense runs **Unbound** (DNS Resolver) as its sole DNS service, replacing
dnsmasq (DNS Forwarder) as of 2026-04-19 (DNS hardening Workstream D,
bd `code-k0d`).

Unbound AXFR-slaves the `viktorbarzin.lan` zone from the Technitium primary
via the `10.0.20.201` LoadBalancer, so LAN-side `.lan` resolution survives
a full Kubernetes outage. Public queries go to Cloudflare via DNS-over-TLS
(`1.1.1.1` + `1.0.0.1` on port 853, SNI `cloudflare-dns.com`).

## Listeners

Unbound binds on:

| Interface | IP | Purpose |
|-----------|-----|---------|
| WAN       | `192.168.1.2:53` | LAN (192.168.1.0/24) clients querying via pfSense WAN |
| LAN       | `10.0.10.1:53`   | Management VLAN clients |
| OPT1      | `10.0.20.1:53`   | K8s VLAN clients (CoreDNS upstream) |
| lo0       | `127.0.0.1:53`   | pfSense itself |

The prior WAN NAT `rdr` rule (`192.168.1.2:53 → 10.0.20.201`) was removed in
the same change — Unbound now answers directly on WAN.

## Config Summary

Relevant `<unbound>` keys in `/cf/conf/config.xml`:

| Key | Value | Meaning |
|-----|-------|---------|
| `enable` | flag | Enable Unbound |
| `dnssec` | flag | DNSSEC validation on |
| `forwarding` | flag | Forwarding mode (send recursive queries to upstream) |
| `forward_tls_upstream` | flag | Use DoT for upstream forwarders |
| `prefetch` | flag | Prefetch records near expiry |
| `prefetchkey` | flag | Prefetch DNSKEY records |
| `dnsrecordcache` | flag | `serve-expired: yes` |
| `active_interface` | `lan,opt1,wan,lo0` | Listen interfaces |
| `msgcachesize` | `256` (MB) | Message cache (rrset-cache auto-doubles to 512MB) |
| `cache_max_ttl` | `604800` | 7 days |
| `cache_min_ttl` | `60` | 60 seconds |
| `custom_options` | base64 | Contains `serve-expired-ttl: 259200` + `auth-zone:` block |

Upstream DoT forwarders live in `<system>`:

- `dnsserver[0] = 1.1.1.1`
- `dnsserver[1] = 1.0.0.1`
- `dns1host = cloudflare-dns.com`
- `dns2host = cloudflare-dns.com`

## Auth-Zone for viktorbarzin.lan

The custom_options block declares:

```
server:
  serve-expired-ttl: 259200

auth-zone:
  name: "viktorbarzin.lan"
  master: 10.0.20.201
  fallback-enabled: yes
  for-downstream: yes
  for-upstream: yes
  zonefile: "viktorbarzin.lan.zone"
  allow-notify: 10.0.20.201
```

- `master: 10.0.20.201` — AXFR source (Technitium LoadBalancer)
- `fallback-enabled: yes` — if the zone can't refresh from master, fall back to normal recursion for this name (prevents hard-fail if AXFR breaks)
- `for-downstream: yes` — answer queries for this zone with AA flag
- `for-upstream: yes` — Unbound's internal iterator also uses this zone
- `zonefile` is relative to the chroot (`/var/unbound/viktorbarzin.lan.zone`)
- `allow-notify: 10.0.20.201` — accept NOTIFY from Technitium

## Technitium-side ACL

Zone `viktorbarzin.lan` on Technitium has `zoneTransfer = UseSpecifiedNetworkACL`
with ACL entries:

- `10.0.20.1` (pfSense OPT1)
- `10.0.10.1` (pfSense LAN)
- `192.168.1.2` (pfSense WAN)

Verify via the Technitium API:

```
curl -sk "http://127.0.0.1:5380/api/zones/options/get?token=$TOK&zone=viktorbarzin.lan" | jq .response.zoneTransfer
```

## Operational Checks

```bash
# Is Unbound listening?
ssh admin@10.0.20.1 "sockstat -l -4 -p 53"

# Auth-zone loaded?
ssh admin@10.0.20.1 "unbound-control -c /var/unbound/unbound.conf list_auth_zones"
# Expected: viktorbarzin.lan.      serial NNNNN

# LAN record via auth-zone? (aa flag = authoritative / from auth-zone)
dig @192.168.1.2 idrac.viktorbarzin.lan +norec

# Public record via DoT? (ad flag = DNSSEC validated, via 1.1.1.1/1.0.0.1)
dig @192.168.1.2 example.com +dnssec

# Zonefile has all records?
ssh admin@10.0.20.1 "wc -l /var/unbound/viktorbarzin.lan.zone"
```

## K8s Outage Drill

Tests that `.lan` resolution survives a full Technitium outage:

```bash
# Scale Technitium primary to 0
kubectl -n technitium scale deploy/technitium --replicas=0

# Wait ~5 seconds, then test from a LAN client
ssh devvm.viktorbarzin.lan "dig @192.168.1.2 idrac.viktorbarzin.lan +short"
# Expected: 192.168.1.4 (served from Unbound's cached auth-zone)

# Restore immediately
kubectl -n technitium scale deploy/technitium --replicas=1
```

Completed successfully on 2026-04-19 initial deployment.

Note: secondary/tertiary Technitium pods remain up and continue to serve
queries via the `10.0.20.201` LoadBalancer even when the primary is down —
so the strongest proof that Unbound's auth-zone serves locally is to also
scale those down (optional, not part of the routine drill).

## Backup & Rollback

### Backups

- **On-box**: `/cf/conf/config.xml.2026-04-19-pre-unbound` (created before this
  workstream ran — keep for 30 days, then delete)
- **Daily**: PVE `daily-backup` script copies `/cf/conf/config.xml` and a full
  pfSense config tar to `/mnt/backup/pfsense/` on the Proxmox host at 05:00
- **Offsite**: Synology `pve-backup/pfsense/` (synced daily by
  `offsite-sync-backup`)

### Rollback to dnsmasq

If Unbound misbehaves, revert to dnsmasq + NAT rdr:

```bash
# On pfSense
cp /cf/conf/config.xml.2026-04-19-pre-unbound /cf/conf/config.xml

# Tell pfSense to re-read config and reload services
php -r 'require_once("config.inc"); require_once("config.lib.inc"); disable_path_cache();'
/etc/rc.restart_webgui            # reloads PHP config caches
# Restart services
php -r 'require_once("config.inc"); require_once("services.inc"); services_dnsmasq_configure(); services_unbound_configure(); filter_configure();'
/etc/rc.filter_configure          # re-applies NAT rules (brings back rdr)
```

Verify:

```bash
sockstat -l -4 -p 53 | grep dnsmasq   # expect dnsmasq on 10.0.10.1 and 10.0.20.1
pfctl -sn | grep '53'                 # expect rdr on wan UDP 53 → 10.0.20.201
```

### Rollback without wiping new changes

If you only want to stop Unbound without restoring the whole config, edit
config.xml and remove `<enable/>` from `<unbound>` + add it back to `<dnsmasq>`,
then re-run `services_unbound_configure()` + `services_dnsmasq_configure()`.
You also need to re-add the WAN NAT rdr in `<nat><rule>` (see the backup XML
for the exact shape — tracker `1775670025`).

## Known Gotchas

1. **pfSense regenerates `/var/unbound/unbound.conf`** on every service reload
   from `<unbound>` in `config.xml`. Edits to unbound.conf are NOT durable.
2. **`unbound-control` default config path is wrong**. Always use
   `unbound-control -c /var/unbound/unbound.conf <cmd>`.
3. **`custom_options` is base64-encoded** in config.xml. Use `base64 -d` to
   decode in a shell, or `base64_decode()` in PHP.
4. **`interface-automatic: yes` is NOT used** when `active_interface` is
   explicitly set to a list — pfSense emits explicit `interface: <ip>` lines.
5. **`auth-zone`'s `zonefile` path is relative to the Unbound chroot**
   (`/var/unbound`), NOT absolute. Using an absolute path silently fails.
6. **DoT forwarders need `forward_tls_upstream`** flag AND `dns1host` /
   `dns2host` set in `<system>` for SNI — without the hostname, pfSense emits
   `forward-addr: 1.1.1.1@853` (no `#`) which Cloudflare rejects with
   certificate hostname mismatch.

## Related Docs

- `docs/architecture/dns.md` — overall DNS architecture (K8s side, Technitium, CoreDNS)
- `docs/architecture/networking.md` — VLAN layout, pfSense interface mapping
- `.claude/skills/pfsense/skill.md` — SSH / CLI patterns for pfSense management
