# DNS Architecture

Last updated: 2026-04-15

## Overview

DNS is served by a split architecture: **Technitium DNS** handles internal resolution (`.viktorbarzin.lan`) and recursive lookups, while **Cloudflare DNS** manages all public domains (`.viktorbarzin.me`). Kubernetes pods use **CoreDNS** which forwards to Technitium for internal zones. All three Technitium instances run on encrypted block storage with zone replication via AXFR every 30 minutes.

## Architecture Diagram

```mermaid
graph TB
    subgraph "External"
        Internet[Internet Clients]
        CF[Cloudflare DNS<br/>~50 domains<br/>viktorbarzin.me]
        CFTunnel[Cloudflared Tunnel<br/>3 replicas]
    end

    subgraph "LAN (192.168.1.0/24)"
        LAN[LAN Clients<br/>WiFi / Wired]
        TPLINK[TP-Link AP<br/>Dumb AP only]
    end

    subgraph "pfSense (10.0.20.1)"
        pf_dnsmasq[dnsmasq<br/>Forwarder]
        pf_kea[Kea DHCP4<br/>3 subnets, 53 reservations]
        pf_ddns[Kea DHCP-DDNS<br/>RFC 2136]
        pf_nat[NAT rdr<br/>UDP 53 → Technitium]
    end

    subgraph "Kubernetes Cluster"
        CoreDNS[CoreDNS<br/>kube-system<br/>.:53 + viktorbarzin.lan:53]

        subgraph "Technitium HA (namespace: technitium)"
            Primary[Primary<br/>technitium]
            Secondary[Secondary<br/>technitium-secondary]
            Tertiary[Tertiary<br/>technitium-tertiary]
        end

        LB_DNS[LoadBalancer<br/>10.0.20.201<br/>ETP=Local]
        ClusterIP[ClusterIP<br/>10.96.0.53<br/>pinned]

        subgraph "Automation CronJobs"
            ZoneSync[zone-sync<br/>every 30min]
            SplitHorizon[split-horizon-sync<br/>every 6h]
            DNSOpt[dns-optimization<br/>every 6h]
            PassSync[password-sync<br/>every 6h]
            DNSSync[phpipam-dns-sync<br/>every 15min]
        end
    end

    Internet -->|DNS query| CF
    CF -->|CNAME to tunnel| CFTunnel
    LAN -->|DNS query UDP 53| pf_nat
    pf_nat -->|forward| LB_DNS
    pf_kea -->|lease event| pf_ddns
    pf_ddns -->|A + PTR| LB_DNS

    pf_dnsmasq -->|.viktorbarzin.lan| LB_DNS
    pf_dnsmasq -->|public queries| CF

    CoreDNS -->|.viktorbarzin.lan| ClusterIP
    CoreDNS -->|public queries| pf_dnsmasq

    LB_DNS --> Primary
    LB_DNS --> Secondary
    LB_DNS --> Tertiary
    ClusterIP --> Primary
    ClusterIP --> Secondary
    ClusterIP --> Tertiary

    ZoneSync -->|AXFR| Primary
    ZoneSync -->|replicate| Secondary
    ZoneSync -->|replicate| Tertiary
```

## Components

| Component | Location | Version | Purpose |
|-----------|----------|---------|---------|
| Technitium DNS | K8s namespace `technitium` | 14.3.0 | Primary internal DNS + recursive resolver |
| CoreDNS | K8s `kube-system` | Cluster default | K8s service discovery + forwarding to Technitium |
| Cloudflare DNS | SaaS | N/A | Public domain management (~50 domains) |
| pfSense dnsmasq | 10.0.20.1 | pfSense 2.7.x | DNS forwarder for management VLAN |
| Kea DHCP-DDNS | 10.0.20.1 | pfSense 2.7.x | Automatic DNS registration on DHCP lease |
| phpIPAM | K8s namespace `phpipam` | v1.7.0 | IPAM ↔ DNS bidirectional sync |

### Terraform Stacks

| Stack | Path | DNS Resources |
|-------|------|---------------|
| Technitium | `stacks/technitium/` | 3 deployments, services, PVCs, 4 CronJobs, CoreDNS ConfigMap |
| Cloudflared | `stacks/cloudflared/` | Cloudflare DNS records (A, AAAA, CNAME, MX, TXT), tunnel config |
| phpIPAM | `stacks/phpipam/` | dns-sync CronJob, pfsense-import CronJob |
| pfSense | `stacks/pfsense/` | VM config (DNS config is via pfSense web UI) |

## DNS Resolution Paths

### K8s Pod → Internal Domain (.viktorbarzin.lan)

```
Pod → CoreDNS (kube-dns:53)
  → template: if 2+ labels before .viktorbarzin.lan → NXDOMAIN (ndots:5 junk filter)
  → forward to Technitium ClusterIP (10.96.0.53)
  → Technitium resolves from viktorbarzin.lan zone
```

The ndots:5 template in CoreDNS short-circuits queries like `www.cloudflare.com.viktorbarzin.lan` (caused by K8s search domain expansion) by returning NXDOMAIN for any query with 2+ labels before `.viktorbarzin.lan`. Only single-label queries (e.g., `idrac.viktorbarzin.lan`) reach Technitium.

### K8s Pod → Public Domain

```
Pod → CoreDNS (kube-dns:53)
  → forward to pfSense (10.0.20.1), fallback 8.8.8.8, 1.1.1.1
  → pfSense dnsmasq → Cloudflare (1.1.1.1)
```

### LAN Client (192.168.1.x) → Any Domain

```
Client gets DNS=192.168.1.2 (pfSense WAN) from DHCP
  → pfSense NAT rdr on WAN interface → Technitium LB (10.0.20.201)
  → Technitium resolves:
    - .viktorbarzin.lan → local zone
    - .viktorbarzin.me (non-proxied) → recursive, then Split Horizon translates
      176.12.22.76 → 10.0.20.200 for 192.168.1.0/24 clients
    - other → recursive to Cloudflare DoH (1.1.1.1)
```

Client source IPs are preserved (no SNAT on 192.168.1.x → 10.0.20.x path) — Technitium logs show real per-device IPs.

### Management VLAN (10.0.10.x) → Any Domain

```
Client gets DNS from Kea DHCP → pfSense (10.0.10.1)
  → pfSense dnsmasq:
    - .viktorbarzin.lan → forward to Technitium (10.0.20.201)
    - other → forward to Cloudflare (1.1.1.1)
```

### K8s VLAN (10.0.20.x) → Any Domain

```
Client gets DNS from Kea DHCP → pfSense (10.0.20.1)
  → pfSense dnsmasq:
    - .viktorbarzin.lan → forward to Technitium (10.0.20.201)
    - other → forward to Cloudflare (1.1.1.1)
```

## Technitium DNS — Internal DNS Server

### Deployment Topology

Three independent Technitium instances, each with its own encrypted block storage PVC (`proxmox-lvm-encrypted`, 2Gi each):

| Instance | Deployment | PVC | Web Service | Role |
|----------|-----------|-----|-------------|------|
| Primary | `technitium` | `technitium-primary-config-encrypted` | `technitium-web:5380` | Authoritative primary, zone edits happen here |
| Secondary | `technitium-secondary` | `technitium-secondary-config-encrypted` | `technitium-secondary-web:5380` | AXFR replica |
| Tertiary | `technitium-tertiary` | `technitium-tertiary-config-encrypted` | `technitium-tertiary-web:5380` | AXFR replica |

All three pods share the `dns-server=true` label, so the DNS LoadBalancer (10.0.20.201) and ClusterIP (10.96.0.53) route queries to any healthy instance.

### High Availability

- **Pod anti-affinity**: `required` on `kubernetes.io/hostname` — all 3 pods run on different nodes
- **PodDisruptionBudget**: `minAvailable=2` — at least 2 DNS pods survive voluntary disruptions
- **Recreate strategy**: Each deployment uses `Recreate` (RWO block storage)
- **Zone sync CronJob** (`technitium-zone-sync`, every 30min): Replicates all primary zones to secondary/tertiary via AXFR. Idempotent — skips existing zones, creates missing ones as Secondary type.

### Services

| Service | Type | IP | Selector | Purpose |
|---------|------|-----|----------|---------|
| `technitium-dns` | LoadBalancer | 10.0.20.201 | `dns-server=true` | External LAN access, `externalTrafficPolicy: Local` |
| `technitium-dns-internal` | ClusterIP | 10.96.0.53 (pinned) | `dns-server=true` | CoreDNS forwarding, survives Service recreation |
| `technitium-primary` | ClusterIP | auto | `app=technitium` | Zone transfers (AXFR) + API access to primary only |
| `technitium-web` | ClusterIP | auto | `app=technitium` | Web UI (port 5380) + DoH (port 80) |
| `technitium-secondary-web` | ClusterIP | auto | `app=technitium-secondary` | Secondary API access |
| `technitium-tertiary-web` | ClusterIP | auto | `app=technitium-tertiary` | Tertiary API access |

### Zones

**Primary zones** (managed on primary, replicated to secondary/tertiary):

| Zone | Type | Records | Notes |
|------|------|---------|-------|
| `viktorbarzin.lan` | Primary | 30+ A/CNAME | Internal hosts (idrac, grafana, proxmox, vaultwarden, etc.) |
| `10.0.10.in-addr.arpa` | Primary | PTR | Reverse DNS for management VLAN |
| `20.0.10.in-addr.arpa` | Primary | PTR | Reverse DNS for K8s VLAN |
| `1.168.192.in-addr.arpa` | Primary | PTR | Reverse DNS for LAN |
| `2.3.10.in-addr.arpa` | Primary | PTR | Reverse DNS for VPN |
| `0.168.192.in-addr.arpa` | Primary | PTR | Reverse DNS for Valchedrym site |
| `emrsn.org` | Primary (stub) | — | Returns NXDOMAIN locally (avoids 27K+ daily corporate query floods) |

**Dynamic updates**: Enabled via `UseSpecifiedNetworkACL` from pfSense IPs (10.0.20.1, 10.0.10.1, 192.168.1.2) for Kea DDNS RFC 2136 updates.

### Resolver Settings

| Setting | Value | Rationale |
|---------|-------|-----------|
| Forwarders | Cloudflare DoH (1.1.1.1, 1.0.0.1) | Encrypted upstream DNS |
| Cache max entries | 100K | Ample for homelab |
| Cache min TTL | 60s | Reduces re-queries for short-TTL domains (e.g., headscale: 18s) |
| Cache max TTL | 7 days | Long cache for stable records |
| Serve stale | Enabled (3 days) | Resilience during upstream failures |

### Ad Blocking

Technitium runs built-in DNS blocking with:
- **OISD Big List** (~486K domains)
- **StevenBlack hosts list**

Blocking is enabled on all three instances (`DNS_SERVER_ENABLE_BLOCKING=true` on secondary/tertiary).

### Query Logging

| Backend | Status | Retention | Purpose |
|---------|--------|-----------|---------|
| MySQL (`technitium` DB) | Disabled | — | Legacy, disabled by password-sync CronJob |
| PostgreSQL (`technitium` DB on CNPG) | Enabled | 90 days | Primary query log store |

Grafana dashboard (`grafana-technitium-dashboard` ConfigMap) visualizes query logs from the MySQL datasource. A Grafana datasource is auto-provisioned via sidecar.

### Web UI & Ingress

- **Web UI**: `technitium.viktorbarzin.me` (Authentik-protected via `ingress_factory`)
- **DNS-over-HTTPS**: `dns.viktorbarzin.me` (separate ingress, port 80)
- **Homepage widget**: Technitium widget showing totalQueries, totalCached, totalBlocked, totalRecursive

## Split Horizon (Hairpin NAT Fix)

### Problem

The TP-Link AP (dumb AP on 192.168.1.x) does not support hairpin NAT. LAN clients resolving non-proxied `*.viktorbarzin.me` domains get the public IP `176.12.22.76`, but can't reach it because the TP-Link won't route back to the local network.

### Solution

Technitium's **Split Horizon AddressTranslation** app post-processes DNS responses for 192.168.1.0/24 clients, translating the public IP to the internal Traefik LB IP:

```
176.12.22.76 → 10.0.20.200
```

**DNS Rebinding Protection** has `viktorbarzin.me` in `privateDomains` to allow the translated private IP without being stripped as a rebinding attack.

### Scope

- **Affected**: Non-proxied domains (ha-sofia, immich, headscale, calibre, vaultwarden, etc.) for 192.168.1.x clients
- **Not affected**: Cloudflare-proxied domains (resolve to Cloudflare edge IPs, no translation needed)
- **Not affected**: 10.0.x.x and K8s clients (reach public IP via pfSense outbound NAT normally)

Config is synced to all 3 Technitium instances by CronJob `technitium-split-horizon-sync` (every 6h).

## CoreDNS Configuration

CoreDNS is managed via a Terraform `kubernetes_config_map` resource in `stacks/technitium/modules/technitium/main.tf`.

```
.:53 {
  errors / health / ready
  kubernetes cluster.local in-addr.arpa ip6.arpa  # K8s service discovery
  prometheus :9153                                  # Metrics
  forward . 10.0.20.1 8.8.8.8 1.1.1.1             # pfSense → Google → Cloudflare
  cache (success 10000 300, denial 10000 300)
  loop / reload / loadbalance
}

viktorbarzin.lan:53 {
  template: .*\..*\.viktorbarzin\.lan\.$ → NXDOMAIN  # ndots:5 junk filter
  forward . 10.96.0.53                                # Technitium ClusterIP
  cache (success 10000 300, denial 10000 300)
}
```

**Kyverno ndots injection**: A Kyverno policy injects `ndots:2` on all pods cluster-wide to reduce search domain expansion noise. The template regex is a second layer of defense for any queries that still get expanded.

## Cloudflare DNS — External Domains

All public domains are under the `viktorbarzin.me` zone. DNS records are **auto-created per service** via the `ingress_factory` module's `dns_type` parameter. A small number of records (Helm-managed ingresses, special cases) remain centrally managed in `config.tfvars`.

### How DNS Records Are Created

```
stacks/<service>/main.tf
  module "ingress" {
    source   = ingress_factory
    dns_type = "proxied"    # ← auto-creates Cloudflare DNS record
  }
```

- **`dns_type = "proxied"`**: Creates CNAME → `{tunnel_id}.cfargotunnel.com` (Cloudflare CDN)
- **`dns_type = "non-proxied"`**: Creates A → public IP + AAAA → IPv6
- **`dns_type = "none"`** (default): No DNS record

The Cloudflare tunnel uses a **wildcard rule** (`*.viktorbarzin.me → Traefik`) — no per-hostname tunnel config needed. Traefik handles host-based routing via K8s Ingress resources.

### Record Types

| Type | Records | Target | Example |
|------|---------|--------|---------|
| Proxied CNAME | ~100 domains | `{tunnel_id}.cfargotunnel.com` | blog, hackmd, homepage, ntfy |
| Non-proxied A | ~35 domains | `176.12.22.76` (public IP) | mail, headscale, immich |
| Non-proxied AAAA | ~35 domains | IPv6 (HE tunnel) | Same as non-proxied A |
| MX | 1 | `mail.viktorbarzin.me` | Inbound email |
| TXT (SPF) | 1 | `v=spf1 include:mailgun.org -all` | Email authentication |
| TXT (DKIM) | 4 | RSA keys (s1, mail, brevo1, brevo2) | Email signing |
| TXT (DMARC) | 1 | `v=DMARC1; p=quarantine; pct=100` | Email policy |
| TXT (MTA-STS) | 1 | `v=STSv1; id=20260412` | TLS enforcement |
| TXT (TLSRPT) | 1 | `v=TLSRPTv1; rua=mailto:postmaster@...` | TLS reporting |
| A (keyserver) | 1 | `130.162.165.220` (Oracle VPS) | PGP keyserver |

### Proxied vs Non-Proxied

- **Proxied (orange cloud)**: Traffic routes through Cloudflare CDN → Cloudflared tunnel → Traefik. Benefits: DDoS protection, caching, no public IP exposure.
- **Non-proxied (grey cloud)**: DNS resolves directly to public IP. Required for services needing direct connections (mail, VPN, WebSocket-heavy apps).

### Zone Settings

- **HTTP/3 (QUIC)**: Enabled globally via `cloudflare_zone_settings_override`

## DHCP → DNS Auto-Registration

Devices get automatic DNS registration without manual intervention. See [networking.md § IPAM & DNS Auto-Registration](networking.md#ipam--dns-auto-registration) for the full data flow diagram.

Summary:
1. **Kea DHCP** on pfSense assigns IP (53 reservations across 3 subnets)
2. **Kea DDNS** sends RFC 2136 dynamic update to Technitium (A + PTR records) — immediate
3. **phpipam-pfsense-import** CronJob (5min) pulls Kea leases + ARP table into phpIPAM
4. **phpipam-dns-sync** CronJob (15min) pushes named phpIPAM hosts → Technitium A + PTR, pulls Technitium PTR → phpIPAM hostnames

## Automation CronJobs

| CronJob | Schedule | Namespace | Purpose |
|---------|----------|-----------|---------|
| `technitium-zone-sync` | `*/30 * * * *` | technitium | AXFR replication to secondary/tertiary |
| `technitium-password-sync` | `0 */6 * * *` | technitium | Vault-rotated MySQL password → Technitium config, configure PG logging |
| `technitium-split-horizon-sync` | `15 */6 * * *` | technitium | Split Horizon + DNS Rebinding Protection on all 3 instances |
| `technitium-dns-optimization` | `30 */6 * * *` | technitium | Min cache TTL 60s, emrsn.org stub zone |
| `phpipam-dns-sync` | `*/15 * * * *` | phpipam | Bidirectional phpIPAM ↔ Technitium DNS sync |
| `phpipam-pfsense-import` | `*/5 * * * *` | phpipam | Import Kea DHCP leases + ARP from pfSense |

### Password Rotation Flow

Vault's database engine rotates the Technitium MySQL password every 7 days. The flow:

```
Vault DB engine rotates password
  → ExternalSecret (refreshInterval=15m) pulls from static-creds/mysql-technitium
  → K8s Secret technitium-db-creds updated
  → CronJob technitium-password-sync (every 6h):
    1. Logs into Technitium API
    2. Disables MySQL query logging (migrated to PG)
    3. Checks PG plugin is loaded (warns if missing)
    4. Configures PG query logging (90-day retention)
```

## Monitoring

| Metric Source | Dashboard | Alerts |
|---------------|-----------|--------|
| Technitium query logs (PostgreSQL) | Grafana `technitium-dns.json` | — |
| CoreDNS Prometheus metrics (:9153) | Grafana CoreDNS dashboard | — |
| Uptime Kuma | External monitors for all proxied domains | ExternalAccessDivergence (15min) |

## Troubleshooting

### DNS Not Resolving Internal Domains

1. Check Technitium pods: `kubectl get pod -n technitium`
2. Check all 3 are healthy: `kubectl get pod -n technitium -l dns-server=true`
3. Test from a pod: `kubectl exec -it <pod> -- nslookup idrac.viktorbarzin.lan 10.96.0.53`
4. Check CoreDNS logs: `kubectl logs -n kube-system -l k8s-app=kube-dns`
5. Verify ClusterIP service: `kubectl get svc -n technitium technitium-dns-internal`

### LAN Clients Can't Resolve

1. Verify pfSense NAT rule redirects UDP 53 on WAN to 10.0.20.201
2. Check Technitium LB service: `kubectl get svc -n technitium technitium-dns`
3. Test from LAN: `dig @192.168.1.2 idrac.viktorbarzin.lan`
4. Check `externalTrafficPolicy: Local` — if no Technitium pod runs on the node receiving traffic, it drops

### Hairpin NAT Not Working (LAN → *.viktorbarzin.me Fails)

1. Verify Split Horizon app is installed on all instances
2. Check CronJob status: `kubectl get cronjob -n technitium technitium-split-horizon-sync`
3. Run the job manually: `kubectl create job --from=cronjob/technitium-split-horizon-sync test-sh -n technitium`
4. Test: `dig @10.0.20.201 immich.viktorbarzin.me` — should return 10.0.20.200 for 192.168.1.x source

### Zone Not Replicating to Secondary/Tertiary

1. Check zone-sync CronJob: `kubectl get cronjob -n technitium technitium-zone-sync`
2. Check recent jobs: `kubectl get jobs -n technitium | grep zone-sync`
3. Verify AXFR is enabled on primary: Check zone options → Zone Transfer = Allow
4. Run sync manually: `kubectl create job --from=cronjob/technitium-zone-sync test-sync -n technitium`

### High NXDOMAIN Rate in Logs

Common causes:
- **ndots:5 expansion**: Pods query `host.search.domain.viktorbarzin.lan` — mitigated by CoreDNS template + Kyverno ndots:2
- **Corporate domains (emrsn.org)**: 27K+ daily queries — mitigated by stub zone returning NXDOMAIN locally
- **Ad blocking**: Expected for blocked domains

### Adding a New DNS Record

For internal `.viktorbarzin.lan` records:
1. Add host in phpIPAM web UI (`phpipam.viktorbarzin.me`) with hostname
2. Wait 15 minutes for `phpipam-dns-sync` to push to Technitium
3. Or add directly in Technitium web UI (`technitium.viktorbarzin.me`)

For external `.viktorbarzin.me` records:
1. Add `dns_type = "proxied"` (or `"non-proxied"`) to the `ingress_factory` module call in the service stack
2. Run `scripts/tg apply` on the service stack — DNS record is auto-created
3. For non-standard records (MX, TXT), add a `cloudflare_record` resource in `stacks/cloudflared/modules/cloudflared/cloudflare.tf`

## Incident History

- **2026-04-14 (SEV1)**: NFS `fsid=0` caused Technitium primary data loss on restart. Fixed by migrating all 3 instances to `proxmox-lvm-encrypted`, adding zone-sync CronJob (30min AXFR). See [post-mortem](../post-mortems/2026-04-14-nfs-fsid0-dns-vault-outage.md).

## Related

- [Networking Architecture](networking.md) — VLAN topology, IPAM auto-registration, ingress flow, MetalLB
- [Mailserver Architecture](mailserver.md) — DNS records for email (MX, SPF, DKIM, DMARC)
- [Security Architecture](security.md) — Kyverno ndots policy
- [Monitoring Architecture](monitoring.md) — CoreDNS metrics, Uptime Kuma external monitors
- Runbook: `docs/runbooks/add-dns-record.md` (referenced but not yet created)
