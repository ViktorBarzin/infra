#!/bin/sh
# Fetch the raw address data phpipam_import.py reads, one file per Source in
# $1 (default /tmp/sources). Everything goes through pfSense, which is the only
# host that can reach every site router; pfSense's own key is authorised on
# them. A fetch that fails leaves its file without the ---SECTION--- markers,
# and the importer then treats that Source as failed and leaves its rows alone.
#
# Usage: fetch_sources.sh [dir]   (PFSENSE=admin@10.0.20.1 by default)
set -u
dir=${1:-/tmp/sources}
pf=${PFSENSE:-admin@10.0.20.1}
mkdir -p "$dir"

# The OpenWrt site routers, by their LAN address.
for pair in london=192.168.8.1 valchedrym=192.168.0.1 mladost3=192.168.3.1; do
	site=${pair%%=*}
	router=${pair#*=}
	ssh -o ConnectTimeout=10 -o BatchMode=yes "$pf" \
		"timeout 20 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes root@$router 'cat /tmp/dhcp.leases; echo; echo ---UCI---; uci -q show dhcp; echo; echo ---ARP---; cat /proc/net/arp'" \
		>"$dir/$site.txt" 2>"$dir/$site.err" || echo "fetch $site failed: $(tail -1 "$dir/$site.err")"
done

# pfSense itself. The home LAN's DHCP server is the TP-Link router, which has
# no readable API, so ping every address first: each probe makes pfSense ARP
# for it, and the ARP table then lists every device that is up. 64 at a time,
# one second each, about 4 s in all. pfSense's admin shell is not sh, hence
# the script on stdin.
ssh -o ConnectTimeout=10 -o BatchMode=yes "$pf" sh -s >"$dir/sofia.txt" 2>"$dir/sofia.err" <<'EOF' || echo "fetch sofia failed: $(tail -1 "$dir/sofia.err")"
i=1
while [ $i -le 254 ]; do
	ping -c 1 -t 1 -q 192.168.1.$i >/dev/null 2>&1 &
	[ $((i % 64)) -eq 0 ] && wait
	i=$((i + 1))
done
wait
printf "\n---KEA_LEASES---\n"
cat /var/lib/kea/dhcp4.leases.2 /var/lib/kea/dhcp4.leases 2>/dev/null
printf "\n---KEA_CONF---\n"
cat /usr/local/etc/kea/kea-dhcp4.conf
printf "\n---ARP---\n"
arp -an
printf "\n---WG---\n"
wg show tun_wg0 allowed-ips
EOF
exit 0
