#!/bin/sh
# Ban internet sources that open too many SSH or admin-page connections to
# the London Flint. provision.sh installs this as /etc/firewall.bruteforce, a
# firewall include that runs again on every firewall reload.
#
# SSH (22) and the GL admin page (443) stay open on the WAN for everyone
# (Viktor, 2026-09-27). Over IPv4 the WAN sits behind carrier NAT, so only
# other customers of the carrier reach it; over IPv6 the whole internet does.
# Password login is off, so these bans only cut scanner noise and slow a
# guesser at the admin page.
#
# Only new connections arriving on the WAN (eth1) are counted: established
# traffic is accepted before input_wan_rule, and the tunnel and the LAN never
# pass through it. Sofia's IPv6 ranges are exempt, so provision.sh still works
# over IPv6 when the tunnel is down. Bans are logged with the prefix
# "wan-bruteforce" and reach Loki through the router's syslog.
# A ban sits in /proc/net/xt_recent/bf_ssh_ban or bf_admin_ban. Lift one with
#   echo -<address> > /proc/net/xt_recent/bf_ssh_ban
#
# BF_EXEMPT overrides the exempt ranges; an empty value tests the bans.

EXEMPT6=${BF_EXEMPT-"2001:470:5a7f::/48 2001:470:6f:43d::/64"}

# name port connections window-seconds ban-seconds. A count above 20 needs a
# bigger xt_recent table than the kernel default.
RULES="ssh 22 5 60 86400
admin 443 20 10 3600"

for ipt in iptables ip6tables; do
	$ipt -N wan_bruteforce 2>/dev/null
	$ipt -F wan_bruteforce
	if [ "$ipt" = ip6tables ]; then
		for net in $EXEMPT6; do
			$ipt -A wan_bruteforce -s "$net" -j RETURN
		done
	fi
	echo "$RULES" | while read -r name port limit window ban; do
		chain="wan_bf_$name"
		$ipt -N "$chain" 2>/dev/null
		$ipt -F "$chain"
		$ipt -A "$chain" -m recent --name "bf_${name}_ban" --set
		$ipt -A "$chain" -m limit --limit 6/min -j LOG --log-prefix "wan-bruteforce ban $name: "
		$ipt -A "$chain" -j DROP

		$ipt -A wan_bruteforce -p tcp --dport "$port" -m recent --name "bf_${name}_ban" --update --seconds "$ban" -j DROP
		$ipt -A wan_bruteforce -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --name "bf_$name" --set
		$ipt -A wan_bruteforce -p tcp --dport "$port" -m conntrack --ctstate NEW -m recent --name "bf_$name" --rcheck --seconds "$window" --hitcount "$limit" -j "$chain"
	done
	$ipt -C input_wan_rule -j wan_bruteforce 2>/dev/null || $ipt -I input_wan_rule -j wan_bruteforce
done
