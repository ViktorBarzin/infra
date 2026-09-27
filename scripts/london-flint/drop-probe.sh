#!/bin/sh
# London Flint internet-drop probe.
#
# Runs on the GL.iNet Flint 2 (busybox ash), installed as /usr/bin/london-drop-probe
# by the london-drop-probe package (build-ipk.py; LuCI -> System -> Software ->
# Upload Package). LuCI -> System -> Scheduled Tasks starts it every minute:
#   * * * * * /usr/bin/flock -n /tmp/drop-probe.lock /usr/bin/timeout 58 /usr/bin/london-drop-probe
#
# Once a second it pings the current default gateway and two public IPs; every
# 5 seconds it asks an AdGuard upstream for a name directly. An internet drop is
# DROP_AFTER consecutive seconds with both public IPs failing (or, for a
# DNS-only drop, DNS_DROP_AFTER consecutive failed lookups while ping works).
# At the start of a drop it snapshots routing, kmwan and DPI-queue state. When
# the path returns it queues one JSON event and pushes the queue to Loki,
# retrying on later runs until Loki accepts it. The line is stamped with the
# push time so the Loki ruler sees it; start and end are in the body.
#
# Source of truth: infra/scripts/london-flint/drop-probe.sh. Design:
# infra/docs/plans/2026-09-27-london-flint-main-router.md.

. /usr/share/libubox/jshn.sh

# Overridable from the crontab line, e.g. PUBLIC1=192.0.2.1 to rehearse a drop.
PUBLIC1=${PUBLIC1:-1.1.1.1}
PUBLIC2=${PUBLIC2:-9.9.9.9}
DNS_SERVER=${DNS_SERVER:-94.140.14.14}
DNS_NAME=${DNS_NAME:-example.com}
DROP_AFTER=5
DNS_DROP_AFTER=2
# Traefik redirects HTTP to HTTPS and the wildcard cert does not cover .lan, so
# pin the name to the internal Traefik IP and skip verification (the path is
# inside the WireGuard tunnel).
LOKI_HOST=loki.viktorbarzin.lan
LOKI_IP=10.0.20.203
LOKI_URL=https://$LOKI_HOST/loki/api/v1/push
STATE=/tmp/drop-probe.state
SNAP=/tmp/drop-probe.snapshot
QUEUE=/root/drop-probe.queue

ok() { ping -c 1 -W 1 "$1" >/dev/null 2>&1; }

gateway() { ip -4 route show default table main | awk '/default/ {print $3; exit}'; }

load_state() {
	first_fail=0; dns_fail=0; start=0; layer=""; gw_down=0; last_dns=0
	[ -f "$STATE" ] && . "$STATE"
}

save_state() {
	printf 'first_fail=%s\ndns_fail=%s\nstart=%s\nlayer=%s\ngw_down=%s\nlast_dns=%s\n' \
		"$first_fail" "$dns_fail" "$start" "$layer" "$gw_down" "$last_dns" >"$STATE"
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

queue_event() {
	local end="$1"
	json_init
	json_add_string drop_id "flint-$start"
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
	json_add_string drop_id "flint-$start"
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
	logger -t drop-probe "internet drop flint-$start layer=$layer duration=$((end - start))s"
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

tick() {
	local now gw p1 p2 pg r1 r2 rg
	now=$(date +%s)
	gw=$(gateway)
	ok "$PUBLIC1" & p1=$!
	ok "$PUBLIC2" & p2=$!
	if [ -n "$gw" ]; then ok "$gw" & pg=$!; fi
	wait $p1; r1=$?
	wait $p2; r2=$?
	if [ -n "$gw" ]; then wait $pg; rg=$?; else rg=1; fi

	if [ "$r1" != 0 ] && [ "$r2" != 0 ]; then
		[ "$first_fail" = 0 ] && first_fail=$now
		[ "$rg" != 0 ] && gw_down=1
		if [ $((now - first_fail + 1)) -ge "$DROP_AFTER" ] && [ "$start" = 0 ]; then
			start=$first_fail
			if [ "$gw_down" = 1 ]; then layer=gateway; else layer=internet; fi
			snapshot
		fi
		save_state
		return
	fi

	if [ "$start" != 0 ] && [ "$layer" != dns ]; then
		queue_event "$now"
		start=0; layer=""
	fi
	first_fail=0; gw_down=0

	if [ $((now - last_dns)) -ge 5 ]; then
		last_dns=$now
		if nslookup "$DNS_NAME" "$DNS_SERVER" >/dev/null 2>&1; then
			if [ "$start" != 0 ] && [ "$layer" = dns ]; then
				queue_event "$now"
				start=0; layer=""
			fi
			dns_fail=0
		else
			dns_fail=$((dns_fail + 1))
			if [ "$dns_fail" -ge "$DNS_DROP_AFTER" ] && [ "$start" = 0 ]; then
				start=$((now - 5 * (DNS_DROP_AFTER - 1)))
				layer=dns
				snapshot
			fi
		fi
	fi
	save_state
}

load_state
flush_queue
end_at=$(( $(date +%s) + 57 ))
while [ "$(date +%s)" -lt "$end_at" ]; do
	t0=$(date +%s)
	tick
	[ "$(date +%s)" = "$t0" ] && sleep 1
done
flush_queue
