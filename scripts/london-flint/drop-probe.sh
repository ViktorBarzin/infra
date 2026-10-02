#!/bin/sh
# London Flint internet-drop probe.
#
# Runs on the GL.iNet Flint 2 (busybox ash), installed as /usr/bin/london-drop-probe
# by the london-drop-probe package (build-ipk.py; LuCI -> System -> Software ->
# Upload Package), which also installs /etc/init.d/london-drop-probe. procd keeps
# it running; LuCI -> System -> Startup starts, stops or disables it.
#
# Not cron: busybox crond skipped every other minute's run of a long-running
# line (seen 2026-09-28), which left 60-second blind spots and produced two
# false 68 s drops on the first night.
#
# Every CHECK_EVERY seconds it makes an HTTP request to two public IPs from
# different providers, over IPv4 and over IPv6, and every DNS_EVERY seconds it
# resolves a fresh name through dnsmasq (since 0.5.0; before that it asked an
# AdGuard upstream directly, which skipped the path clients use). An IPv6 drop
# (both IPv6 requests failing while IPv4 works) is reported as layer=ipv6.
# After a failure it rechecks every RECHECK_EVERY seconds
# until the path returns, so a drop is timed to within a couple of seconds while
# the healthy-state traffic stays low. An internet drop is DROP_AFTER seconds or
# more with both requests failing; a DNS-only drop is DNS_DROP_AFTER seconds or
# more of failed lookups while HTTP works. Shorter blips are not reported: the
# outages that matter here last longer than 30 seconds (Viktor, 2026-09-28).
# Any HTTP answer counts as working.
#
# Not ping: behind the Hyperoptic router, a fresh one-shot ping out of the WAN
# failed about half the time (1.1.1.1 4/8, the gateway 6/8) while a continuous
# ping and every HTTP request succeeded, which produced 16 false drops on the
# night of 2026-09-27. The gateway is pinged only at the start of a drop, as one
# 3-packet ping, to tell a dead upstream link (layer=gateway) from an internet
# problem beyond it (layer=internet).
# At the start of a drop it snapshots routing, kmwan and DPI-queue state. When
# the path returns it queues one JSON event and pushes the queue to Loki,
# retrying on later runs until Loki accepts it. The line is stamped with the
# push time so the Loki ruler sees it; start and end are in the body.
#
# Source of truth: infra/scripts/london-flint/drop-probe.sh. Design:
# infra/docs/plans/2026-09-27-london-flint-main-router.md.

. /usr/share/libubox/jshn.sh

# Overridable from the crontab line, e.g. PUBLIC1=http://192.0.2.1/ to rehearse
# a drop.
PUBLIC1=${PUBLIC1:-http://1.1.1.1/}
PUBLIC2=${PUBLIC2:-https://8.8.8.8/}
# The same two providers over IPv6. An IPv6 drop is both failing for
# DROP_AFTER seconds while IPv4 works; it is reported as layer=ipv6.
PUBLIC6_1=${PUBLIC6_1:-http://[2606:4700:4700::1111]/}
PUBLIC6_2=${PUBLIC6_2:-https://[2001:4860:4860::8888]/}
# DNS is checked through dnsmasq, the path every client uses, with a fresh
# name each time (probe-<time>.<zone>, answered by the zone's wildcard) so
# dnsmasq's cache cannot answer for a dead upstream.
DNS_SERVER=${DNS_SERVER:-127.0.0.1}
DNS_ZONE=${DNS_ZONE:-viktorbarzin.me}
# Every NEIGH_EVERY seconds the probe pushes the IPv4/IPv6 neighbour tables
# and the DHCP leases to Loki ({job="london-neigh"}), so the DNS digest can
# turn a client address (often a rotating IPv6 privacy address) into a MAC
# and a hostname.
NEIGH_EVERY=300
# REHEARSAL=1 prefixes the layer with "rehearsal-" so a test drop is labelled
# as one in Loki and Slack.
REHEARSAL=${REHEARSAL:-0}
CHECK_EVERY=10
DNS_EVERY=30
RECHECK_EVERY=2
DROP_AFTER=30
DNS_DROP_AFTER=30
# Traefik redirects HTTP to HTTPS and the wildcard cert does not cover .lan, so
# pin the name to the internal Traefik IP and skip verification (the path is
# inside the WireGuard tunnel).
LOKI_HOST=loki.viktorbarzin.lan
LOKI_IP=10.0.20.203
LOKI_URL=https://$LOKI_HOST/loki/api/v1/push
STATE=/tmp/drop-probe.state
SNAP=/tmp/drop-probe.snapshot
QUEUE=/root/drop-probe.queue

web_ok() {
	[ "$(curl -sk --connect-timeout 1 -m 2 -o /dev/null -w '%{http_code}' "$1")" != 000 ]
}

is_dns() { [ "$1" = dns ] || [ "$1" = rehearsal-dns ]; }

# busybox nslookup exits 0 on NXDOMAIN too, so require an address line after
# the answer's Name: (the server header line is "Address:", no number).
dns_ok() {
	nslookup "probe-$1.$DNS_ZONE" "$DNS_SERVER" 2>/dev/null | grep -q '^Address [0-9]*: '
}

# 0 when the gateway answers none of 3 pings in one continuous ping.
gateway_alive() {
	[ -n "$1" ] && ping -c 3 -W 1 "$1" 2>/dev/null | grep -q ' [1-9][0-9]* packets received'
}

gateway() { ip -4 route show default table main | awk '/default/ {print $3; exit}'; }

load_state() {
	first_fail=0; dns_first_fail=0; start=0; layer=""; last_dns=0
	v6_first_fail=0; v6_start=0; last_neigh=0
	[ -f "$STATE" ] && . "$STATE"
}

save_state() {
	printf 'first_fail=%s\ndns_first_fail=%s\nstart=%s\nlayer=%s\nlast_dns=%s\nv6_first_fail=%s\nv6_start=%s\nlast_neigh=%s\n' \
		"$first_fail" "$dns_first_fail" "$start" "$layer" "$last_dns" \
		"$v6_first_fail" "$v6_start" "$last_neigh" >"$STATE"
}

snapshot() {
	{
		echo "== ip route show default"; ip -4 route show default table main
		echo "== ip route get 8.8.8.8"; ip route get 8.8.8.8
		echo "== kmwan"; cat /proc/gl-kmwan/status
		echo "== nfnetlink_queue"; cat /proc/net/netfilter/nfnetlink_queue
		echo "== wan"; ifstatus wan | jsonfilter -e '@.up' -e '@.uptime' -e '@["ipv4-address"][0].address'
		echo "== wg"; wg show wgclient1 latest-handshakes
	} >"$SNAP" 2>&1
}

# queue_event <start> <layer> <end>
queue_event() {
	local start="$1" layer="$2" end="$3" id
	id="flint-$start"
	[ "$layer" = ipv6 ] || [ "$layer" = rehearsal-ipv6 ] && id="flint-v6-$start"
	json_init
	json_add_string drop_id "$id"
	json_add_string source flint
	json_add_string layer "$layer"
	json_add_int start "$start"
	json_add_int end "$end"
	json_add_int duration_s $((end - start))
	json_add_string gateway "$(gateway)"
	json_add_string snapshot "$(cat "$SNAP" 2>/dev/null)"
	line=$(json_dump)
	# One Loki push body per queued line, labels carry the drop identity.
	json_init
	json_add_array streams
	json_add_object
	json_add_object stream
	json_add_string job london-drops
	json_add_string source flint
	json_add_string layer "$layer"
	json_add_string drop_id "$id"
	json_close_object
	json_add_array values
	json_add_array
	json_add_string "" "@NOW@"
	json_add_string "" "$line"
	json_close_array
	json_close_array
	json_close_object
	json_close_array
	json_dump >>"$QUEUE"
	logger -t drop-probe "drop $id layer=$layer duration=$((end - start))s"
	# Push now; anything that fails is retried at the start of the next run.
	flush_queue
}

flush_queue() {
	[ -s "$QUEUE" ] || return 0
	local keep=/tmp/drop-probe.keep body code
	: >"$keep"
	while IFS= read -r body; do
		body=$(echo "$body" | sed "s/@NOW@/$(date +%s)000000000/")
		code=$(curl -sk -m 5 -o /dev/null -w '%{http_code}' --resolve "$LOKI_HOST:443:$LOKI_IP" \
			-H 'Content-Type: application/json' --data-binary "$body" "$LOKI_URL")
		[ "$code" = 204 ] || echo "$body" >>"$keep"
	done <"$QUEUE"
	if [ -s "$keep" ]; then mv "$keep" "$QUEUE"; else rm -f "$QUEUE" "$keep"; fi
}

# One Loki line with the neighbour tables and DHCP leases. Best effort: a
# failed push is not queued, the next one comes NEIGH_EVERY seconds later.
push_neigh() {
	local line body
	json_init
	json_add_string neigh4 "$(ip -4 neigh show)"
	json_add_string neigh6 "$(ip -6 neigh show)"
	json_add_string leases "$(cat /tmp/dhcp.leases 2>/dev/null)"
	line=$(json_dump)
	json_init
	json_add_array streams
	json_add_object
	json_add_object stream
	json_add_string job london-neigh
	json_close_object
	json_add_array values
	json_add_array
	json_add_string "" "$(date +%s)000000000"
	json_add_string "" "$line"
	json_close_array
	json_close_array
	json_close_object
	json_close_array
	body=$(json_dump)
	curl -sk -m 5 -o /dev/null --resolve "$LOKI_HOST:443:$LOKI_IP" \
		-H 'Content-Type: application/json' --data-binary "$body" "$LOKI_URL"
}

# IPv6 drops, judged only while IPv4 works (an IPv4 drop is reported on its
# own and would otherwise be reported twice).
check_v6() {
	local now="$1" q1 q2 s1 s2 v6layer=ipv6
	[ "$REHEARSAL" = 1 ] && v6layer=rehearsal-ipv6
	web_ok "$PUBLIC6_1" & q1=$!
	web_ok "$PUBLIC6_2" & q2=$!
	wait $q1; s1=$?
	wait $q2; s2=$?
	if [ "$s1" != 0 ] && [ "$s2" != 0 ]; then
		[ "$v6_first_fail" = 0 ] && v6_first_fail=$now
		if [ $((now - v6_first_fail)) -ge "$DROP_AFTER" ] && [ "$v6_start" = 0 ]; then
			v6_start=$v6_first_fail
		fi
		return
	fi
	if [ "$v6_start" != 0 ]; then
		queue_event "$v6_start" "$v6layer" "$now"
		v6_start=0
	fi
	v6_first_fail=0
}

tick() {
	local now p1 p2 r1 r2
	now=$(date +%s)
	web_ok "$PUBLIC1" & p1=$!
	web_ok "$PUBLIC2" & p2=$!
	wait $p1; r1=$?
	wait $p2; r2=$?

	if [ "$r1" != 0 ] && [ "$r2" != 0 ]; then
		[ "$first_fail" = 0 ] && first_fail=$now
		if [ $((now - first_fail)) -ge "$DROP_AFTER" ] && [ "$start" = 0 ]; then
			start=$first_fail
			if gateway_alive "$(gateway)"; then layer=internet; else layer=gateway; fi
			[ "$REHEARSAL" = 1 ] && layer="rehearsal-$layer"
			snapshot
		fi
		save_state
		return
	fi

	if [ "$start" != 0 ] && ! is_dns "$layer"; then
		queue_event "$start" "$layer" "$now"
		start=0; layer=""
	fi
	first_fail=0

	check_v6 "$now"
	if [ $((now - last_neigh)) -ge "$NEIGH_EVERY" ]; then
		last_neigh=$now
		push_neigh
	fi

	local dns_every=$DNS_EVERY
	[ "$dns_first_fail" != 0 ] && dns_every=$RECHECK_EVERY
	if [ $((now - last_dns)) -ge "$dns_every" ]; then
		last_dns=$now
		if dns_ok "$now"; then
			if [ "$start" != 0 ] && is_dns "$layer"; then
				queue_event "$start" "$layer" "$now"
				start=0; layer=""
			fi
			dns_first_fail=0
		else
			[ "$dns_first_fail" = 0 ] && dns_first_fail=$now
			if [ $((now - dns_first_fail)) -ge "$DNS_DROP_AFTER" ] && [ "$start" = 0 ]; then
				start=$dns_first_fail
				layer=dns
				[ "$REHEARSAL" = 1 ] && layer=rehearsal-dns
				snapshot
			fi
		fi
	fi
	save_state
}

# Seconds to wait before the next HTTP check.
interval() {
	if [ "$first_fail" != 0 ] || [ "$dns_first_fail" != 0 ] || [ "$v6_first_fail" != 0 ]; then
		echo "$RECHECK_EVERY"
	else
		echo "$CHECK_EVERY"
	fi
}

load_state
flush_queue
while :; do
	t0=$(date +%s)
	tick
	next=$((t0 + $(interval)))
	while [ "$(date +%s)" -lt "$next" ]; do sleep 1; done
done
