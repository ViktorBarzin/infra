# OPNsense Unbound DNS resolver

> Rewritten for OPNsense at the 2026-11-10 cutover; the resolver ran on pfSense before.

## Overview

OPNsense runs **Unbound** as the firewall's only DNS service. On pfSense,
Unbound replaced dnsmasq (DNS Forwarder) on 2026-04-19 (DNS hardening
Workstream D, bd `code-k0d`); the OPNsense settings were converted from that
pfSense config.

Unbound AXFR-slaves the `viktorbarzin.lan` zone from the Technitium primary
via the `10.0.20.201` LoadBalancer, so LAN-side `.lan` resolution survives
a full Kubernetes outage. Public queries go to Cloudflare via DNS-over-TLS
(`1.1.1.1` + `1.0.0.1` on port 853, verified as `cloudflare-dns.com`).

Config is code: `playbooks/files/opnsense/unbound.yml`, applied by
`playbooks/tasks/opnsense/unbound.yml`. Never change Unbound in the GUI.

```sh
cd ~/code/infra
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags unbound --check --diff
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags unbound
scripts/opnsense-verify --host 10.0.10.1 --profile production
```

## Listeners

Unbound binds on (checked with `sockstat` on 2026-11-10):

| Interface | IP | Purpose |
|-----------|-----|---------|
| WAN (`wan`)  | `192.168.1.2:53` | LAN (192.168.1.0/24) clients querying via the firewall's WAN address |
| LAN (`lan`)  | `10.0.10.1:53`   | Management VLAN clients |
| OPT1 (`opt1`) | `10.0.20.1:53`  | K8s VLAN clients (CoreDNS upstream) |
| lo0          | `127.0.0.1:53`   | the firewall itself |

`unbound.yml` lists `lan`, `opt1`, `wan`, `lo0`; the task leaves `lo0` out
because OPNsense adds the loopback addresses itself. The VLAN 30 (CCTV) and
WireGuard addresses are not listeners; the `WireGuard` access list in
`unbound.yml` allows `10.3.0.1/32`.

History: the pfSense WAN NAT `rdr` rule (`192.168.1.2:53 → 10.0.20.201`) was
removed on 2026-04-19, when Unbound started answering on WAN directly.

## Config summary

Keys in `unbound.yml` and what they set:

| Key | Value | Meaning |
|-----|-------|---------|
| `enabled` | `true` | Enable Unbound |
| `dnssec` | `true` | DNSSEC validation on |
| `harden_dnssec_stripped` | `true` | Reject DNSSEC-stripped answers |
| `forwarding` | enabled, `use_tls: true` | Forward recursive queries to the two DoT servers (written as DoT entries, `/var/unbound/etc/dot.conf`) |
| `prefetch`, `prefetch_key` | `true` | Prefetch records and DNSKEYs near expiry |
| `serve_expired` | `true` | `serve-expired: yes` |
| `serve_expired_ttl` | `259200` | Serve expired answers for up to 3 days |
| `listen_interfaces` | `lan, opt1, wan, lo0` | Listen interfaces (see above) |
| `advanced.msgcachesize_mb` | `256` | Message cache |
| `advanced.cache_max_ttl` | `604800` | 7 days |
| `advanced.cache_min_ttl` | `60` | 60 seconds |
| `dns_rebind_protection` | `false` | As on pfSense; see Known gotchas for what OPNsense does anyway |
| `private_domains` | `viktorbarzin.me` | The task adds `viktorbarzin.lan` |
| `insecure_domains` | `viktorbarzin.me` | No DNSSEC validation for this zone |
| `auth_zone` | see below | `viktorbarzin.lan` secondary |

The two forwarders, as rendered on the box:

```
forward-zone:
  name: "."
  forward-tls-upstream: yes
  forward-addr: 1.1.1.1@853#cloudflare-dns.com
  forward-addr: 1.0.0.1@853#cloudflare-dns.com
```

## Auth-zone for viktorbarzin.lan

The auth-zone has no OPNsense API, so the task renders it from `unbound.yml`
`auth_zone` into `/usr/local/etc/unbound.opnsense.d/viktorbarzin-lan.conf`
(template `unbound-auth-zone.conf.j2`). OPNsense copies that file into the
chroot (`/var/unbound/etc/`) and includes it on every reconfigure:

```
auth-zone:
    name: "viktorbarzin.lan"
    primary: 10.0.20.201
    zonefile: "viktorbarzin.lan.zone"
    allow-notify: 10.0.20.201
    fallback-enabled: yes
    for-downstream: yes
    for-upstream: yes
```

- `primary: 10.0.20.201`: AXFR source (Technitium LoadBalancer)
- `fallback-enabled: yes`: if the zone can't refresh from the primary, fall back to normal recursion for this name (prevents hard-fail if AXFR breaks)
- `for-downstream: yes`: answer queries for this zone with the AA flag
- `for-upstream: yes`: Unbound's internal iterator also uses this zone
- `zonefile` is relative to the chroot (`/var/unbound/viktorbarzin.lan.zone`)
- `allow-notify: 10.0.20.201`: accept NOTIFY from Technitium

## Technitium-side ACL

Zone `viktorbarzin.lan` on Technitium has `zoneTransfer = UseSpecifiedNetworkACL`
with ACL entries for the firewall's three addresses, which OPNsense took over
from pfSense unchanged:

- `10.0.20.1` (OPT1)
- `10.0.10.1` (LAN)
- `192.168.1.2` (WAN)

Verify via the Technitium API:

```
curl -sk "http://127.0.0.1:5380/api/zones/options/get?token=$TOK&zone=viktorbarzin.lan" | jq .response.zoneTransfer
```

## Domain override: viktorbarzin.me → Technitium (2026-06-10)

`unbound.yml` `domain_overrides` carries one entry forwarding the whole
`viktorbarzin.me` zone to Technitium `10.0.20.201` (forward-zone, not AXFR;
rendered as `/var/unbound/etc/domainoverrides.conf`). Every Unbound client
(all VLANs + 192.168.1.x via the WAN listener) gets Technitium's internal
split-horizon answers: ingress hosts CNAME to the zone apex whose A record
auto-tracks the live Traefik LB IP (`technitium-ingress-dns-sync` + the
`apex-dns` blackbox scrape as drift canary; it replaced the
`viktorbarzin-apex-probe` CronJob on 2026-08-16). This is what keeps kubelet
forgejo image pulls (and everything else on 10.0.x) off the broken public
NAT-hairpin with zero per-host DNS config; see
`docs/post-mortems/2026-06-10-tuya-bridge-forgejo-pull-hairpin.md`.

Notes:

- The domain is NOT DNSSEC-signed (no DS records). On pfSense no
  `domain-insecure` or `private-domain` options were needed; on OPNsense
  `unbound.yml` lists `viktorbarzin.me` in both `insecure_domains` and
  `private_domains`, because OPNsense strips private answers outside the
  private domains.
- **Cluster-outage behavior**: the zone SERVFAILs while Technitium is down
  (forward-zone, no local copy). Deliberate: the services are down anyway.
  Contrast with `viktorbarzin.lan`, which is AXFR-slaved to survive outages.
- **In-cluster pods must NOT see these answers** (Traefik LB is ETP=Local,
  unreachable from pods). CoreDNS has a dedicated `viktorbarzin.me:53`
  carve-out (stacks/technitium); do not remove it while this override exists.
- To change or remove the override, edit `domain_overrides` in `unbound.yml`
  and run the playbook with `--tags unbound` (the task prunes entries that are
  no longer in the YAML). History: on pfSense the entry was added on
  2026-06-10 with an SSH + PHP `write_config()` call.

Verify:

```
dig +short @10.0.20.1 forgejo.viktorbarzin.me   # apex CNAME + live Traefik IP
dig +short @10.0.20.1 mail.viktorbarzin.me      # 10.0.20.1 (non-Traefik record)
dig +short @10.0.20.1 google.com                # public, unaffected
```

## Operational checks

```bash
# Is Unbound listening?
ssh root@10.0.10.1 "sockstat -l -4 -p 53"

# Auth-zone loaded?
ssh root@10.0.10.1 "unbound-control -c /var/unbound/unbound.conf list_auth_zones"
# Expected: viktorbarzin.lan.      serial NNNNN

# LAN record via auth-zone? (aa flag = authoritative / from auth-zone)
dig @192.168.1.2 idrac.viktorbarzin.lan +norec

# Public record via DoT? (ad flag = DNSSEC validated, via 1.1.1.1/1.0.0.1)
dig @192.168.1.2 example.com +dnssec

# Zonefile has all records?
ssh root@10.0.10.1 "wc -l /var/unbound/viktorbarzin.lan.zone"
```

Resolver logs: `opnsense-log resolver` on the box, or Loki
`{job="syslog", host="opnsense"}`.

## K8s outage drill

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

Completed successfully on 2026-04-19 on pfSense; not yet re-run on OPNsense
(as of 2026-11-10).

Note: secondary/tertiary Technitium pods remain up and continue to serve
queries via the `10.0.20.201` LoadBalancer even when the primary is down,
so the strongest proof that Unbound's auth-zone serves locally is to also
scale those down (optional, not part of the routine drill).

## Backup and rollback

### Backups

- **Source**: `unbound.yml` and the auth-zone template in git.
- **Daily**: `scripts/daily-backup.sh` (step 3, on the Proxmox host, run by the nightly chain)
  copies `/conf/config.xml` to `/mnt/backup/opnsense/config-YYYYMMDD.xml`;
  alert `OpnsenseBackupStale`.
- **Offsite**: Synology `pve-backup/`, synced from `/mnt/backup` daily by
  `offsite-sync-backup`.

### Rollback

- A bad Unbound change: revert the edit to `unbound.yml` and run the playbook
  with `--tags unbound`.
- The whole firewall back to pfSense: `/root/opnsense-cutover/opnsense-cutover rollback`
  on the Proxmox host (`docs/runbooks/opnsense.md`). Never start VM 101
  directly; it has OPNsense's MACs and addresses.

History: on pfSense the rollback to dnsmasq restored
`/cf/conf/config.xml.2026-04-19-pre-unbound` and re-added the WAN NAT `rdr`
(tracker `1775670025`). Neither applies to OPNsense, which has no dnsmasq
setup to go back to.

## Known gotchas

1. **OPNsense regenerates `/var/unbound/unbound.conf`** and the files under
   `/var/unbound/etc/` on every reconfigure. Edits on the box are NOT durable;
   edit `unbound.yml` or the auth-zone template.
2. **`unbound-control` needs the config path.** Use
   `unbound-control -c /var/unbound/unbound.conf <cmd>`.
3. **`auth-zone`'s `zonefile` path is relative to the Unbound chroot**
   (`/var/unbound`), NOT absolute. Using an absolute path silently fails.
4. **DoT forwarders need the verify hostname.** Each DoT entry carries
   `cloudflare-dns.com` so the rendered line is `1.1.1.1@853#cloudflare-dns.com`.
   On pfSense, without the hostname the line rendered as `1.1.1.1@853` (no `#`)
   and Cloudflare rejected it with a certificate hostname mismatch.
5. **Private answers are stripped outside the private domains.** pfSense had
   DNS rebind protection off; OPNsense always strips private-address answers for
   names outside its private domains, so the task adds `viktorbarzin.lan` to
   `viktorbarzin.me` there. A new internal zone with private answers needs the
   same.
6. **Unbound does not register DHCP leases.** `register_dhcp_leases` in the
   YAML reads `true` (pfSense's value), but the task writes `regdhcp: false`:
   on pfSense it had no effect with Kea.

## Kea DHCP-DDNS TSIG (WS E, 2026-04-19)

Kea DHCP-DDNS on pfSense signed its RFC 2136 dynamic updates with an
HMAC-SHA256 TSIG key (`kea-ddns`). Technitium's `viktorbarzin.lan` zone
and reverse zones (`10.0.10.in-addr.arpa`, `20.0.10.in-addr.arpa`,
`1.168.192.in-addr.arpa`) require both a firewall source IP (10.0.20.1 /
10.0.10.1 / 192.168.1.2) AND a valid TSIG signature.

**State on 2026-11-10.** The firewall sends no dynamic updates. On OPNsense
`kea-dhcp-ddns` is not running, `kea-dhcp4.conf` has no DDNS settings, and
the playbook's Kea task (`dhcp.yml`, `--tags kea`) configures none. Before the
cutover pfSense was in the same state: since 2026-10-14 at least,
`kea-dhcp-ddns` was not running and pfSense had regenerated `kea-dhcp4.conf` on
2026-07-18 without the hand-added DDNS settings. The Technitium side is ready:
since 2026-10-14 the `technitium-dynamic-updates` CronJob
(`stacks/technitium/modules/technitium/dynamic_updates.tf`) sets the key and
the zone policy on all three instances every hour, so Technitium accepts
signed updates from the firewall addresses as soon as something sends them.
The same zone also accepts the `external-dns` key (ADR-0033).

### Config locations

| Side | File | Notes |
|------|------|-------|
| OPNsense | none | No DDNS config. Turning it on would be a change to the Kea task and `dhcp.yml`, not a hand edit on the box |
| Technitium | Zone options API: `POST /api/zones/options/set?zone=<z>&updateSecurityPolicies=kea-ddns\|*.<z>\|ANY&updateNetworkACL=10.0.20.1,10.0.10.1,192.168.1.2&update=UseSpecifiedNetworkACL` | Set by the `technitium-dynamic-updates` CronJob on all 3 instances: AXFR copies records, not zone options. Key policies apply on the primary only; replicas forward signed updates to it |
| Technitium settings | TSIG keys array: `POST /api/settings/set` with `tsigKeys: [{keyName: "kea-ddns", sharedSecret: <b64>, algorithmName: "hmac-sha256"}]` | Set by the `technitium-dynamic-updates` CronJob on all 3 instances, from Vault. The API replaces the whole list, so the job sends both keys (`kea-ddns`, `external-dns`) every time it writes |
| Vault | `secret/viktor/kea_ddns_tsig_secret` | Authoritative copy of the base64 secret |

History: on pfSense the client side was the hand-managed
`/usr/local/etc/kea/kea-dhcp-ddns.conf` (pre-WS-E backup `.2026-04-19-pre-tsig`).

### Rotating the TSIG key

Since 2026-10-14 the `technitium-dynamic-updates` CronJob rewrites the key
list and zone policies on every instance hourly from
`stacks/technitium/modules/technitium/dynamic_updates.tf`. A key or policy
added only through the API is removed within the hour, so steps 3, 5 and 7
below are edits to that file (the `KEYS` list and `dynamic_update_zones`),
followed by a run of the job, rather than API calls.

1. Generate a new base64 32-byte secret: `openssl rand -base64 32` (any base64-encoded blob of reasonable length works; HMAC-SHA256 truncates/pads internally).
2. Write it to Vault: `vault kv patch secret/viktor kea_ddns_tsig_secret=<new-secret>`.
3. Add the new key under a **new name** (e.g., `kea-ddns-v2`) on all 3 instances. Do NOT remove `kea-ddns` while a client still uses it; you'd orphan in-flight updates.
4. Point the DDNS client at the new key. While the firewall sends no updates (above) there is nothing to change here.
5. Update each affected zone's `updateSecurityPolicies` to use the new key name.
6. After a lease-renewal cycle (default Kea lease = 7200s / 2h), verify with `kubectl -n technitium exec <primary-pod> -- grep "TSIG KeyName: kea-ddns-v2" /etc/dns/logs/<today>.log`.
7. Remove the old `kea-ddns` key from Technitium settings and from any client config.

### Emergency TSIG bypass (if rotation breaks DDNS)

If DDNS updates are failing and you cannot quickly fix the key, temporarily
downgrade the zone policy to IP-ACL only (firewall source IPs) without
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
now flow unsigned from the firewall IPs: **weaker** than TSIG but restores
service. Re-enable TSIG as soon as the key issue is resolved. The hourly
CronJob puts the key policies back on its next run.

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

## Related docs

- `docs/runbooks/opnsense.md`: the OPNsense box, its playbook, access, cutover and rollback
- `docs/architecture/dns.md`: overall DNS architecture (K8s side, Technitium, CoreDNS)
- `docs/architecture/networking.md`: VLAN layout, firewall interface mapping
