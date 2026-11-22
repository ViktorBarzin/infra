#!/bin/sh
# Install and configure the London Flint's monitoring packages.
#
# A GL firmware upgrade keeps UCI settings but drops every package installed
# with opkg. The 4.9.1 -> 4.11.0 upgrade on 2026-10-02 removed the node
# exporter and london-drop-probe this way, so run this after every upgrade.
# It is idempotent: packages already present at the wanted version are left
# alone, so a second run changes nothing.
#
# It also locks SSH to the keys in authorized_keys and loads the WAN
# brute-force bans from wan-bruteforce.sh.
#
# Run from the devvm, which reaches the router over the WireGuard tunnel:
#   scripts/london-flint/provision.sh
# If the tunnel is down, the router answers SSH on its LAN IPv6 address:
#   ROUTER=root@2a01:4b00:ab23:1200::1 SSH_OPTS="-o HostKeyAlias=10.3.2.6" scripts/london-flint/provision.sh
#
# What gets installed is described in docs/architecture/london-site.md
# (Monitoring). Bump PROBE_VERSION together with any drop-probe.sh change.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROUTER=${ROUTER:-root@10.3.2.6}
SSH_OPTS=${SSH_OPTS:-}
PROBE_VERSION=0.6.3
# The wifi collector is left out on purpose: the MediaTek iwinfo backend has
# no noise, quality or bitrate, so it exports nothing useful.
EXPORTER_PKGS="prometheus-node-exporter-lua prometheus-node-exporter-lua-wifi_stations prometheus-node-exporter-lua-netstat prometheus-node-exporter-lua-openwrt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

ipk=$(python3 "$HERE/build-ipk.py" "$PROBE_VERSION" "$tmp")
# shellcheck disable=SC2086 # SSH_OPTS is a list of options
ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'cat > /tmp/london-drop-probe.ipk' <"$ipk"

# shellcheck disable=SC2086
ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'cat > /tmp/60-mtk-debug-off' <"$HERE/mtk-debug-off.hotplug"

# shellcheck disable=SC2086
ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'cat > /tmp/firewall.bruteforce' <"$HERE/wan-bruteforce.sh"
# The router gets the key list without its comment lines.
# shellcheck disable=SC2086
grep -v '^#' "$HERE/authorized_keys" | ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'cat > /tmp/authorized_keys'

# ssh joins its arguments into one remote command line, so the package list
# needs its own quotes to arrive as a single argument.
# shellcheck disable=SC2086
ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" "sh -s -- '$PROBE_VERSION' '$EXPORTER_PKGS'" <<'EOF'
set -eu
want_probe=$1
pkgs=$2

missing=""
for p in $pkgs; do
	opkg list-installed "$p" | grep -q "^$p " || missing="$missing $p"
done
if [ -n "$missing" ]; then
	echo "installing:$missing"
	# Package lists land in /tmp (RAM); only the packages touch flash.
	opkg update >/dev/null
	# shellcheck disable=SC2086
	opkg install $missing
else
	echo "exporter packages present"
fi

have=$(opkg list-installed london-drop-probe | awk '{print $3}')
if [ "$have" = "$want_probe" ]; then
	echo "london-drop-probe $have present"
else
	echo "london-drop-probe: '${have:-none}' -> $want_probe"
	# postinst enables and starts the procd service.
	opkg install --force-reinstall /tmp/london-drop-probe.ipk
fi
rm -f /tmp/london-drop-probe.ipk

# Listen on every interface: the WAN zone drops 9100 and the tunnel zone
# accepts it, which is how Prometheus in Sofia scrapes 10.3.2.6:9100.
uci set prometheus-node-exporter-lua.main.listen_interface='*'
uci set prometheus-node-exporter-lua.main.listen_port='9100'
uci commit prometheus-node-exporter-lua
/etc/init.d/prometheus-node-exporter-lua enable
/etc/init.d/prometheus-node-exporter-lua restart

# Silence the Wi-Fi driver's debug logging, now and on every interface add.
hook=/etc/hotplug.d/net/60-mtk-debug-off
if ! cmp -s /tmp/60-mtk-debug-off "$hook"; then
	mv /tmp/60-mtk-debug-off "$hook"
	echo "installed $hook"
else
	rm -f /tmp/60-mtk-debug-off
fi
chmod 755 "$hook"
grep -qxF "$hook" /etc/sysupgrade.conf || echo "$hook" >>/etc/sysupgrade.conf
for i in ra0 rax0; do iwpriv "$i" set Debug=0; done

# SSH: keys from authorized_keys only, no passwords (Viktor, 2026-11-22). SSH
# and the admin page stay open on the WAN, and over IPv6 that is the whole
# internet. The key list replaces the router's, and this script's own key is
# in it, so the next run still gets in.
if ! cmp -s /tmp/authorized_keys /etc/dropbear/authorized_keys; then
	cp /tmp/authorized_keys /etc/dropbear/authorized_keys
	echo "ssh: authorized_keys updated"
fi
chmod 600 /etc/dropbear/authorized_keys
rm -f /tmp/authorized_keys
if [ "$(uci -q get dropbear.@dropbear[0].PasswordAuth)" != off ] || [ "$(uci -q get dropbear.@dropbear[0].RootPasswordAuth)" != off ]; then
	uci set dropbear.@dropbear[0].PasswordAuth='off'
	uci set dropbear.@dropbear[0].RootPasswordAuth='off'
	uci commit dropbear
	# Open sessions, this one included, survive the restart.
	/etc/init.d/dropbear restart
	echo "ssh: password login off"
else
	echo "ssh: password login already off"
fi

# Ban WAN sources that open SSH or admin-page connections too fast. A firewall
# include, so every firewall reload puts the rules back; listed in
# sysupgrade.conf, so it outlives a firmware upgrade.
bf=/etc/firewall.bruteforce
if ! cmp -s /tmp/firewall.bruteforce "$bf"; then
	mv /tmp/firewall.bruteforce "$bf"
	echo "installed $bf"
else
	rm -f /tmp/firewall.bruteforce
fi
chmod 755 "$bf"
grep -qxF "$bf" /etc/sysupgrade.conf || echo "$bf" >>/etc/sysupgrade.conf
if [ "$(uci -q get firewall.bruteforce.path)" != "$bf" ]; then
	uci set firewall.bruteforce=include
	uci set firewall.bruteforce.type='script'
	uci set firewall.bruteforce.path="$bf"
	uci set firewall.bruteforce.reload='1'
	uci commit firewall
	echo "firewall: include $bf"
fi
sh "$bf"
echo "firewall: WAN brute-force bans loaded"

# DNS: log every lookup (--log-queries=extra puts a serial and the client on
# each line; the lines leave over the TCP syslog to Loki and nothing goes to
# flash), and raise the concurrent-query limit from 150, which was being hit.
# AdGuard is also asked over IPv6: over IPv4 the flat shares a CGNAT address,
# and AdGuard stopped answering it for up to 283 s at a time while IPv6 kept
# answering. "All servers" is on, so the first answer wins.
changed=0
[ "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 1 ] || { uci set dhcp.@dnsmasq[0].logqueries='1'; changed=1; }
[ "$(uci -q get dhcp.@dnsmasq[0].dnsforwardmax)" = 1000 ] || { uci set dhcp.@dnsmasq[0].dnsforwardmax='1000'; changed=1; }
for s in 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff; do
	uci -q get dhcp.@dnsmasq[0].server | tr ' ' '\n' | grep -qxF "$s" || { uci add_list dhcp.@dnsmasq[0].server="$s"; changed=1; }
done
if [ "$changed" = 1 ]; then
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	echo "dnsmasq: query log on, forward-max 1000, AdGuard IPv6 upstreams"
else
	echo "dnsmasq settings present"
fi

# Static lease for the iOS test rig phone ("Empress Anca"), so the devvm can
# reach it over Wi-Fi at a known address (docs/runbooks/ios-test-rig.md). It
# joins the guest SSID "5G-Tower" with a fixed private Wi-Fi address; if that
# address changes on the phone, update the MAC here.
if [ "$(uci -q get dhcp.iphone_london.ip)" != 192.168.9.205 ] || [ "$(uci -q get dhcp.iphone_london.mac)" != 6e:b1:68:39:7b:22 ]; then
	uci set dhcp.iphone_london=host
	uci set dhcp.iphone_london.name='iphone-london'
	uci set dhcp.iphone_london.mac='6e:b1:68:39:7b:22'
	uci set dhcp.iphone_london.ip='192.168.9.205'
	uci commit dhcp
	/etc/init.d/dnsmasq reload
	echo "dhcp: iphone-london -> 192.168.9.205"
else
	echo "dhcp: iphone-london lease present"
fi

# Static lease for the Dell Precision's Ubuntu worker, a Kubernetes node
# (ADR-0045). The node registers this address with the cluster, so it must not
# change. The MAC is the Wi-Fi card's permanent address; Fedora and Windows on
# the same laptop use private addresses and get ordinary leases.
if [ "$(uci -q get dhcp.dell_worker.ip)" != 192.168.8.20 ] || [ "$(uci -q get dhcp.dell_worker.mac)" != 48:89:e7:18:0e:66 ]; then
	uci set dhcp.dell_worker=host
	uci set dhcp.dell_worker.name='dell-worker'
	uci set dhcp.dell_worker.mac='48:89:e7:18:0e:66'
	uci set dhcp.dell_worker.ip='192.168.8.20'
	uci commit dhcp
	/etc/init.d/dnsmasq reload
	echo "dhcp: dell-worker -> 192.168.8.20"
else
	echo "dhcp: dell-worker lease present"
fi

# London traffic to Sofia keeps its own source address: no masquerade on the
# tunnel (Viktor, 2026-11-22, docs/plans/2026-11-22-london-network-roles-design.md).
# Sofia routes 192.168.8.0/24 back through the tunnel. The one NAT left is
# OPNsense's, for traffic to the Sofia home LAN (192.168.1.0/24), whose
# TP-Link drops asymmetric replies (playbooks/files/opnsense/aliases.yml,
# wg_site_lans). GL keeps the
# setting per WireGuard peer (the "IP Masquerading" option of the VPN client)
# and writes it into the firewall zone, so both are set.
fw_changed=0
for p in $(uci -X show wireguard | sed -n "s/^wireguard\.\(peer_[0-9]*\)\.masq='1'$/\1/p"); do
	[ "$(uci -q get "wireguard.$p.end_point" || true)" = "" ] && continue
	case "$(uci -q get "wireguard.$p.end_point")" in vpn.viktorbarzin.me:*) ;; *) continue ;; esac
	uci set "wireguard.$p.masq=0"
	uci commit wireguard
	echo "wireguard: $p masquerade off"
done
for k in masq masq6; do
	[ "$(uci -q get firewall.wgclient1.$k)" = 0 ] || { uci set "firewall.wgclient1.$k=0"; fw_changed=1; }
done
# The rule that exempted 192.168.8.0/24 -> 10.0.20.0/24 from the masquerade
# (ADR-0045) is no longer needed.
if grep -q 'london-lan-no-nat' /etc/firewall.user; then
	grep -v -e 'london-lan-no-nat' -e 'postrouting_rule -s 192.168.8.0/24 -d 10.0.20.0/24' /etc/firewall.user >/tmp/firewall.user.new
	cat /tmp/firewall.user.new >/etc/firewall.user
	rm -f /tmp/firewall.user.new
	iptables -t nat -D postrouting_rule -s 192.168.8.0/24 -d 10.0.20.0/24 -j ACCEPT 2>/dev/null || true
	echo "firewall.user: london-lan-no-nat removed"
fi
if [ "$fw_changed" = 1 ]; then
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	echo "firewall: tunnel masquerade off"
fi
if iptables -t nat -S zone_wgclient1_postrouting | grep -q MASQUERADE; then
	echo "firewall: tunnel still masquerades" >&2
	exit 1
fi
echo "firewall: no masquerade on the tunnel"

# Device names (docs/architecture/dns.md, "London devices"). Every leased
# device is named in viktorbarzin.lan by phpipam-import, from the
# hostname it announces. These entries give a chosen name to devices whose own
# name is missing or shared (five Kasa plugs all say "KP115"). No IP is pinned,
# so a name follows its device from one SSID to another. Kasa plugs are named
# after their nickname in the Kasa app.
# Each argument after the name is a MAC; a Mac on a private Wi-Fi address can
# present one per SSID, so mbp-london lists all of them.
dhcp_changed=0
ensure_host() {
	sec=$1 name=$2
	shift 2
	macs=$*
	# Drop any other host section that claims this name or one of these MACs,
	# such as the anonymous entries made in the GL UI before this existed.
	for other in $(uci -X show dhcp | sed -n "s/^dhcp\.\([^.=]*\)=host$/\1/p"); do
		[ "$other" = "$sec" ] && continue
		o_name=$(uci -q get "dhcp.$other.name" || true)
		o_macs=$(uci -q get "dhcp.$other.mac" | tr 'A-F' 'a-f' || true)
		hit=0
		[ "$o_name" = "$name" ] && hit=1
		for m in $macs; do
			case " $o_macs " in *" $m "*) hit=1 ;; esac
		done
		if [ "$hit" = 1 ]; then
			uci delete "dhcp.$other"
			dhcp_changed=1
			echo "dhcp: removed $other ($o_name $o_macs), replaced by $sec"
		fi
	done
	if [ "$(uci -q get "dhcp.$sec")" != host ] || [ "$(uci -q get "dhcp.$sec.name")" != "$name" ] ||
		[ "$(uci -q get "dhcp.$sec.mac")" != "$macs" ] || uci -q get "dhcp.$sec.ip" >/dev/null; then
		uci set "dhcp.$sec=host"
		uci set "dhcp.$sec.name=$name"
		uci set "dhcp.$sec.mac=$macs"
		uci -q delete "dhcp.$sec.ip" || true
		dhcp_changed=1
		echo "dhcp: $name -> $macs"
	fi
}
ensure_host plug_livia plug-livia 78:8c:b5:74:30:11
ensure_host plug_jinx plug-jinx 78:8c:b5:74:38:23
ensure_host plug_pikkachu plug-pikkachu 78:8c:b5:74:39:ce
ensure_host plug_michelle plug-michelle 9c:53:22:2b:59:4b
ensure_host plug_thor plug-thor 78:8c:b5:74:31:39
ensure_host plug_tapo plug-tapo 78:8c:b5:fe:ae:c1
ensure_host mbp_london mbp-london 84:2f:57:39:9a:d9 16:a8:3e:53:fe:6b 52:9f:c2:9a:64:ab
ensure_host anca_mba_london anca-mba-london aa:1c:ce:36:58:a8
ensure_host portal_london portal-london a4:0e:2b:0e:48:a3
ensure_host projector_london projector-london f4:9d:8a:26:0b:18

# The router's own traffic to 10.0.0.0/8 goes through the tunnel (table 1001),
# ahead of GL's fwmark rules at 6000. dnsmasq copies each client query's mark
# onto its upstream query (GL's conntrack option), and LAN traffic is marked
# 0x8000, "use main". At priority 9950 this rule came after that, so lookups
# forwarded to Technitium for London clients left via the WAN and were never
# answered, while the router's own unmarked lookups worked (2026-10-13). With
# the tunnel down, table 1001 holds only a blackhole, so this fails closed.
if [ "$(uci -q get network.router_to_sofia_via_tunnel.priority)" != 5990 ] ||
	[ "$(uci -q get network.router_to_sofia_via_tunnel.lookup)" != 1001 ]; then
	uci set network.router_to_sofia_via_tunnel=rule
	uci set network.router_to_sofia_via_tunnel.in='loopback'
	uci set network.router_to_sofia_via_tunnel.dest='10.0.0.0/8'
	uci set network.router_to_sofia_via_tunnel.lookup='1001'
	uci set network.router_to_sofia_via_tunnel.priority='5990'
	uci commit network
	ubus call network reload
	echo "network: router's 10.0.0.0/8 traffic -> tunnel at priority 5990"
else
	echo "network: router-to-tunnel rule present"
fi

# Resolve every viktorbarzin.lan name (Sofia's and London's alike) and the
# Sofia reverse zones at Technitium over the tunnel, so London clients get the
# same answer Sofia does. dnsmasq keeps answering bare names and <name>.lan
# from its own leases, and those keep working when the tunnel is down.
# dnsmasq's TCP fallback is dropped by GL's tcp_dns_leak_drop rule, so an
# answer over 1232 bytes fails; plain A lookups are far below that.
for s in /viktorbarzin.lan/10.0.20.201 /1.168.192.in-addr.arpa/10.0.20.201 /10.in-addr.arpa/10.0.20.201; do
	uci -q get dhcp.@dnsmasq[0].server | tr ' ' '\n' | grep -qxF "$s" || { uci add_list dhcp.@dnsmasq[0].server="$s"; dhcp_changed=1; echo "dnsmasq: server $s"; }
done
if [ "$dhcp_changed" = 1 ]; then
	uci commit dhcp
	/etc/init.d/dnsmasq restart
else
	echo "dhcp: device names and Technitium forwarding present"
fi
# Canary: a name only Technitium knows. The GL DNS page and the Tailscale
# toggle both rewrite dnsmasq settings, so a run that finds this failing after
# changing nothing means something else undid the forwarding.
# It runs on the router, whose own lookups carry no GL mark, so it cannot see
# a routing fault that only hits client lookups (the 9950 rule above). Check
# one from a London client after changing routing.
i=0
until [ "$(dig +short +time=2 +tries=1 @127.0.0.1 openwrt-london.viktorbarzin.lan)" = 192.168.8.1 ]; do
	i=$((i + 1))
	[ "$i" -lt 10 ] || { echo "dnsmasq: openwrt-london.viktorbarzin.lan does not resolve via Technitium" >&2; exit 1; }
	sleep 1
done
echo "dnsmasq: viktorbarzin.lan resolves via Technitium"

# System log: an 8 MB ring in RAM (was 512 KB, which the DNS query log filled
# in 3 to 14 minutes). The drop probe backfills tunnel outages from this ring,
# so its size is how long an outage can be and still arrive in Loki whole.
# Never log_file: that would write to flash (Viktor, 2026-09-28).
if [ "$(uci -q get system.@system[0].log_size)" != 8192 ]; then
	uci set system.@system[0].log_size='8192'
	uci commit system
	/etc/init.d/log restart
	# dnsmasq keeps writing to the old logd's socket after a log restart and
	# the query log goes silent (seen 2026-10-03), so restart it too.
	/etc/init.d/dnsmasq restart
	echo "system log: 8 MB ring"
else
	echo "system log ring present"
fi
EOF

# London device roles (docs/plans/2026-11-22-london-network-roles-design.md):
# the agent, its procd service, the DHCP hook that sends leases, and the
# firewall include that rebuilds the london_roles chain. The bearer token for
# the wifi app comes from Vault and lives only on the router. ROLES_MODE is
# "log" (log what enforce would block) or "enforce".
ROLES_MODE=log
for f in london-roles.sh:london-roles london-roles.init:london-roles.init london-roles.hotplug:london-roles.hotplug london-roles.firewall:london-roles.firewall; do
	# shellcheck disable=SC2086
	ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" "cat > /tmp/${f#*:}.new" <"$HERE/${f%%:*}"
done
# shellcheck disable=SC2086
vault kv get -field=router_token secret/wifi | ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'umask 077; cat > /tmp/london-roles.token.new'
# shellcheck disable=SC2086
ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" "sh -s -- '$ROLES_MODE'" <<'EOF'
set -eu
mode=$1
changed=0
place() { # new-file target mode
	if ! cmp -s "$1" "$2"; then
		mv "$1" "$2"
		changed=1
		echo "london-roles: installed $2"
	else
		rm -f "$1"
	fi
	chmod "$3" "$2"
	grep -qxF "$2" /etc/sysupgrade.conf || echo "$2" >>/etc/sysupgrade.conf
}
mkdir -p /etc/hotplug.d/dhcp
place /tmp/london-roles.new /usr/bin/london-roles 755
place /tmp/london-roles.init.new /etc/init.d/london-roles 755
place /tmp/london-roles.hotplug.new /etc/hotplug.d/dhcp/90-london-roles 644
place /tmp/london-roles.firewall.new /etc/firewall.london-roles 755
place /tmp/london-roles.token.new /etc/london-roles.token 600
printf 'LR_URL=https://wifi.viktorbarzin.me\nLR_MODE=%s\n' "$mode" >/tmp/london-roles.conf.new
place /tmp/london-roles.conf.new /etc/london-roles.conf 644
grep -qxF /etc/london-roles.list /etc/sysupgrade.conf || echo /etc/london-roles.list >>/etc/sysupgrade.conf
if [ "$(uci -q get firewall.london_roles.path)" != /etc/firewall.london-roles ]; then
	uci set firewall.london_roles=include
	uci set firewall.london_roles.type='script'
	uci set firewall.london_roles.path='/etc/firewall.london-roles'
	uci set firewall.london_roles.reload='1'
	uci commit firewall
	echo "firewall: include /etc/firewall.london-roles"
fi
/usr/bin/london-roles firewall
/etc/init.d/london-roles enable
if [ "$changed" = 1 ] || ! pgrep -f '/usr/bin/london-roles run' >/dev/null; then
	/etc/init.d/london-roles restart
	echo "london-roles: service (re)started, mode $mode"
else
	echo "london-roles: service running, mode $mode"
fi
EOF

# Verify from this side of the tunnel, the same path Prometheus uses.
metrics=$(curl -s -m 10 http://10.3.2.6:9100/metrics | grep -c '^node_' || true)
# shellcheck disable=SC2086
probe=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'pgrep -f /usr/bin/london-drop-probe >/dev/null && echo running || echo stopped')
echo "node exporter: $metrics node_* series over the tunnel"
# shellcheck disable=SC2086
ring=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'ps w | sed -n "s|.*/sbin/logd -S \([0-9][0-9]*\).*|\1|p"')
# The router should offer publickey and nothing else.
# shellcheck disable=SC2086
auth=$(ssh -v -o BatchMode=yes -o PubkeyAuthentication=no $SSH_OPTS "$ROUTER" true 2>&1 | sed -n 's/.*Authentications that can continue: //p' | head -1 | tr -d '\r')
# shellcheck disable=SC2086
bans=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'ip6tables -C input_wan_rule -j wan_bruteforce && iptables -C input_wan_rule -j wan_bruteforce && echo loaded || echo missing')
echo "drop probe: $probe"
echo "log ring: ${ring} KB"
echo "ssh login methods: $auth"
echo "WAN brute-force bans: $bans"
# shellcheck disable=SC2086
roles=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'pgrep -f "/usr/bin/london-roles run" >/dev/null && iptables -C forwarding_lan_rule -o wgclient1 -j london_roles 2>/dev/null && echo running || echo missing')
echo "london-roles: $roles"
[ "$metrics" -gt 0 ] && [ "$probe" = running ] && [ "$ring" = 8192 ] && [ "$auth" = publickey ] && [ "$bans" = loaded ] && [ "$roles" = running ]
