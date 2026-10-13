#!/bin/sh
# Install and configure the London Flint's monitoring packages.
#
# A GL firmware upgrade keeps UCI settings but drops every package installed
# with opkg. The 4.9.1 -> 4.11.0 upgrade on 2026-10-02 removed the node
# exporter and london-drop-probe this way, so run this after every upgrade.
# It is idempotent: packages already present at the wanted version are left
# alone, so a second run changes nothing.
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

# Device names (docs/architecture/dns.md, "London devices"). Every leased
# device is named in viktorbarzin.lan by phpipam-remote-import, from the
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

# Verify from this side of the tunnel, the same path Prometheus uses.
metrics=$(curl -s -m 10 http://10.3.2.6:9100/metrics | grep -c '^node_' || true)
# shellcheck disable=SC2086
probe=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'pgrep -f /usr/bin/london-drop-probe >/dev/null && echo running || echo stopped')
echo "node exporter: $metrics node_* series over the tunnel"
# shellcheck disable=SC2086
ring=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'ps w | sed -n "s|.*/sbin/logd -S \([0-9]*\).*|\1|p"')
echo "drop probe: $probe"
echo "log ring: ${ring} KB"
[ "$metrics" -gt 0 ] && [ "$probe" = running ] && [ "$ring" = 8192 ]
