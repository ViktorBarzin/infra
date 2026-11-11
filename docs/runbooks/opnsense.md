# OPNsense edge firewall

OPNsense is the edge firewall since the cutover on 2026-11-10 (ADR-0038, plan `docs/plans/2026-11-03-opnsense-migration.md`), on pfSense's addresses and MACs (the **Production profile**). pfSense (VM 101) is kept stopped with its NICs link-down as the rollback, with no removal date (Viktor, 2026-11-10); see Cutover.

| | |
|---|---|
| VM | 100 `opnsense` on the Proxmox host, 8 vCPU, 8 GB, 32 GB `local-lvm`, `stacks/opnsense` (Terraform, bpg/proxmox) |
| Version | OPNsense 26.7.8, plugins os-crowdsec, os-haproxy, os-tailscale, os-node_exporter, os-squid (installed by the playbook's `squid` area) |
| Addresses | WAN 192.168.1.2 and fdfe:e989:d3ce:1::1, VLAN 10 10.0.10.1 and 2001:470:6f:43d::1, VLAN 20 10.0.20.1 and 2001:470:5a7f:20::1, VLAN 30 10.0.30.1, WireGuard 10.3.2.1, HE tunnel 2001:470:6e:43d::2, tailnet 100.64.0.17 (staging used .250/.2, kept in `addresses.yml`) |
| GUI | https://opnsense.viktorbarzin.me (Authentik, then OPNsense login as root); on the LAN `https://10.0.10.1:8443` |
| SSH | `root@10.0.10.1` with the Ansible key (Vault `secret/opnsense ssh_private_key`, `~/.ssh/opnsense/id_ed25519`) or any key in `authorized_keys.yml` (pfSense's, carried over); root's shell is csh, so pipe scripts to `/bin/sh -s` |
| Serial console | `qm terminal 100` on the Proxmox host (login prompt on serial since the second reboot after the console change) |
| Secrets | Vault `secret/opnsense`: `root_password`, `api_key`, `api_secret`, `ssh_*`, `pve_api_token`, `crowdsec_bouncer_key`, `squid_ca_intermediate_key` (the Squid interception intermediate, phase 5 of the network IDS plan), `tailscale_preauth_key`, `wireguard_tun_wg0_private_key` and `outbound_ssh_private_key` (both pfSense's) |
| Config source | `playbooks/files/opnsense/*.yml` (converted from pfSense once, now edited by hand), applied by `playbooks/opnsense.yml` |

## Everyday

```sh
cd ~/code/infra
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --check --diff   # changed=0 when nothing was edited
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true [--tags filter,nat]
scripts/opnsense-verify --host 10.0.10.1 --profile production
python3 -m pytest playbooks/filter_plugins/test_opnsense.py -q
```

Each area is tagged (aliases, gateways, routes, filter, nat, unbound, ntp, kea, radvd, netflow, syslog, node_exporter, suricata, netsec_eve, squid, haproxy, users, crowdsec, tailscale). After every area the playbook checks that SSH and the API answer, that no DHCP/RA daemon runs and that there is no gif or wg device in staging. The production profile refuses to run without `-e opnsense_allow_production=true`.

Monitoring: Prometheus job `opnsense-node` (10.0.20.1:9100, `ScrapeTargetDown`; `EdgeFirewallVMDown` on qemu/100), Loki `{job="syslog", host="opnsense"}` (filter log, Suricata EVE, system), daily `config.xml` copy by `scripts/daily-backup.sh` to `/mnt/backup/opnsense/`.

## Suricata tuning

Suricata runs in IDS mode on lan (VLAN 10, `vtnet1`) and opt1 (VLAN 20, `vtnet2`) only. WAN is not inspected (2026-11-10): every routed flow also crossed VLAN 10 or 20 and alerted twice, and on WAN it showed the firewall's address instead of the inside host. The HE tunnel's IPv6 is still seen as it enters VLAN 20.

Signatures that fire only on our own services are turned off in `playbooks/tasks/opnsense/suricata.yml` (`opn_ids_disabled_sids`, each with its reason): the `files.pythonhosted.org` lookup (pip) and BitTorrent (qBittorrent in servarr). The STUN, cloudflared, GitHub release, Tailscale control and `pages.dev` signatures that used to be listed lived in `emerging-info`, which is now off as a whole (below). The playbook asserts each listed SID is installed, so a renamed or retired rule fails the run. Add a SID only with its reason; never turn off a rule that names a threat (`ET COMPROMISED`, `ET DROP`, `ET CINS`, `ET SCAN`, abuse.ch).

Effect, measured 2026-11-10: about 400 alerts per 5 minutes before, 16 after (plus two tests). What stays, on purpose:

| Source | Signatures | Why it stays |
|---|---|---|
| qBittorrent tracker lookups (`*.pw`, `*.tk`, `*.to`) | `ET DNS ... Likely Hostile` | the rule is a real malware signal for other names (the `ET DYN_DNS` ones, Valchedrym's DDNS name included, went with `emerging-dyn_dns` on 2026-11-11) |
| tv app sources (`vavoo.to`, `*.top`) | `ET DNS Query for .to TLD`, `*.top` | same |
| outside scanners and listed hosts | `ET DROP Dshield`, `ET DROP Spamhaus`, `ET CINS`, `ET COMPROMISED`, `SSH-2.0-Go` | real attacks; what CrowdSec will ban |

Count by signature and interface:

```
homelab logs query 'sum by (sig, iface) (count_over_time({job="syslog", host="opnsense"} |= "event_type" |= "alert" | regexp `"in_iface":"(?P<iface>[^"]+)".*"signature":"(?P<sig>[^"]+)"` [1h]))' --since 1h
```

Test that detection works: `curl -s -A BlackSun http://example.com/ -o /dev/null` from the devvm raises `ET USER_AGENTS Suspicious User Agent (BlackSun)` (SID 2008983, `emerging-user_agents`) on `vtnet1` within a minute. The earlier `dig icanhazip.com` test used an `emerging-info` rule, off since 2026-11-11; `testmynids.org` no longer works either, the domain is parked.

### ET Open categories left off

Since 2026-11-11 (Viktor) the playbook enables every `ET open/*` ruleset except the 13 in `opn_ids_excluded`, each with its reason: `dyn_dns`, `info`, `phishing`, `exploit_kit`, `hunting`, `mobile_malware`, `adware_pup`, `web_client`, `retired`, `activex`, `scada`, `chat`, `games`. They target browsing people, phones and desktops, none of which sit behind this firewall, or they are informational. That took the active rules from 63,816 to 43,082. The client-side ones come back if the home LAN moves behind OPNsense (`docs/plans/2026-11-10-network-ids.md`, open question 1). The playbook asserts every listed category still exists.

`ids/service/update_rules` rewrites the rule files but the running Suricata keeps the rules it loaded: on 2026-11-11 the left-off categories kept firing until `ids/service/reload_rules`. The playbook now reloads after every update. A live reload builds the new detection engine beside the old one: RSS went from 4.1 GB to 5.1 GB for about 30 seconds and free memory fell to 180 MB with no swap. Since 2026-11-11 the VM has OPNsense's 2 GB swap file (`tasks/opnsense/swap.yml`), so reloads and restarts need no quiet hour (Viktor: resilience over time-of-day rules): a live reload at 06:00 local dipped to 156 MB free, put 160 MB in swap for a moment, and DNS answered all 90 one-second probes. `OPNsenseMemoryLow` and `OPNsenseSwapHeavy` watch it.

### Capture: buffer and stream bypass

Suricata's capture missed 4.4% of the packets it should have inspected (blind spots; traffic itself is not affected in IDS mode), in bursts of up to 26% per 5 minutes. Two changes on 2026-11-11, in `files/opnsense/suricata-netsec-capture.yaml` and the tunable task:

- **Capture buffer**: `net.bpf.maxbufsize` 512 KB to 32 MB (System > Settings > Tunables, from the playbook) and `pcap: buffer-size: 33554432` for `vtnet1` and `vtnet2`. OPNsense's template has no `pcap:` section, so the conf.d list adds it. `netstat -B` shows the store buffer of Suricata's descriptors filling past 2.5 MB, which the old cap could not hold.
- **Stream bypass**: `stream.bypass: yes` with the stock 1 MB reassembly depth, so the tail of camera video, tv streams and NFS skips detection (`flow_bypassed.local_pkts` in `stats.log`; 28% of packets in the first 10 minutes). The file restates the template's whole `stream:` section; the playbook refuses to install it when the template's section fingerprint changes and asserts the loaded values with `suricata --dump-config`.

What limits it now: OPNsense's pcap mode runs one worker thread per interface (`W#01-vtnet2`), and VLAN 20 carries about 13,000 packets a second at night, most of it video (Frigate pulling RTSP on node1, tv app streams) and NFS. That thread reached 88% of a core in a 6-second sample during the warm-up after a restart.

Counters: `netsec_suricata_capture_kernel_packets_total`, `netsec_suricata_capture_kernel_drops_total` and `netsec_suricata_flow_bypassed_packets_total` from `netsec-squid-metrics` (cron on OPNsense, `stats.log` every 5 minutes). Alert `SuricataCaptureDrops`: more than 1% missed over an hour.

Measured after the change (5-minute `stats.log` intervals, local time, 2026-11-11; Suricata restarted 01:58, live rule reload 02:19:09 to 02:19:42):

| Interval ending | Packets | Missed | Bypassed |
|---|---|---|---|
| 02:04, 02:09 | 4.0M, 3.7M | 3.5%, 4.0% | 28%, 27% |
| 02:14, 02:19 | 4.1M, 3.1M | 0.04%, 0% | 37%, 34% |
| 02:24 | 6.5M | 15.9% | 18% |
| 02:29 | 3.1M | 0.17% | 32% |
| 02:34 to 03:19, ten intervals | 2.9M to 7.5M | 0% each | 27% to 72% |

Before: 82 of 1,982 intervals above 1%, peaks of 21% and 26%, a floor around 0.03%. The two misses left are Suricata itself: the first ten minutes after a start (warming flow and stream state) and the minutes around a live rule reload (the 02:24 interval held the reload and no bigger traffic than the rest; a 3.5 GB NFS write from node3 to the Proxmox host at 02:26, 55,000 packets a second, cost 0.17% in the next interval). Since the kernel capture filter (NFS and devvm-to-Proxmox SSH excluded) the misses outside those minutes are zero. Memory: Suricata's RSS went from 4,882 MiB to 3,801 MiB.


A second EVE file, `eve-meta.json` (alert, DNS responses, TLS, HTTP), feeds ClickHouse `netsec.eve`; it comes from a `conf.d` file that restates the stock outputs, area `netsec_eve` (`docs/architecture/network-security-monitoring.md`, phase 2). Suricata allows one `anomaly` logger only, so a second output with `anomaly` stops it from starting.

`ids/service/reconfigure` blocks while Suricata restarts with its rules (about 83,000 installed, 43,000 active), longer than the `uri` module's 30 second default, so that task has a 600 second timeout.

Two trusted bulk flows never reach Suricata (kernel `bpf-filter` in `playbooks/files/opnsense/suricata-netsec-capture.yaml`, Viktor 2026-11-11): NFS to the Proxmox host (192.168.1.127, port 2049) and SSH between the devvm and the Proxmox host. Local bypass still copies every packet into Suricata before skipping it, and their bursts overflowed even the 32 MB buffer (0.46% missed per hour, e.g. 1.4M NFS packets and a 1.6 GB devvm-to-Proxmox SSH copy at 03:20 local). SSH to the host from anywhere else stays inspected.

## Squid (decryption for opted-in machines)

os-squid decrypts HTTP and HTTPS only for the machines in alias `opted_in`, which is empty: the redirects in `nat_port_forwards.yml` match that alias alone, and Squid listens only on loopback (3128, 3129, and a plain 3130). The `squid` area installs the plugin, imports the interception root (certificate only) and intermediate (with its key from Vault) into System > Trust, writes the settings, the JSON access log (`/usr/local/etc/squid/post-auth/netsec-log.conf`), its rotation and syslog-ng tail, and the metrics cron. Opting a machine in, the no-bump list and CA renewal: `docs/runbooks/network-ids.md`, "Decryption (phase 5)".

- The no-bump list is `opn_squid_nobump` in `tasks/opnsense/squid.yml`; apply `--tags squid` after editing it.
- Squid logs `ERROR: No forward-proxy ports configured` when it has only intercept ports; the loopback port 3130 in `netsec-log.conf` is there for that.
- Squid's `%"` log code escapes a value but does not add quotes; `netsec-log.conf` wraps each such field in quotes itself.

## Rebuild from nothing

1. `cd stacks/opnsense && ../../scripts/tg apply`: uploads the nano image (signed checksum list, `scripts/opnsense-image-upload`) and creates VM 100 with every NIC disconnected (`local.nics`).
2. `scripts/opnsense-bootstrap-config.py --out /tmp/x/config.xml`, then write it over the serial console with `scripts/opnsense-bootstrap-serial` (usage in its docstring). The box reboots into the staging addresses.
3. Gate before any NIC connects: over serial or after connecting VLAN 10 only, check the staging addresses, `pgrep -l 'dnsmasq|kea|radvd'` prints nothing, `ifconfig -l` has no gif/wg, no global IPv6. Then flip `disconnected` to false in `local.nics` one NIC at a time: VLAN 10, VLAN 20 and 30, WAN last (after checking 192.168.1.250 is unused).
4. Update and plugins: `configctl firmware update` (reboots), then `configctl firmware install os-crowdsec` and the other three.
5. The two console settings need two reboots to reach a serial login: OPNsense regenerates `loader.conf` during boot.
6. `ansible-playbook ... playbooks/opnsense.yml`, then `scripts/opnsense-verify`.
7. Tailscale: create a one-time key (`headscale preauthkeys create --user 1 --expiration 1h`), store it as `tailscale_preauth_key`, run `--tags tailscale`. The plugin passes the key only when a state file exists without a profile, so the first start shows a login URL; `configctl tailscale restart` then logs in.
8. CrowdSec: `cscli bouncers add <name> -k <key>` on the cluster LAPI, store the key as `crowdsec_bouncer_key`, run `--tags crowdsec`.

## Production config and the dry run

The production config is the staging box's `config.xml` plus two layers, built and tested on an isolated clone before the swap:

1. `scripts/opnsense-production-config.py --in staging.xml --out production.xml` rewrites what the API cannot set: the .1 and static IPv6 addresses, the WireGuard (opt2 on `wg0`), HE (opt3 on `gif0`) and Tailscale (opt5 on `tailscale0`) assignments, IPv6 on, the DNS rebind check off (as on pfSense) and pfSense's resolvers. Tests: `python3 -m pytest scripts/opnsense_production_config_test.py -q`.
2. `ansible-playbook ... playbooks/opnsense.yml -e opnsense_profile=production -e opnsense_allow_production=true` adds the HE gif device, the WireGuard instance with pfSense's key (Vault `wireguard_tun_wg0_private_key`) and four peers, the production gateways, routes, rules, NAT, Kea, radvd and Tailscale routes.

Dry run (2026-11-10): VM 100 was cloned to VM 199 with every NIC on `vmbr99`, a bridge with no physical port, reached only from the network namespace `opndry` on the Proxmox host (10.0.10.250 on VLAN 10). Ansible and `scripts/opnsense-verify --isolated --api-base ... --ssh-option ...` reached it through `ProxyCommand=ssh root@192.168.1.127 ip netns exec opndry nc %h %p` with `HostKeyAlias=10.0.10.2`, so nothing could land on pfSense's real .1 addresses. Result: Ansible idempotent, 30/30 production checks after a cold boot, Kea offered a lease, router advertisements gave a SLAAC address and default route, Unbound answered. The clone's `config.xml` is the swap's production config.

Kea leases were not copied: every lease pfSense held on 2026-11-10 belonged to a reserved host.

## Cutover (VM swap)

`scripts/opnsense-cutover` on the Proxmox host does the swap with a dead-man revert. It must run on the host, never from a VM behind the firewall: every VM loses the network for a few minutes. It runs as transient systemd units, so a dropped SSH session does not stop it. Break-glass from outside: `ssh -p 52222 -i ~/.ssh/breakglass_ed25519 root@viktorbarzin.ddns.net` (the TP-Link forwards it to the host directly).

1. Claim `host:pfsense`, `host:opnsense`, `host:pve`. Approve pfSense's routes on the OPNsense Headscale node in advance (`headscale nodes approve-routes -i <id> -r <routes>`); a route is served only once announced too, so this changes nothing before the swap.
2. Copy the script and the production `config.xml` to `/root/opnsense-cutover/` on the host, `sha256sum config.xml > config.xml.sha256`.
3. `opnsense-cutover prepare`: shuts VM 100 down, takes the offline snapshot `pre-cutover`, starts it again, pins its host key, records both VMs' MACs. pfSense serves throughout.
4. `opnsense-cutover swap 10`: arms the revert (rollback in 10 minutes unless confirmed), installs the config on VM 100, powers it off and shuts pfSense down, gives VM 100 pfSense's four MACs (TP-Link forwards, ARP and the EUI-64 link-local addresses stay valid), starts it and runs health checks. `/root/opnsense-cutover/log` has every step.
5. From a session that has come back: `opnsense-cutover extend 20` keeps the revert armed while the checks below run, then `opnsense-cutover confirm`. Confirm sets `link_down` on pfSense's NICs (it still has the same MACs) and deletes the copied `config.xml`.
6. Boot order (`playbooks/reboot-boot-order.yml`: 100 order 1, 101 disabled), the dependents below, Terraform plan of `stacks/opnsense` (the MACs are pinned there), `scripts/opnsense-verify --host 10.0.10.1 --profile production`.

Rollback, for as long as VM 101 and the `pre-cutover` snapshot are kept: `opnsense-cutover rollback` (runs as its own unit). It stops VM 100 by any means, brings pfSense back first (links up, onboot, start), then restores VM 100's `pre-cutover` snapshot (staging config, own MACs) and leaves it stopped. If the snapshot restore fails it keeps VM 100 off the network (`link_down`, onboot 0). pfSense itself is never changed.

Tested on throwaway VMs (2026-11-10): automatic revert, confirm, extend, and rollback after confirm. Two blind reviews of the script and of the production config found the issues fixed before the real run (rollback ordering, a manual rollback dying with its session, pfSense's duplicate MACs, the CrowdSec bouncer blocking both directions, NAT for the WireGuard site LANs, the KMS rate limits, DNS rebind protection).

### Dependents (changed at the cutover)

Most kept working because OPNsense took pfSense's addresses and MACs: CoreDNS's forwarder, Traefik's PROXY trust of 10.0.20.1, backup-mx's relay, Headscale ACLs (by address and tag), the bastion, Technitium's zone transfers to 10.0.20.1, rpi-sofia's routes, the TP-Link forwards. Changed with the cutover commit:

| Dependent | Change |
|---|---|
| `scripts/daily-backup.sh` (hand-copied to `/usr/local/bin/daily-backup` on the host) | pfSense step removed; OPNsense step on 10.0.20.1 pushes `job="opnsense-backup"` (`OpnsenseBackupStale`). The host's `known_hosts` for 10.0.20.1 now holds OPNsense's key |
| Prometheus | `opnsense-node` on 10.0.20.1:9100; `PfSenseVMDown` became `EdgeFirewallVMDown` on qemu/100; Tailscale subnet-router alert names 100.64.0.17 |
| `stacks/reverse-proxy` | `opnsense` on 10.0.20.1 with the Homepage link; `pfsense.viktorbarzin.me` retired |
| `stacks/headscale` subnet-router probe | pings 100.64.0.17; node 399 tagged `tag:infra`, renamed `opnsense`, pfSense's routes approved |
| `stacks/phpipam` | `fetch_sources.sh` logs in as root@10.0.20.1 and reads OPNsense's Kea and `wg0`; device entry renamed |
| `stacks/crowdsec` `crowdsec-lapi-edge` | source range 10.0.20.1 only |
| `playbooks/reboot-boot-order.yml` | 100 order 1, 101 disabled |
| `stacks/opnsense` | pfSense's MACs pinned in `local.nics` |

## Gotchas found while building it

- The nano image's importer prompt waits only a few seconds at boot; the serial script writes `config.xml` from a root shell instead. FreeBSD's tty takes at most 255 bytes per input line, so the base64 goes over in 160-byte pieces.
- The release `config.xml.sample` has no serial console settings, and a console change needs two reboots to take effect.
- PVE requires `Sys.Modify` on `/` to set a VM's `startup`, so boot order lives in `reboot-boot-order.yml`, not Terraform.
- The user API stores `authorizedkeys` but does not rewrite `/root/.ssh/authorized_keys`; `tasks/opnsense/users.yml` calls `local_user_set()`.
- Syslog to Alloy over UDP never arrived from this box (one-off UDP packets did); it uses TCP.
- A placeholder in the YAML that the profile cannot fill now fails the run (`opn_render`), because an empty value reads as "any" in a rule.
- Staging box only: the Proxmox host reaches 10.0.20.2 through pfSense, while the box answers straight out of its WAN leg, so pfSense saw one direction and stalled bulk uploads from the host (small commands passed). The cutover staged `config.xml.production` from the devvm on VLAN 10 instead. Production has no such middlebox: the host talks to the firewall itself.
- On the first boot after the swap HAProxy did not start: the generated `haproxy.conf` on disk was most likely still the staging one, binding 10.0.20.2. `configctl haproxy start` fixed it, and `rc.syshook.d/start/99-haproxy-ensure` (`tasks/opnsense/haproxy.yml`) now starts it at the end of boot if the early start fails. A later reboot started it normally.
- mx2 (Oracle) cannot test inbound SMTP: Oracle blocks outbound port 25. Use mladost3-openwrt: `(sleep 4; echo QUIT) | nc 176.12.22.76 25`.
- The CrowdSec plugin's own rules block in and out on every interface; they are off, and `filter.yml` blocks the bouncer's tables inbound on WAN and the HE tunnel only, with the bouncer limited to `origins: [crowdsec, CAPI, cscli]` (`tasks/opnsense/crowdsec.yml`).
- HTTP/3 from outside: mx2's curl has no HTTP/3 and the box has no pip, so download the `aioquic` wheels on the devvm (`pip download --only-binary=:all: --platform manylinux2014_x86_64 --python-version 3.12 aioquic`), unzip them into `/tmp` on mx2 and run a small aioquic client with `PYTHONPATH`. Traefik's access log shows `RequestProtocol` HTTP/3.0.

## CrowdSec agent, Homepage, Tailscale node

- **CrowdSec agent** (since 2026-11-10): the box's agent reads the filter, GUI and audit logs (collections `firewallservices/pf`, `crowdsecurity/opnsense`, `opnsense-gui`, `sshd`) and pushes alerts to the cluster LAPI at 10.0.20.210:8080 as machine `opnsense-edge` (Vault `secret/opnsense crowdsec_agent_password`). Its local LAPI stays off. The LAPI's centralized allowlist `trusted-infra` (`stacks/crowdsec`, `lapi_allowlist`) keeps our own IPv4 and IPv6 space from being banned by any agent; the CronJob `crowdsec-lapi-reconcile` (every 15 minutes) keeps it and the machine in step. Only block lines feed the port-scan scenario; pass lines show as unparsed in `cscli metrics`, which is expected. Check: `ssh root@10.0.10.1 'cscli lapi status'`, and on the LAPI `cscli alerts list -m opnsense-edge`.
- **Homepage widget**: user `homepage` (privileges Diagnostics: System Activity and Reporting: Traffic only, scrambled password) with one API key in Vault `secret/opnsense homepage_api_key` / `homepage_api_secret`, created by `--tags users`; the key gets 403 on everything else. To rotate: delete the key in the GUI, remove the two Vault fields, rerun `--tags users`, then let CI apply `stacks/reverse-proxy`.
- **Tailscale node 399** has key expiry disabled (`headscale nodes expire -i 399 --disable`), like pfSense's node had. Without `--disable` that command expires the node at once.
