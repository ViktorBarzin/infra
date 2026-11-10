# OPNsense edge firewall

OPNsense replaces pfSense as the edge firewall (ADR-0038, plan `docs/plans/2026-11-03-opnsense-migration.md`). Until cutover it runs next to pfSense on spare addresses (the **Staging profile**); pfSense still carries all traffic.

| | |
|---|---|
| VM | 100 `opnsense` on the Proxmox host, 8 vCPU, 8 GB, 32 GB `local-lvm`, `stacks/opnsense` (Terraform, bpg/proxmox) |
| Version | OPNsense 26.7.8, plugins os-crowdsec, os-haproxy, os-tailscale, os-node_exporter |
| Staging addresses | WAN 192.168.1.250, VLAN 10 10.0.10.2, VLAN 20 10.0.20.2, VLAN 30 10.0.30.2; no IPv6 on the LAN NICs |
| GUI | https://opnsense.viktorbarzin.me (Authentik, then OPNsense login as root); on the LAN `https://10.0.10.2:8443` |
| SSH | `root@10.0.10.2`, key in Vault `secret/opnsense ssh_private_key` (`~/.ssh/opnsense/id_ed25519`); root's shell is csh, so pipe scripts to `/bin/sh -s` |
| Serial console | `qm terminal 100` on the Proxmox host (login prompt on serial since the second reboot after the console change) |
| Secrets | Vault `secret/opnsense`: `root_password`, `api_key`, `api_secret`, `ssh_*`, `pve_api_token`, `crowdsec_bouncer_key`, `tailscale_preauth_key` |
| Config source | `playbooks/files/opnsense/*.yml` (converted from pfSense once, now edited by hand), applied by `playbooks/opnsense.yml` |

## Everyday

```sh
cd ~/code/infra
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml --check --diff   # must be changed=0 when nothing was edited
ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml [--tags filter,nat]
scripts/opnsense-verify            # PASS/FAIL per check, plus what staging cannot test
python3 -m pytest playbooks/filter_plugins/test_opnsense.py -q
```

Each area is tagged (aliases, gateways, routes, filter, nat, unbound, ntp, kea, radvd, netflow, syslog, node_exporter, suricata, haproxy, users, crowdsec, tailscale). After every area the playbook checks that SSH and the API answer, that no DHCP/RA daemon runs and that there is no gif or wg device in staging. The production profile refuses to run without `-e opnsense_allow_production=true`.

Monitoring: Prometheus job `opnsense-node` (10.0.20.2:9100, `ScrapeTargetDown`), Loki `{job="syslog", host="opnsense"}` (filter log, Suricata EVE, system), daily `config.xml` copy by `scripts/daily-backup.sh` to `/mnt/backup/opnsense/`.

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

Rollback, any time in the two weeks: `opnsense-cutover rollback` (runs as its own unit). It stops VM 100 by any means, brings pfSense back first (links up, onboot, start), then restores VM 100's `pre-cutover` snapshot (staging config, own MACs) and leaves it stopped. If the snapshot restore fails it keeps VM 100 off the network (`link_down`, onboot 0). pfSense itself is never changed.

Tested on throwaway VMs (2026-11-10): automatic revert, confirm, extend, and rollback after confirm. Two blind reviews of the script and of the production config found the issues fixed before the real run (rollback ordering, a manual rollback dying with its session, pfSense's duplicate MACs, the CrowdSec bouncer blocking both directions, NAT for the WireGuard site LANs, the KMS rate limits, DNS rebind protection).

### Dependents

Most keep working because OPNsense takes pfSense's addresses: CoreDNS's forwarder, Traefik's PROXY trust of 10.0.20.1, backup-mx's relay, Headscale ACLs, bastion, Technitium (it accepts zone transfers from 10.0.20.1), rpi-sofia's routes. These change at cutover:

| Dependent | Change |
|---|---|
| `scripts/daily-backup.sh` | `OPNSENSE_HOST=10.0.20.1`, remove the pfSense step and its Pushgateway job (and the `Pfsense*Backup*` alerts) |
| Prometheus `opnsense-node` job | target 10.0.20.1:9100 |
| `stacks/reverse-proxy` `module "opnsense"` | `backend_ip = "10.0.20.1"`; retire `module "pfsense"` |
| Homepage widget | OPNsense widget (API key) instead of the pfSense REST package |
| phpIPAM import (`stacks/phpipam/files/fetch_sources.sh`) | read Kea leases from OPNsense (`/var/db/kea/`) instead of pfSense's paths |
| CrowdSec `crowdsec-lapi-edge` | drop 10.0.20.2 from the source ranges once staging is gone |
| gatus on mx2 | external checks of the WAN forwards and IPv6 through OPNsense |
| Docs | `docs/architecture/networking.md` and the pfSense runbooks |

## Gotchas found while building it

- The nano image's importer prompt waits only a few seconds at boot; the serial script writes `config.xml` from a root shell instead. FreeBSD's tty takes at most 255 bytes per input line, so the base64 goes over in 160-byte pieces.
- The release `config.xml.sample` has no serial console settings, and a console change needs two reboots to take effect.
- PVE requires `Sys.Modify` on `/` to set a VM's `startup`, so boot order lives in `reboot-boot-order.yml`, not Terraform.
- The user API stores `authorizedkeys` but does not rewrite `/root/.ssh/authorized_keys`; `tasks/opnsense/users.yml` calls `local_user_set()`.
- Syslog to Alloy over UDP never arrived from this box (one-off UDP packets did); it uses TCP.
- A placeholder in the YAML that the profile cannot fill now fails the run (`opn_render`), because an empty value reads as "any" in a rule.
