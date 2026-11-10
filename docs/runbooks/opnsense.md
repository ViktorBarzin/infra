# OPNsense edge firewall

OPNsense is the edge firewall since the cutover on 2026-11-10 (ADR-0038, plan `docs/plans/2026-11-03-opnsense-migration.md`), on pfSense's addresses and MACs (the **Production profile**). pfSense (VM 101) is kept stopped with its NICs link-down as the rollback, with no removal date (Viktor, 2026-11-10); see Cutover.

| | |
|---|---|
| VM | 100 `opnsense` on the Proxmox host, 8 vCPU, 8 GB, 32 GB `local-lvm`, `stacks/opnsense` (Terraform, bpg/proxmox) |
| Version | OPNsense 26.7.8, plugins os-crowdsec, os-haproxy, os-tailscale, os-node_exporter |
| Addresses | WAN 192.168.1.2 and fdfe:e989:d3ce:1::1, VLAN 10 10.0.10.1 and 2001:470:6f:43d::1, VLAN 20 10.0.20.1 and 2001:470:5a7f:20::1, VLAN 30 10.0.30.1, WireGuard 10.3.2.1, HE tunnel 2001:470:6e:43d::2, tailnet 100.64.0.17 (staging used .250/.2, kept in `addresses.yml`) |
| GUI | https://opnsense.viktorbarzin.me (Authentik, then OPNsense login as root); on the LAN `https://10.0.10.1:8443` |
| SSH | `root@10.0.10.1` with the Ansible key (Vault `secret/opnsense ssh_private_key`, `~/.ssh/opnsense/id_ed25519`) or any key in `authorized_keys.yml` (pfSense's, carried over); root's shell is csh, so pipe scripts to `/bin/sh -s` |
| Serial console | `qm terminal 100` on the Proxmox host (login prompt on serial since the second reboot after the console change) |
| Secrets | Vault `secret/opnsense`: `root_password`, `api_key`, `api_secret`, `ssh_*`, `pve_api_token`, `crowdsec_bouncer_key`, `tailscale_preauth_key`, `wireguard_tun_wg0_private_key` and `outbound_ssh_private_key` (both pfSense's) |
| Config source | `playbooks/files/opnsense/*.yml` (converted from pfSense once, now edited by hand), applied by `playbooks/opnsense.yml` |

## Everyday

```sh
cd ~/code/infra
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --check --diff   # changed=0 when nothing was edited
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true [--tags filter,nat]
scripts/opnsense-verify --host 10.0.10.1 --profile production
python3 -m pytest playbooks/filter_plugins/test_opnsense.py -q
```

Each area is tagged (aliases, gateways, routes, filter, nat, unbound, ntp, kea, radvd, netflow, syslog, node_exporter, suricata, haproxy, users, crowdsec, tailscale). After every area the playbook checks that SSH and the API answer, that no DHCP/RA daemon runs and that there is no gif or wg device in staging. The production profile refuses to run without `-e opnsense_allow_production=true`.

Monitoring: Prometheus job `opnsense-node` (10.0.20.1:9100, `ScrapeTargetDown`; `EdgeFirewallVMDown` on qemu/100), Loki `{job="syslog", host="opnsense"}` (filter log, Suricata EVE, system), daily `config.xml` copy by `scripts/daily-backup.sh` to `/mnt/backup/opnsense/`.

## Suricata tuning

Suricata runs in IDS mode on lan (VLAN 10, `vtnet1`) and opt1 (VLAN 20, `vtnet2`) only. WAN is not inspected (2026-11-10): every routed flow also crossed VLAN 10 or 20 and alerted twice, and on WAN it showed the firewall's address instead of the inside host. The HE tunnel's IPv6 is still seen as it enters VLAN 20.

Signatures that fire only on our own services are turned off in `playbooks/tasks/opnsense/suricata.yml` (`opn_ids_disabled_sids`, each with its reason): STUN (coturn, Matrix, Headscale DERP, WebRTC), cloudflared, GitHub release downloads, pip, Tailscale control lookups, `pages.dev` (tv app sources) and BitTorrent (qBittorrent in servarr). The playbook asserts each listed SID is installed, so a renamed or retired rule fails the run. Add a SID only with its reason; never turn off a rule that names a threat (`ET COMPROMISED`, `ET DROP`, `ET CINS`, `ET SCAN`, abuse.ch).

Effect, measured 2026-11-10: about 400 alerts per 5 minutes before, 16 after (plus two tests). What stays, on purpose:

| Source | Signatures | Why it stays |
|---|---|---|
| `valchedrym.ddns.net` lookups, about one a minute through CoreDNS (one Uptime Kuma ping monitor plus pods not yet attributed) | `ET DYN_DNS *.ddns .net` | the rule is a real malware signal for other names |
| qBittorrent tracker lookups (`*.pw`, `*.tk`, `*.to`, `farted.net`, `duckdns.org`) | `ET DNS ... Likely Hostile`, `ET DYN_DNS` | same |
| tv app sources (`vavoo.to`, `*.top`) | `ET DNS Query for .to TLD`, `*.top` | same |
| outside scanners and listed hosts | `ET DROP Dshield`, `ET DROP Spamhaus`, `ET CINS`, `ET COMPROMISED`, `SSH-2.0-Go` | real attacks; what CrowdSec will ban |

Count by signature and interface:

```
homelab logs query 'sum by (sig, iface) (count_over_time({job="syslog", host="opnsense"} |= "event_type" |= "alert" | regexp `"in_iface":"(?P<iface>[^"]+)".*"signature":"(?P<sig>[^"]+)"` [1h]))' --since 1h
```

Test that detection works: `dig icanhazip.com @10.0.10.1` from the devvm raises `ET INFO External IP Lookup Domain in DNS Lookup (icanhazip .com)` on `vtnet1` within a minute. `testmynids.org` no longer works: the domain is parked.

`ids/service/reconfigure` blocks while Suricata restarts with about 83,000 rules, longer than the `uri` module's 30 second default, so that task has a 600 second timeout.

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
