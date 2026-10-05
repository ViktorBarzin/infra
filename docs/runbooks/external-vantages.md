# External vantages: testing the homelab from outside

The devvm cannot test a public path. It resolves `*.viktorbarzin.me` through
Technitium's split horizon, and a request to the WAN IP comes back through
pfSense NAT reflection, so both look like a real external round trip without
being one. To check what an outside client sees, run the test from one of the
two machines below.

| | mx2 | mladost3-openwrt |
|---|---|---|
| What it is | Oracle Always-Free VM, backup MX + status page (ADR-0020) | The Mladost 3 site router (OpenWrt 23.05, TP-Link WDR4300) |
| Network | Oracle Cloud, Frankfurt, hosting ASN | BTC/Vivacom residential broadband, Sofia, AS8866 |
| Public address | 92.5.132.215 | 77.85.22.145 (DHCP, has been stable; it can change) |
| IP families | IPv4 only in practice (its IPv6 egress is dead) | IPv4 only (the ISP gives no IPv6) |
| Login | `ssh -i ~/.ssh/backup-mx ubuntu@92.5.132.215` | `ssh root@192.168.3.1` (or `root@10.3.2.7`) over the tunnel; `ssh root@77.85.22.145` over the internet when the tunnel is down; key only |
| Tools | full Ubuntu userland | `curl`, busybox `ping`/`nslookup`/`traceroute`; more via `opkg` (the USB extroot has 3.4 GB free) |
| Survives a homelab outage | yes, it has its own uplink and SSH | yes via its public address: SSH on 77.85.22.145 is open (key only), so with Sofia's internet down log in through mx2 (`ssh -J ubuntu@92.5.132.215 root@77.85.22.145`) |

Use mx2 when the homelab may be down, and for anything that should look like
a datacentre client. Use mladost3-openwrt when a residential, Bulgarian
address matters, for example to check geo or ASN-based filtering, or to
compare against mx2 when a result looks like it depends on where the client
sits.

## What is and isn't external from mladost3-openwrt

The router routes `10.0.0.0/8`, `192.168.1.0/24`, `192.168.8.0/24` and
`192.168.9.0/24` into the tunnel, and everything else out its own WAN.

- **External:** any public address, including Sofia's WAN IP `176.12.22.76`
  (`ip route get 176.12.22.76` shows `via 77.85.16.1 dev eth0.2`), and every
  Cloudflare-proxied hostname.
- **Not external:** hostnames with `dns_type = "internal"` resolve to
  `10.0.20.203`, which goes through the tunnel and arrives at Traefik as
  `10.3.2.7`. To test one of those from outside, pin it to the WAN IP:

  ```sh
  curl -s -o /dev/null -w '%{http_code}\n' \
    --resolve highlights-immich-milka.viktorbarzin.me:443:176.12.22.76 \
    https://highlights-immich-milka.viktorbarzin.me/
  ```

- The router's DNS forwards to 9.9.9.9 / 8.8.4.4, so `nslookup <name>
  127.0.0.1` shows the public answer, except that private answers are allowed
  for `viktorbarzin.me` (`rebind_domain`).
- Requests from it reach the homelab with source `77.85.22.145`; remember that
  when reading Traefik logs or CrowdSec decisions after a test.

Don't install heavy tools or run long jobs on the router: it has 128 MB of
RAM, and its busybox has no `nohup`, so keep the SSH session open for
anything long-running. Settings: [`../architecture/vpn.md`](../architecture/vpn.md)
(WireGuard, Mladost 3).

## Examples

```sh
# Is a proxied service reachable from a residential BG client?
ssh root@192.168.3.1 'curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://immich.viktorbarzin.me/'

# Does a LAN-only service refuse outsiders? (expect 403)
ssh root@192.168.3.1 'curl -s -o /dev/null -w "%{http_code}\n" --resolve highlights-immich.viktorbarzin.me:443:176.12.22.76 https://highlights-immich.viktorbarzin.me/'

# The same from a datacentre client, for comparison
ssh -i ~/.ssh/backup-mx ubuntu@92.5.132.215 'curl -s -o /dev/null -w "%{http_code}\n" https://immich.viktorbarzin.me/'
```
