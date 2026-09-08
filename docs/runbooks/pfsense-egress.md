# Runbook: pfSense WAN / egress outage

**Scope:** the cluster (and home) loses **internet egress** while pfSense is
otherwise alive — internal VLAN routing and DNS keep working. This is the
**2026-06-27 incident class**: pfSense (Proxmox **VMID 101**) stopped passing
IPv4 egress for ~20 min (00:02→00:23 UTC) while LAN/OPT1 routing + Unbound
stayed up; recovery required a manual reboot, and **nothing alerted** (no egress
probe existed; the cloudflared replica metric stayed green). The alerts +
probes below close that gap. Incident detail: memory ids #6715–#6723.

pfSense is a **single point of failure** (no HA): it is the k8s default gateway
(`10.0.20.1`), Kea DHCP, Unbound DNS, NAT, and the WireGuard hub. WAN is
**static** `192.168.1.2/24`, upstream gateway `WANGW = 192.168.1.1` (the TP-Link
Archer AX6000). The sole IPv4 default gateway, no gateway-group/failover.

## Alerts (all in `stacks/monitoring/modules/monitoring/`)

| Alert | Signal | Means |
|-------|--------|-------|
| `WANGatewayUnreachable` (critical) | in-cluster ICMP to `192.168.1.1` fails >3m | pfSense's upstream gateway is unreachable from the cluster |
| `InternetEgressDown` (critical) | in-cluster ICMP to **both** `9.9.9.9` and `1.1.1.1` fails >2m | internet egress through pfSense NAT is black-holed |
| `ExternalDNSResolutionDown` (warning) | UDP/53 to both public resolvers fails >3m | egress or external-DNS path broken |
| `EgressOnlyDivergence` (critical) | t3-probe `cloudflare` leg down **while** `internal` leg up >3m | egress-specific failure, internal healthy (the exact 2026-06-27 signature) |
| `PfSenseVMDown` (critical) | `pve_up{id="qemu/101"}==0` while host up >2m | the pfSense VM stopped/crashed (host fine) |
| `CloudflaredTunnelConnLoss` (warning, Loki) | >20 cloudflared edge-conn failures/5m | tunnel/egress trouble (canary that fires first; replica metric is blind) |

Probes run **from inside the cluster** (blackbox-exporter, pod → node → pfSense
NAT), so they exercise the exact egress path that fails. `WANGatewayUnreachable`
/ `InternetEgressDown` **inhibit** the downstream egress symptoms so one root
alert pages, not a storm.

`PfSenseVMDown` **does not** catch a *guest-internal* reboot — `pve_up` tracks
the qemu process, which survives an in-guest reboot (this is why 2026-06-27 was
metric-invisible). `CloudflaredTunnelConnLoss` + the probe alerts cover that case.

## Diagnose (read-only first)

1. **Confirm scope** — is it egress-only or total?
   - `kubectl -n monitoring` Grafana → `probe_success{job=~"wan-gateway-icmp|internet-egress-icmp"}` and `t3probe_connected` by `leg`.
   - Internal still up? `pve_up{id="qemu/101"}` should be `1`; internal k8s DNS (`10.0.20.1`) still resolving = pfSense alive, egress-only.
2. **Capture pfSense on-box logs BEFORE rebooting** (they persist on disk — no RAM-disk — and are the only source that proves the mechanism; they are NOT shipped to Loki):
   ```
   ssh -i ~/.ssh/id_ed25519 admin@10.0.20.1      # devvm wizard key (id #6784)
   clog /var/log/gateways.log | grep -iE 'WANGW|down|up|delay|loss'   # dpinger gateway alarms
   clog /var/log/routing.log  | grep -iE 'default|route'              # default-route add/delete
   clog /var/log/system.log   | tail -200
   netstat -rn | head                                                 # is the default route present?
   ls -la /var/crash/                                                 # panic/textdump?
   ```
   (If SSH is rejected post-reboot, the reboot regenerated `authorized_keys` from
   config.xml — re-add the key via console or WebGUI; see id #6718.)
3. **Upstream check** — is the TP-Link / ISP up? It held the same public IP with
   clean DHCP renewals through the 2026-06-27 event, so a *sustained* upstream
   fault is unlikely; a reboot fixing it points at **pfSense-side state**.

## Recover

- **Fast path (known fix):** reboot pfSense — re-adds the default route, re-arms
  dpinger, flushes pf state. **Capture the logs above FIRST** (a reboot wipes
  the volatile evidence needed to find the real mechanism).
- Targeted (if logs show a dpinger gateway-down): System → Routing → Gateways →
  WANGW; check the monitor IP + dpinger state; re-enable the gateway / let it
  re-eval. Confirm `netstat -rn` shows the default route restored.

## Prevent / harden (deferred, needs a live-pfSense change)

Not done in this monitoring change — tracked for a follow-up with hands-on
pfSense access: point dpinger's monitor at the local gateway (`192.168.1.1`)
instead of an external IP + widen thresholds; disable `gw_down_kill_states` for
the single WAN; add a failover gateway group; a 60s auto-recovery watchdog;
ship pfSense system/gateway/routing syslog to the cluster so these logs become
centrally queryable.
