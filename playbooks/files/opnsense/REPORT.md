# pfSense to OPNsense conversion report

Generated from pfSense config.xml on 2026-11-04 by `scripts/pfsense-to-opnsense.py`, then reviewed. Edit the YAML, do not regenerate.

## Counts

| Section | pfSense | YAML | Note |
|---|---|---|---|
| filter rules | 57 | 52 | 10 had an empty type (pfSense: pass); 4 had no ipprotocol (pfSense: inet) |
| aliases | 10 | 10 |  |
| gateways | 8 | 8 | 1 marked port: false |
| static routes | 6 | 6 |  |
| NAT port forwards | 27 | 26 | enabled 24 -> 23 |
| outbound NAT rules | 15 | 15 | mode hybrid |
| DHCPv4 interfaces | 4 | 3 | backend kea; 12 reservations |
| router advertisements | 3 | 2 | opt1 is ramode disabled |
| unbound domain overrides | 1 | 1 |  |
| unbound host overrides | 0 | 0 |  |
| unbound ACLs | 1 | 1 |  |
| NTP servers | 1 | 1 |  |
| WireGuard tunnels | 1 | 1 |  |
| WireGuard peers | 4 | 4 | no peer has a configured endpoint (they all dial in) |
| Tailscale advertised routes | 7 | 7 |  |
| HAProxy frontends | 6 | 5 |  |
| HAProxy backends | 7 | 6 |  |
| softflowd instances | 1 | 1 |  |
| remote syslog targets | 1 | 1 |  |
| sysctl tunables | 1 | 1 |  |

## Dropped

- filter: filter rule 1621028916 (NAT imaps). references alias 'mailserver', which config.xml does not define.
- filter: filter rule 1621028981 (NAT smtps). references alias 'mailserver', which config.xml does not define.
- filter: filter rule 1621167654 (NAT smtps submission). references alias 'mailserver', which config.xml does not define.
- filter: filter rule 1621168251 (NAT imap). references alias 'mailserver', which config.xml does not define.
- filter: filter rule 1673734240 (NAT). references alias 'mailserver', which config.xml does not define.
- gateways: default. stale ISP inet6 gateway, kept in YAML with port: false.
- nat port forwards: port forward wan:143 (imap). targets alias 'mailserver', which config.xml does not define.
- dhcp: DHCPv4 on wan (range 192.168.1.20-192.168.1.254). disabled in pfSense (the TP-Link serves that LAN).
- dhcp: DHCPv6 on opt1 (range 2a00:4802:365:fc02::). DHCPv6 server disabled in pfSense.
- dhcp: DHCPv6 on lan (range 2001:470:6f:43d::1). DHCPv6 server disabled in pfSense.
- radvd: router advertisements on opt1. ramode disabled in pfSense.
- dns: dnsmasq settings (interfaces, custom options, host pxe.viktorbarzin.lan -> 10.0.10.20). dnsmasq is disabled in pfSense; Unbound answers on port 53.
- haproxy: frontend mailserver_proxy_test (:2525). the :2525 test listener (decision 7).
- haproxy: backend mailserver_nodes. used only by a dropped frontend.

## Literal firewall addresses replaced

| Object | Field | pfSense | YAML |
|---|---|---|---|
| filter rule 1775639929 (Allow DNS (UDP) from LAN to pfSense) | destination.address | `192.168.1.2` | `{{ fw.wan }}` |
| filter rule 1783022274 (CCTV: allow NTP to gateway only (default deny covers the rest)) | destination.address | `10.0.30.1` | `{{ fw.opt4 }}` |
| port forward wan:587 (smtps submission) | target | `10.0.20.1` | `{{ fw.opt1 }}` |
| port forward wan:993 (imaps) | target | `10.0.20.1` | `{{ fw.opt1 }}` |
| port forward wan:465 (smtps) | target | `10.0.20.1` | `{{ fw.opt1 }}` |
| port forward wan:25 (no description) | target | `10.0.20.1` | `{{ fw.opt1 }}` |
| dhcp lan | dns_servers | `10.0.10.1` | `{{ fw.lan }}` |
| dhcp lan | gateway (pfSense default) | `10.0.10.1` | `{{ fw.lan }}` |
| dhcp opt1 | dns_servers | `10.0.20.1` | `{{ fw.opt1 }}` |
| dhcp opt1 | gateway (pfSense default) | `10.0.20.1` | `{{ fw.opt1 }}` |
| dhcp opt4 | dns_servers (pfSense default) | `10.0.30.1` | `{{ fw.opt4 }}` |
| dhcp opt4 | gateway (pfSense default) | `10.0.30.1` | `{{ fw.opt4 }}` |
| radvd lan | rdnss (pfSense default) | `2001:470:6f:43d::1` | `{{ fw.lan_v6.split('/')[0] }}` |
| haproxy frontend mailserver_proxy_25 | bind | `10.0.20.1` | `{{ fw.opt1 }}` |
| haproxy frontend mailserver_proxy_465 | bind | `10.0.20.1` | `{{ fw.opt1 }}` |
| haproxy frontend mailserver_proxy_587 | bind | `10.0.20.1` | `{{ fw.opt1 }}` |
| haproxy frontend mailserver_proxy_993 | bind | `10.0.20.1` | `{{ fw.opt1 }}` |
| haproxy frontend internal_https_443 | bind | `10.0.20.1` | `{{ fw.opt1 }}` |
| haproxy frontend internal_https_443 | bind | `10.0.10.1` | `{{ fw.lan }}` |

## pfSense defaults written out

- dhcp lan: gateway unset; pfSense uses the interface address
- dhcp lan: domain unset; pfSense uses the system domain viktorbarzin.lan
- dhcp opt1: gateway unset; pfSense uses the interface address
- dhcp opt1: domain unset; pfSense uses the system domain viktorbarzin.lan
- dhcp opt4: no DNS servers set; pfSense then offers the interface address, written out as {{ fw.opt4 }}
- dhcp opt4: gateway unset; pfSense uses the interface address
- dhcp opt4: domain unset; pfSense uses the system domain viktorbarzin.lan
- radvd lan: RDNSS unset; pfSense advertises the interface address, written out as a placeholder
- radvd lan: DNSSL unset; pfSense advertises the system domain viktorbarzin.lan

## Not mapped

- `dhcp reservation client id`: lan truenas: cid 'truenas' not copied (reservations match on MAC)
- `dhcp reservation client id`: lan ubuntu-server: cid 'pxe-server' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 docker-registry: cid 'docker-registry' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 k8s-master: cid 'k8s-master' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 k8s-node2: cid 'k8s-node2' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 k8s-node3: cid 'k8s-node3' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 k8s-node4: cid 'k8s-node4' not copied (reservations match on MAC)
- `dhcp reservation client id`: opt1 k8s-node5: cid 'k8s-node5' not copied (reservations match on MAC)
- `unbound sslcertref`: a certificate is referenced but the DNS-over-TLS listener is off; not ported
- `installedpackages/frrbgp`: FRR BGP: configured but not running; not ported (decision 7)
- `installedpackages/frrbgpneighbors`: FRR BGP neighbors: not ported (decision 7)
- `installedpackages/frrglobalroutemaps`: FRR route maps: not ported (decision 7)
- `installedpackages/openbgpd`: stale OpenBGPD section: not ported
- `installedpackages/freeradius`: FreeRADIUS: not ported (decision 7)
- `installedpackages/freeradiussettings`: FreeRADIUS: not ported (decision 7)
- `installedpackages/freeradiusclients`: FreeRADIUS: not ported (decision 7)
- `installedpackages/freeradiusinterfaces`: FreeRADIUS: not ported (decision 7)
- `installedpackages/freeradiuseapconf`: FreeRADIUS: not ported (decision 7)
- `installedpackages/miniupnpd`: UPnP/NAT-PMP: enabled in config, not running; not ported (decision 7)
- `installedpackages/snortglobal`: Snort: replaced by Suricata, configured fresh (decision 8); rule sets and suppress lists do not carry over
- `installedpackages/snortsync`: Snort XMLRPC sync: not ported
- `installedpackages/shellcmdsettings`: earlyshellcmd 'service wireguardd start': pfSense WireGuard package detail; OPNsense starts WireGuard itself
- `system/acb`: Netgate AutoConfigBackup: not ported (decision 7); daily backup copies /conf/config.xml
- `system/authserver`: RADIUS auth server 'pfsense-radius' to 127.0.0.1: not ported with FreeRADIUS
- `system/user`: users admin, emo: not ported; root password hash and SSH keys come from Vault via the bootstrap config
- `system/group`: groups all, admins: OPNsense has its own admins group
- `cert / ca`: 2 certs ('webConfigurator default', FreeRADIUS server) and 1 CA (FreeRADIUS CA): not ported; OPNsense makes its own GUI cert
- `cron`: 16 entries, all pfSense system or package jobs (bogons, Snort, RESTAPI cache, ACB upload, periodic); none custom
- `snmpd`: community set but SNMP disabled; not ported
- `dhcrelay6`: DHCPv6 relay on lan, not enabled; not ported
- `system/pkg_repo_conf_path, already_run_config_upgrade, widgets, rrd, revision, diag`: pfSense internals with no OPNsense meaning
- `filter/separator, nat/separator`: GUI separators only
- `REST API package (pfSense-pkg-RESTAPI)`: Homepage widget moves to OPNsense's own API (plan, dependents)
- `system/dnsserver gateways, dns1host/dns2host`: carried into unbound.yml forwarding (TLS hostnames) and misc.yml; check OPNsense's System > General mapping
- `system/webgui ssl-certref, webguicss, logincss, dashboardcolumns, loginshowhost, roaming`: cosmetic or pfSense-specific GUI settings

## Secrets needed (names only, none in these files)

- OPNsense root password hash (bootstrap config.xml)
- OPNsense API key and secret (bootstrap config.xml, then the playbook)
- SSH authorized key for root (bootstrap config.xml)
- CrowdSec bouncer key from LAPI (os-crowdsec)
- WireGuard private key of tun_wg0 (reuse pfSense's, decision 13)
- Tailscale/Headscale pre-auth key for registering the node (single-use, from Headscale)

## Ambiguous or worth a second look

- filter rule 1775855648 (IPv6 WireGuard site-to-site) carries associated-rule-id 'pass', which only has meaning on a NAT rule. Ignored.
- filter rule 1776118561 (Allow all WireGuard VPN traffic) carries associated-rule-id 'pass', which only has meaning on a NAT rule. Ignored.
- Gateway k8s_master_gw (10.0.20.100 on opt1) is not used by any route or rule in config.xml. Ported as-is; it may be droppable.
- port forward wan:51820 (no description): pfSense's linked filter rule 1743809095 passes to k8s_shared_lb:51820, but the forward targets k8s_wireguard_lb:51820. The rule was edited out of step with the forward; the WAN pass-all rule admits the traffic either way. OPNsense's linked rule will follow the forward.
- port forward wan:443 (https): pfSense's linked filter rule 1621023633 passes to nginx:443, but the forward targets traefik_lb:443. The rule was edited out of step with the forward; the WAN pass-all rule admits the traffic either way. OPNsense's linked rule will follow the forward.
- port forward wan:80 (http): pfSense's linked filter rule 1621023661 passes to nginx:80, but the forward targets traefik_lb:80. The rule was edited out of step with the forward; the WAN pass-all rule admits the traffic either way. OPNsense's linked rule will follow the forward.
- port forward wan:587 (smtps submission): linked filter rule 1621167654 referenced the undefined 'mailserver' alias and was dropped; the forward keeps associated_rule: linked, so OPNsense creates a correct pass rule to the target. Today that traffic is admitted only by the WAN pass-all rule.
- port forward wan:993 (imaps): linked filter rule 1621028916 referenced the undefined 'mailserver' alias and was dropped; the forward keeps associated_rule: linked, so OPNsense creates a correct pass rule to the target. Today that traffic is admitted only by the WAN pass-all rule.
- port forward wan:465 (smtps): linked filter rule 1621028981 referenced the undefined 'mailserver' alias and was dropped; the forward keeps associated_rule: linked, so OPNsense creates a correct pass rule to the target. Today that traffic is admitted only by the WAN pass-all rule.
- port forward wan:25 (no description): linked filter rule 1673734240 referenced the undefined 'mailserver' alias and was dropped; the forward keeps associated_rule: linked, so OPNsense creates a correct pass rule to the target. Today that traffic is admitted only by the WAN pass-all rule.
- radvd wan: config.xml has no RA interval, so live pfSense uses its 200-600 s default, but scripts/pfsense-sofia-lan-ula-ra.php sets 10/30 s (Matter devices sleep and miss slow RAs). The YAML follows the script (10/30). Either the script was not re-run after a later save, or its interval keys were dropped by a GUI save.
- unbound private_domains / insecure_domains are inferred from how pfSense's unbound.inc treats domain overrides; I did not read the live /var/unbound/unbound.conf (only config.xml was in scope).
- ntp: pfSense's server is 2.pfsense.pool.ntp.org. Kept as written; OPNsense's default pool (0-3.opnsense.pool.ntp.org) is an alternative. config.xml has no <ntpd> section, so interfaces (all) and restrictions (none set) are pfSense's defaults.
- haproxy: none of the six retired ipv6_* frontends is present in config.xml, so nothing was omitted on that account.
- haproxy: the mail frontends store extaddr '10.0.20.1' (a literal, not one of pfSense's named choices). The fact sheet says the live haproxy.cfg binds them on '*'. The YAML binds them to {{ fw.opt1 }}, which covers the WAN port forwards (they target 10.0.20.1). Confirm whether anything reaches 25/465/587/993 on another firewall address.
- haproxy internal_https_443: the SNI ACL still matches pfsense.viktorbarzin.lan/.me and sends it to the GUI on 127.0.0.1:8443. Kept as-is; it probably wants opnsense.viktorbarzin.* at cutover.
- syslog: pfSense sends firewall logs only, to 10.0.20.200:30514 (the CrowdSec NodePort). The plan (decision 10) sends all logs to Alloy at 10.0.20.208 as well; the YAML records pfSense's target only.
- NAT port forwards: config.xml has 24 enabled forwards (27 total, 3 disabled); the plan and fact sheet say 23. After dropping the port-143 forward to 'mailserver' the YAML has 23 enabled, which matches the plan's figure.
- filter rule 1775855648 (IPv6 WireGuard site-to-site) passes to 2001:470:6e:43d::2, the firewall's own HE tunnel address. It is production-only (opt3) and the same in both profiles, so it stays a literal; it is not in literal_map.
- WireGuard addresses 10.3.2.1/24 and 10.3.0.1/32 (the opt2 tunnel) and the Unbound ACL for 10.3.0.1/32 stay literal: they exist only in production and do not change between profiles.
- Rules on the 'WireGuard' interface group are marked profile: production as well as opt2/opt3, since the group has no member without the tunnel. The 'WireGuard' and 'Tailscale' group names are pfSense's; OPNsense's plugins name their interfaces/groups differently (wireguard, tailscale), so the playbook has to map them.
- The two Tailscale filter rules and several outbound NAT rules store a CIDR in <network> (100.64.0.0/10, 10.0.30.0/24, 192.168.1.0/24); pfSense's GUI would store those under <address>. They are written as address: <cidr>.
- Outbound NAT rules with no <ipprotocol> are written as inet46, reading pfSense's empty value as 'any'. The (self) -> 10.0.20.200:53 rule translates to an IPv4 address, so in practice it is IPv4 only.
- Outbound NAT on opt1: source (self) to 10.0.20.200/32 udp/53 is translated to 10.0.20.200 port 30054, i.e. the firewall's own DNS queries to the shared LB leave with the LB's address as source. 10.0.20.200 is not a firewall address, so it stays literal (the plan's review table lists it among the literals; nothing profile-specific in it). Worth confirming it is still wanted.
- Outbound NAT on opt3 (source any, inet, to opt3ip) has no effect: opt3 has no IPv4 address. Ported as-is.
- The eight 'Auto created rule' outbound entries are pfSense's automatic rules copied in when hybrid mode was chosen. OPNsense's automatic rules produce the same masquerade for its own interface networks; the playbook could skip them in hybrid mode.
- radvd lan is stateless_dhcp (O flag set) but no DHCPv6 server runs on lan, so clients get DNS only from RDNSS. OPNsense 'stateless' behaves the same way.
- dhcp opt4: pfSense offers the firewall address as DNS on the CCTV segment, but Unbound does not listen on opt4 and the opt4 rule allows only NTP, so that DNS server is unreachable today. Carried over unchanged.
- unbound register_dhcp_leases is set, but pfSense 2.7.2's Kea backend does not register leases in Unbound, so it has no effect today. Enabling the OPNsense equivalent with Kea would be a behaviour change.
- HTML entities in descriptions were decoded and em/en dashes and arrows became '-' and '->'.
- Port ranges written a:b in pfSense (49152:49252) are normalised to a-b.
- sysctl kern.ipc.maxsockbuf=16777216 was set by the FRR package, which is not ported. Kept in misc.yml; it may not be needed on OPNsense.
- misc.yml webgui.alt_hostnames_needed and tailscale.yml profiles come from the plan (review table, decision 12), not from config.xml.

## Files

- `addresses.yml`
- `aliases.yml`
- `gateways.yml`
- `routes.yml`
- `filter.yml`
- `nat_port_forwards.yml`
- `nat_outbound.yml`
- `dhcp.yml`
- `radvd.yml`
- `unbound.yml`
- `ntp.yml`
- `wireguard.yml`
- `tailscale.yml`
- `haproxy.yml`
- `netflow.yml`
- `syslog.yml`
- `misc.yml`
- `REPORT.md`
