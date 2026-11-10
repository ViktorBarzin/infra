# Runbook: OPNsense WAN / egress outage

> Rewritten for OPNsense at the 2026-11-10 cutover; the edge firewall was pfSense before.

**Scope:** the cluster (and home) loses **internet egress** while the edge
firewall is otherwise alive: internal VLAN routing and DNS keep working. This is
the **2026-06-27 incident class**: pfSense (Proxmox VMID 101, before the
2026-11-10 cutover) stopped passing IPv4 egress for ~20 min (00:02→00:23 UTC)
while LAN/OPT1 routing and Unbound stayed up; recovery required a manual reboot,
and **nothing alerted** (no egress probe existed; the cloudflared replica metric
stayed green). The alerts and probes below close that gap. Incident detail:
memory ids #6715–#6723.

The edge firewall is OPNsense, Proxmox **VMID 100**, on pfSense's former
addresses and MACs (`docs/runbooks/opnsense.md`). It is a **single point of
failure** (no HA): it is the k8s default gateway (`10.0.20.1`), Kea DHCP,
Unbound DNS, NAT, and the WireGuard hub. WAN is **static** `192.168.1.2/24`,
upstream gateway `WANGW = 192.168.1.1` (the TP-Link Archer AX6000). The sole
IPv4 default gateway, no gateway group or failover.

## Alerts (all in `stacks/monitoring/modules/monitoring/`)

| Alert | Signal | Means |
|-------|--------|-------|
| `WANGatewayUnreachable` (critical) | in-cluster ICMP to `192.168.1.1` fails >3m | the firewall's upstream gateway is unreachable from the cluster |
| `InternetEgressDown` (critical) | in-cluster ICMP to **both** `9.9.9.9` and `1.1.1.1` fails >2m | internet egress through the firewall's NAT is black-holed |
| `ExternalDNSResolutionDown` (warning) | UDP/53 to both public resolvers fails >3m | egress or external-DNS path broken |
| `EgressOnlyDivergence` (critical) | t3-probe `cloudflare` leg down **while** `internal` leg up >3m | egress-specific failure, internal healthy (the exact 2026-06-27 signature) |
| `EdgeFirewallVMDown` (critical) | `pve_up{id="qemu/100"}==0` while host up >2m | the OPNsense VM stopped or crashed (host fine) |
| `CloudflaredTunnelConnLoss` (warning, Loki) | >20 cloudflared edge-conn failures/5m | tunnel/egress trouble (canary that fires first; replica metric is blind) |

Probes run **from inside the cluster** (blackbox-exporter, pod → node → OPNsense
NAT), so they exercise the exact egress path that fails. `WANGatewayUnreachable`
/ `InternetEgressDown` **inhibit** the downstream egress symptoms so one root
alert pages, not a storm.

`EdgeFirewallVMDown` was `PfSenseVMDown` on qemu/101 until the cutover. It
also inhibits the Tailscale, London and Mladost 3 tunnel alerts it causes.

`EdgeFirewallVMDown` **does not** catch a *guest-internal* reboot: `pve_up`
tracks the qemu process, which survives an in-guest reboot (this is why
2026-06-27 was metric-invisible). `CloudflaredTunnelConnLoss` and the probe
alerts cover that case.

## Diagnose (read-only first)

1. **Confirm scope:** is it egress-only or total?
   - Grafana → `probe_success{job=~"wan-gateway-icmp|internet-egress-icmp"}` and `t3probe_connected` by `leg`.
   - Internal still up? `pve_up{id="qemu/100"}` should be `1`; internal k8s DNS (`10.0.20.1`) still resolving means OPNsense is alive and the fault is egress-only.
2. **Capture the firewall's view BEFORE rebooting.** OPNsense keeps its logs on
   disk under `/var/log/<type>/` and also ships them to Loki
   (`{job="syslog", host="opnsense"}`), so the gateway and system logs survive a
   reboot in both places:
   ```
   ssh root@10.0.10.1          # root's shell is csh; pipe longer scripts to /bin/sh -s
   opnsense-log gateways | grep -iE 'WANGW|down|up|delay|loss'   # dpinger gateway alarms
   opnsense-log system | tail -200
   pluginctl -r return_gateways_status                          # dpinger status, delay, loss per gateway
   netstat -rn -f inet | grep default                           # is the default route present?
   ls -la /var/crash/                                           # panic/textdump?
   ```
   `opnsense-log -l` lists the log types. Any key in
   `playbooks/files/opnsense/authorized_keys.yml` logs in; the bastion also
   allows ProxyJump to `10.0.20.1`.
3. **Upstream check:** is the TP-Link / ISP up? It held the same public IP with
   clean DHCP renewals through the 2026-06-27 event, so a *sustained* upstream
   fault is unlikely; a reboot fixing it points at **firewall-side state**.

## Recover

- **Fast path:** reboot OPNsense. This re-adds the default route, re-arms
  dpinger and flushes pf state. **Capture the output above FIRST**; the logs
  persist, but the route table, dpinger status and pf state do not.
- **VM stopped** (`EdgeFirewallVMDown`): start VM 100 on the Proxmox host
  (`qm start 100`). Never start VM 101: the stopped pfSense VM has the same
  MACs and addresses. Going back to pfSense is
  `/root/opnsense-cutover/opnsense-cutover rollback` on the Proxmox host
  (`docs/runbooks/opnsense.md`, Cutover).
- **Targeted** (if the logs show a dpinger gateway-down): check WANGW in
  `pluginctl -r return_gateways_status` and the default route with `netstat -rn`.
  The gateway settings (monitor IP, intervals, kill states) are code in
  `playbooks/files/opnsense/gateways.yml`; do not change them in the GUI.
  Re-apply with
  `ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags gateways`
  (first with `--check --diff`).

## Prevent / harden (open)

Carried over from the pfSense follow-up list; still open on OPNsense as of
2026-11-10 unless noted. Each is an edit to `gateways.yml` (or new config) and a
playbook run:

- dpinger's WANGW monitor is still the external `9.9.9.9`
  (`gateways.yml` `monitor`); pointing it at the local gateway `192.168.1.1` and
  widening the thresholds is open.
- Kill states on gateway down is still on for the single WAN
  (`kill_states_on_down: true`).
- No failover gateway group, no auto-recovery watchdog.
- Done with the cutover: the firewall's system, gateway and filter logs now go to
  the cluster (syslog over TCP to Alloy `10.0.20.208`, Loki
  `{job="syslog", host="opnsense"}`).
