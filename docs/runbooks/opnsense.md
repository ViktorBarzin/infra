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

## Before cutover (not built yet)

These need the production profile and cannot be tested while pfSense holds the addresses. Each is written and checked in the cutover session.

| Item | What to do |
|---|---|
| WireGuard hub | Copy pfSense's `tun_wg0` private key into Vault; render the tunnel and four peers from `wireguard.yml` (production only) |
| HE tunnel and IPv6 | gif interface (opt3), HE gateway, the three IPv6 interface addresses from `addresses.yml`, the production-only rules and mail port forwards in `filter.yml` and `nat_port_forwards.yml` |
| Tailscale routes | Production key with `--tags tag:infra` (auto-approved routes), advertise the seven routes and the exit node from `tailscale.yml`; extend `tasks/opnsense/tailscale.yml`, which refuses production today |
| CrowdSec agent | A LAPI-side allowlist (trusted addresses, 10.0.0.0/8, 192.168.0.0/16, our IPv6 prefixes) before the OPNsense agent may push alerts |
| Production config.xml | Render the production profile into a `config.xml` before the swap (see Cutover), so the swap is one import and reboot rather than a live re-run that drops its own connection |
| Kea leases | Optional: copy pfSense's lease file so clients keep their addresses without re-leasing |

## Cutover (VM swap)

1. Claim `host:pfsense` and `host:opnsense`. Check break-glass access (`ssh -p 52222 root@viktorbarzin.ddns.net`, then `qm terminal 100` / `qm terminal 101`).
2. `qm shutdown 101` (pfSense).
3. Set VM 100's four MAC addresses to pfSense's (net0 `BC:24:11:D7:3F:BA`, net1 `BC:24:11:48:40:B9`, net2 `BC:24:11:A9:F9:04`, net3 `BC:24:11:86:D0:A7`) in `stacks/opnsense` and apply; the TP-Link forwards and the nodes' ARP/NDP caches then need nothing.
4. Import the production `config.xml` on VM 100 over serial, reboot.
5. Run `ansible-playbook ... opnsense.yml -e opnsense_profile=production -e opnsense_allow_production=true` for idempotence, then `scripts/opnsense-verify --host 10.0.10.1 --profile production`.
6. Boot order: in `playbooks/reboot-boot-order.yml` set 100 to order 1 and 101 to `state: disabled`, apply.
7. Dependents (below), then the checks staging could not run: WAN port forwards from outside (mx2), DHCP leases, router advertisements, HE tunnel and HTTP/3 over IPv6, WireGuard sites, Tailscale routes, mail through HAProxy with real client addresses in Postfix logs.

Rollback: `qm shutdown 100`, put VM 100's own MACs back, `qm start 101`, boot order back. pfSense stays stopped and unchanged for two weeks.

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
