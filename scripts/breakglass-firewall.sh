#!/usr/bin/env bash
set -euo pipefail
# Break-glass base firewall (redesigned 2026-06-11; replaced the port-knock gate).
#
# Source of truth. Deploy to the PVE host with:
#   scp scripts/breakglass-firewall.sh root@192.168.1.127:/usr/local/sbin/breakglass-firewall.sh
#   ssh root@192.168.1.127 'chmod 0755 /usr/local/sbin/breakglass-firewall.sh && systemctl restart breakglass-firewall.service'
# The breakglass-firewall.service oneshot runs this at boot (RemainAfterExit).
#
# Model: key-only SSH break-glass on :52222, openly reachable from the WAN, NO
# port-knock. The SSH key is the gate (brute-force-proof); the rate-limit below
# only trims scanner noise / slows a hypothetical sshd 0-day.
#   :22    -> LAN admin (all of root's keys), always allowed.
#   :52222 -> WAN break-glass. LAN/VLAN sources bypass the limit; external NEW
#             connections are rate-limited per source IP, then accepted.
iptables -N BREAKGLASS 2>/dev/null || iptables -F BREAKGLASS
iptables -C INPUT -j BREAKGLASS 2>/dev/null || iptables -I INPUT 1 -j BREAKGLASS

iptables -A BREAKGLASS -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A BREAKGLASS -p tcp --dport 22 -j ACCEPT
iptables -A BREAKGLASS -p tcp --dport 52222 -s 192.168.1.0/24 -j ACCEPT
iptables -A BREAKGLASS -p tcp --dport 52222 -s 10.0.0.0/8 -j ACCEPT
iptables -A BREAKGLASS -p tcp --dport 52222 -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-name bg_ssh --hashlimit-mode srcip \
  --hashlimit-above 6/min --hashlimit-burst 3 -j DROP
iptables -A BREAKGLASS -p tcp --dport 52222 -j ACCEPT
