# Network intrusion detection and prevention

Status: draft, awaiting Viktor's approval. Grilled with Viktor on 2026-11-10 (memory #17435); revised the same day after two blind challenger reviews. Research: `docs/research/2026-11-03-network-ids-options.md`, ADR-0038.

## Goal

Inspect Sofia traffic for malicious flows, keep what the IDS sees queryable in ClickHouse, tell us in Slack, and turn detections into firewall bans. Built from parts already running. OPNsense became the production edge firewall on 2026-11-10 (ADR-0038 amendment, `7979f6d36`); pfSense VM 101 stays stopped as the rollback.

## Decisions

| # | Area | Decision |
|---|---|---|
| 1 | DPI | Suricata protocol metadata: DNS, TLS names and JA4, HTTP hosts. No Zenarmor or ntopng: neither exports to ClickHouse for free |
| 2 | Prevention | Suricata stays in IDS mode. Alerts become CrowdSec bans, enforced by OPNsense in pf tables. No inline IPS |
| 3 | Inbound bans | Outside addresses that attack us, from TCP alerts only (`crowdsecurity/suricata` hub scenarios). No UDP-based bans: spoofed UDP could ban our WireGuard peers |
| 4 | Destination bans | Only abuse.ch C2 hits (Feodo Tracker, SSL Blacklist) when one of our hosts is the source. They go into a separate list that only a new OPNsense outbound rule uses; Traefik, node and host bouncers never see them, and IPv6 widening skips them. Other malware hits alert without banning. Home devices are never banned |
| 5 | Ban start | Every scenario on every agent runs in CrowdSec simulation for 2 weeks; Viktor reviews the would-be bans; then real bans |
| 6 | Data | Alerts 365d, dns/tls/http 30d, NetFlow 14d, proxy URLs 30d, Tetragon connections 30d. No Suricata flow events |
| 7 | Store | Database `netsec` on the existing `claude-sessions` ClickHouse (encrypted SAS). Not backed up: losing the disk loses history only, and no browsing data lands on NFS or offsite |
| 8 | Access | Viktor only. No Grafana datasource, because every Authentik user is a Grafana Viewer and OSS Grafana cannot restrict a datasource. Queries through `homelab netsec sql` |
| 9 | Notify | Slack #alerts for everything. Bans grouped into one message per 10 minutes by the CrowdSec Slack plugin; home-device malware alerts post at once from a scheduled query job through Alertmanager (`lane=security`) |
| 10 | Shipper | Its own Vector Deployment in `stacks/netsec`, same image and config pattern as rybbit's `event-pipeline` (ADR-0041). Viktor first chose to share `event-pipeline`, then reversed after the review showed a netsec fault would stop app analytics |
| 11 | Host agents | CrowdSec agent and bouncer on Linux servers and Windows VM 300; Tetragon on k8s nodes, watch-only. Nothing on personal devices; no osquery or Fleet |
| 12 | Decryption | Squid SSL bump on OPNsense for an `opted_in` alias. URLs only, no virus scanning |
| 13 | Sites | Sofia only |

## Pipeline

```
OPNsense (production)
  Suricata IDS -- eve.json (stock) + eve-meta.json (alert, dns, tls, http)
     |-- os-crowdsec agent (simulation) --> LAPI (k8s)
     |        inbound bans  --> pf, WAN + HE tunnel, in
     |        C2 dest. bans --> pf, lan + opt1, out   (OPNsense only)
     |        Slack plugin, grouped 10 min
     |-- syslog-ng file tail, TCP ----------+
  Squid (opted_in only), JSON --------------+
  NetFlow v9 --> goflow2 + shipper sidecar -+
k8s nodes: Tetragon, JSON ------------------+
                                            v
                         Vector (new, ns netsec) --> ClickHouse netsec.*
                                                        |
                         homelab netsec sql          scheduled query job
                                                        --> Alertmanager --> Slack
```

## What it sees and what it does not

| Path | Seen |
|---|---|
| Internet to direct (non-proxied) hosts, IPv4 and HE IPv6 | yes, on WAN and the HE tunnel |
| Proxied hostnames | no: they arrive inside the cloudflared tunnel as TLS to Cloudflare. Traefik's CrowdSec plugin keeps covering them |
| Homelab hosts to the internet, and between VLANs | yes, on lan and opt1, with the inside address |
| Road-warrior WireGuard (ends in a pod) and node-to-node traffic | no: east-west. Tetragon covers k8s nodes |
| Pod DNS | named as Technitium, not the pod; Tetragon and Goldmane give the pod |
| DoH, DoT from clients, ECH | names hidden; flows still recorded |
| Home LAN devices behind the AX6000 | no, until open question 1 is settled |

## Phases

Every OPNsense change lands on the production firewall: `--check --diff` first, applied in a quiet hour, verified, with the listed rollback. Each phase is verified before the next.

### 1. Store and shipper
- `netsec` database, a writer user with a real quota (rows and bytes per hour) and a reader user for Viktor, tables `eve` (typed columns plus JSON, TTL per event type, IPv6 columns), `flows`, `proxy`, `process_connections`, on the claude-sessions instance (`stacks/claude-sessions`). `backup.sh` stays `DATABASE claude` only.
- `stacks/netsec`: a Vector Deployment with memory buffers (disk buffers jammed on 0.61.0, `stacks/rybbit/files/vector.yaml:294`), a TCP input on an internal LoadBalancer with source ranges limited to OPNsense, and a NetworkPolicy so only OPNsense, goflow2 and Tetragon reach it.
- goflow2 writes flows to a file on a shared emptyDir; a Vector sidecar in the goflow2 pod tails it and forwards to the netsec Vector.
- `homelab netsec sql` verb next to `homelab claude-sessions sql`.
- Verify: rows arrive in `flows` from live NetFlow; `homelab netsec sql` returns them.
- Rollback: delete the stack; goflow2 returns to stdout.

### 2. Suricata metadata off the box
- A conf.d file that restates all four stock outputs (eve.json, syslog eve, stats, syslog) and adds `eve-meta.json`. A repeated `outputs:` key replaces the template's list, so the playbook asserts with `suricata --dump-config` that all five exist.
- A `newsyslog.conf.d` entry rotates `eve-meta.json`.
- A syslog-ng `conf.d` file tails it and sends raw JSON lines over TCP to Vector, avoiding the 8 KB syslog limit.
- All in `playbooks/tasks/opnsense/`; `--check` must stay a no-op after apply.
- Verify: `curl testmynids.org/uid/index.html` from VLAN 20 lands in `netsec.eve`; dns and tls rows arrive; Intrusion Detection > Alerts and Loki still show the alert.
- Rollback: remove the two conf.d files and reconfigure the IDS.

### 3. Alerts into bans, in simulation
- LAPI allowlist in Terraform, copied from the existing parser whitelist (`stacks/crowdsec/modules/crowdsec/main.tf:320-370`: private ranges, 100.64/10, 172.16/12, Sofia egress 176.12.22.76, Viktor's work ranges) plus `2001:470:6f:43d::/64`, `2001:470:6e:43d::/64`, the HE endpoint, Cloudflare, upstream resolvers, GitHub and ghcr. 100.64/10 joins Suricata's HOME_NET.
- `simulation: true` globally on the OPNsense agent, set by the playbook and checked after every reconfigure.
- os-crowdsec agent on, with an `acquis.d` file for `eve.json` (`type: suricata-evelogs`) and the `crowdsecurity/suricata` collection.
- Custom scenario for C2 destinations with its own origin; a new OPNsense alias fed only by that origin; an outbound pf rule on lan and opt1. The Traefik plugin, node bouncers and host bouncers filter that origin out; `ipv6-ban-widen.sh` skips it.
- CrowdSec Slack plugin with a 10 minute group wait. Scheduled query job (CronJob in `stacks/netsec`) posts home-device malware alerts to Alertmanager every minute.
- Verify: the test alert gives a simulated decision and a Slack message; nothing reaches pf.
- Rollback: agent off in the playbook; decisions expire.

### 4. Host agents
- CrowdSec agent and firewall bouncer through Ansible on the devvm (`playbooks/devvm.yml`), the Proxmox host, rpi-sofia and the registry VM; CrowdSec for Windows plus the Windows Firewall bouncer on VM 300. Simulation on each agent.
- Tetragon in a new `stacks/tetragon` (Helm through Terraform), one observe-only `tcp_connect` policy, JSON to Vector. Measured on node1 before rolling to all nodes.
- Verify: an ssh brute force from a test address gives a simulated decision; a pod's outbound connection appears in `netsec.process_connections` with binary and pod.

### 5. Decryption for opted-in machines
- os-squid in transparent mode, port forward of TCP 443 only from `opted_in`, UDP 443 blocked for that alias.
- Root CA generated and kept off the cluster and off the firewall; the firewall holds a 1-year intermediate (path length 0). The no-bump list, not name constraints, keeps banking and pinned apps out.
- No-bump list: Apple, Google, Microsoft Update, banking, messaging, password managers.
- Squid JSON access log without Referer, to Vector, `netsec.proxy` 30d. Query strings stay stripped.
- The alias starts empty; one throwaway VM proves it.

### 6. Go-live and enforcement
- Simulation clock starts when phase 3 lands. After one hour of phase 2 data, measure `eve` volume and resize the claude-sessions PVC if the estimate (30-150 MB/day) is off.
- After 2 weeks: review the would-be bans with Viktor, tune, switch simulation off on every agent.

## Production checks

Prometheus alerts, routed to the security lane:
- no rows per source for 30 minutes (eve, flows, proxy, process_connections)
- netsec Vector sink errors and buffer fill
- OPNsense: Suricata, Squid, os-crowdsec agent or bouncer down, via a node_exporter textfile collector; root filesystem above 80 percent
- OPNsense agent not pushing to the LAPI; OPNsense bouncer not pulling
- intermediate CA expiring within 30 days
- claude-sessions ClickHouse disk above 80 percent; Tetragon DaemonSet not ready

Docs: new `docs/architecture/network-security-monitoring.md` and `docs/runbooks/network-ids.md`; updates to `docs/architecture/networking.md`, `docs/agents/security.md`, `docs/runbooks/opnsense.md`, `.claude/reference/service-catalog.md`.

## Risks

| Risk | Mitigation |
|---|---|
| A false positive bans something we rely on | Full allowlist first, global simulation for 2 weeks, review before enforcing |
| A change on the production firewall breaks routing | `--check --diff`, quiet-hour applies, per-phase rollback, pfSense VM 101 as the last resort |
| An OPNsense upgrade changes the Suricata template | Playbook asserts all five outputs after every run |
| A C2 address on a shared cloud blocks something we use | Destination bans only from abuse.ch C2 lists, outbound at OPNsense only, with the CDN allowlist |
| The claude-sessions ClickHouse (4Gi limit) slows under netsec load | Writer quota; measure after phase 2; split into its own instance if needed |
| The Squid plugin has no named maintainer | Confined to `opted_in`; a dead Squid alerts and affects only those machines |
| PII: every site each device visits | Encrypted storage, no Grafana, no backups, Viktor-only user, TTLs |

## Open questions

1. **Home LAN coverage.** Home devices sit behind the AX6000 and never cross OPNsense. Options: OPNsense as the edge router with the AX6000 as an access point; a separate inspected Wi-Fi VLAN; mirroring the internet link (no per-device attribution); DNS logging only. Viktor is discussing it with emo.
2. **Opted-in machines.** Which machines trust the interception certificate. Mostly depends on question 1.
3. **Tetragon retention** was not discussed; 30 days is a default.
4. **Duplicate alerts.** Suricata runs on wan, lan and opt1, so a routed flow can alert twice. Collapse by `community_id` at query time; revisit if Slack shows duplicates.
