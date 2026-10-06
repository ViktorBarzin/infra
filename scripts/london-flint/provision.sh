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
