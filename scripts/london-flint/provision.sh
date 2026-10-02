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
PROBE_VERSION=0.5.0
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
changed=0
[ "$(uci -q get dhcp.@dnsmasq[0].logqueries)" = 1 ] || { uci set dhcp.@dnsmasq[0].logqueries='1'; changed=1; }
[ "$(uci -q get dhcp.@dnsmasq[0].dnsforwardmax)" = 1000 ] || { uci set dhcp.@dnsmasq[0].dnsforwardmax='1000'; changed=1; }
if [ "$changed" = 1 ]; then
	uci commit dhcp
	/etc/init.d/dnsmasq restart
	echo "dnsmasq: query log on, forward-max 1000"
else
	echo "dnsmasq settings present"
fi
EOF

# Verify from this side of the tunnel, the same path Prometheus uses.
metrics=$(curl -s -m 10 http://10.3.2.6:9100/metrics | grep -c '^node_' || true)
# shellcheck disable=SC2086
probe=$(ssh -o BatchMode=yes $SSH_OPTS "$ROUTER" 'pgrep -f /usr/bin/london-drop-probe >/dev/null && echo running || echo stopped')
echo "node exporter: $metrics node_* series over the tunnel"
echo "drop probe: $probe"
[ "$metrics" -gt 0 ] && [ "$probe" = running ]
