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

## Kea DHCP-DDNS TSIG (WS E, 2026-04-19)

Kea DHCP-DDNS on pfSense signs its RFC 2136 dynamic updates with an
HMAC-SHA256 TSIG key (`kea-ddns`). Technitium's `viktorbarzin.lan` zone
and reverse zones (`10.0.10.in-addr.arpa`, `20.0.10.in-addr.arpa`,
`1.168.192.in-addr.arpa`) require both a pfSense-source IP (10.0.20.1 /
10.0.10.1 / 192.168.1.2) AND a valid TSIG signature.

### Config locations

| Side | File | Notes |
|------|------|-------|
| pfSense | `/usr/local/etc/kea/kea-dhcp-ddns.conf` | Hand-managed. Pre-WS-E backup: `.2026-04-19-pre-tsig`. Daemon: `kea-dhcp-ddns` (`pkill -x kea-dhcp-ddns && /usr/local/sbin/kea-dhcp-ddns -c /usr/local/etc/kea/kea-dhcp-ddns.conf -d &`) |
| Technitium | Zone options API: `POST /api/zones/options/set?zone=<z>&updateSecurityPolicies=kea-ddns\|*.<z>\|ANY&updateNetworkACL=10.0.20.1,10.0.10.1,192.168.1.2&update=UseSpecifiedNetworkACL` | Set on primary; replicates to secondary/tertiary via AXFR |
| Technitium settings | TSIG keys array: `POST /api/settings/set` with `tsigKeys: [{keyName: "kea-ddns", sharedSecret: <b64>, algorithmName: "hmac-sha256"}]` | Must be set on all 3 Technitium instances (primary, secondary, tertiary) |
| Vault | `secret/viktor/kea_ddns_tsig_secret` | Authoritative copy of the base64 secret |

### Rotating the TSIG key

1. Generate a new base64 32-byte secret: `openssl rand -base64 32` (any base64-encoded blob of reasonable length works; HMAC-SHA256 truncates/pads internally).
2. Write it to Vault: `vault kv patch secret/viktor kea_ddns_tsig_secret=<new-secret>`.
3. Add the new key under a **new name** (e.g., `kea-ddns-v2`) via the Technitium settings API on all 3 instances. Do NOT overwrite `kea-ddns` while Kea still uses it — you'd orphan in-flight updates.
4. Update `/usr/local/etc/kea/kea-dhcp-ddns.conf` on pfSense to reference both keys in `tsig-keys`, set `key-name: kea-ddns-v2` on each `forward-ddns` / `reverse-ddns` domain, restart `kea-dhcp-ddns`.
5. Update each affected zone's `updateSecurityPolicies` to use the new key name.
6. After a lease-renewal cycle (default Kea lease = 7200s / 2h), verify with `kubectl -n technitium exec <primary-pod> -- grep "TSIG KeyName: kea-ddns-v2" /etc/dns/logs/<today>.log`.
7. Remove the old `kea-ddns` key from Technitium settings + Kea config.

### Emergency TSIG bypass (if rotation breaks DDNS)

If DDNS updates are failing and you cannot quickly fix the key, temporarily
downgrade the zone policy to IP-ACL only (pfSense source IPs) without
TSIG:

```bash
kubectl -n technitium port-forward pod/<primary-pod> 5380:5380 &
TOKEN=$(curl -s -X POST http://127.0.0.1:5380/api/user/login \
  -d "user=admin&pass=$(vault kv get -field=technitium_password secret/platform)&includeInfo=false" | jq -r .token)

for Z in viktorbarzin.lan 10.0.10.in-addr.arpa 20.0.10.in-addr.arpa 1.168.192.in-addr.arpa; do
  curl -s -X POST "http://127.0.0.1:5380/api/zones/options/set?token=$TOKEN&zone=$Z&update=UseSpecifiedNetworkACL&updateNetworkACL=10.0.20.1,10.0.10.1,192.168.1.2&updateSecurityPolicies="
done
```

This clears `updateSecurityPolicies` while keeping the IP ACL. Updates
now flow unsigned from pfSense IPs — **weaker** than TSIG but restores
service. Re-enable TSIG as soon as the key issue is resolved.

### Verify TSIG is enforced

```bash
# Unsigned update should fail
nsupdate <<EOF
server 10.0.20.201 53
zone viktorbarzin.lan
update delete tsig-test.viktorbarzin.lan.
update add tsig-test.viktorbarzin.lan. 300 A 10.99.99.99
send
EOF
# Expected: "update failed: REFUSED"

# Signed update should succeed
cat > /tmp/kea-ddns.key <<EOF
key "kea-ddns" {
    algorithm hmac-sha256;
    secret "$(vault kv get -field=kea_ddns_tsig_secret secret/viktor)";
};
EOF
nsupdate -k /tmp/kea-ddns.key <<EOF
server 10.0.20.201 53
zone viktorbarzin.lan
update delete tsig-test.viktorbarzin.lan.
update add tsig-test.viktorbarzin.lan. 300 A 10.99.99.99
send
EOF
dig @10.0.20.201 +short tsig-test.viktorbarzin.lan
# Expected: 10.99.99.99
rm -f /tmp/kea-ddns.key
```

## Related Docs

- `docs/architecture/dns.md` — overall DNS architecture (K8s side, Technitium, CoreDNS)
- `docs/architecture/networking.md` — VLAN layout, pfSense interface mapping
- `.claude/skills/pfsense/skill.md` — SSH / CLI patterns for pfSense management
