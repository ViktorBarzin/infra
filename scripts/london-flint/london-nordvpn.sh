#!/bin/sh
# NordVPN tunnel for London media players (docs/architecture/london-site.md, "Media players via NordVPN").
#
# The ISP objects to BitTorrent, and Stremio on the projector falls back to
# torrents when Real-Debrid has no copy. So every device with the role
# `media` sends all its internet traffic through a NordVPN WireGuard tunnel
# (interface nordvpn, routing table 1100), and the Flint's WAN only ever
# carries the encrypted tunnel. Traffic to Sofia keeps using wgclient1.
#
#   london-nordvpn apply      mark media players and (re)build the kill switch;
#                             the firewall include runs it on every reload
#   london-nordvpn refresh    fetch the account key and a Bulgarian server, bring the tunnel up
#   london-nordvpn watchdog   refresh when the handshake is stale (cron, every minute)
#
# Routing lives in uci, set by scripts/london-flint/provision.sh: rule
# nordvpn_media (mark 0x18000/0x1f000 -> table 1100, priority 5995) and the
# route nordvpn_blackhole (table 1100, metric 254), so with the tunnel down
# media traffic is dropped, never sent out of the WAN. The kill switch chain
# is a second guard that holds even if routing is wrong.
#
# The NordVPN access token is in /etc/london-nordvpn.token (mode 600), from
# Vault secret/proxy nordvpn_token, the token the cluster's gateways use.
set -u

NV_TOKEN_FILE=${NV_TOKEN_FILE:-/etc/london-nordvpn.token}
NV_RUN=${NV_RUN:-/tmp/london-nordvpn}
NV_NOW=${NV_NOW:-}
# Tests point these at stand-ins: busybox sh runs its own applets first.
NV_IFUP=${NV_IFUP:-ifup}
NV_LOGGER=${NV_LOGGER:-logger}
IFACE=nordvpn
COUNTRY=33       # NordVPN's id for Bulgaria (Viktor's choice: Bulgarian sites and catalogues)
MARK=0x10000     # a bit GL's own marks (0xf000, 0xf00, 0xf00000) leave free
STALE_S=300      # WireGuard re-handshakes every 2 minutes; keepalive keeps it busy
FIRST_S=180      # no handshake this long after a refresh: the server is not answering
COOLDOWN_S=600   # NordVPN refuses an over-limit reconnect for about 10 minutes
BACKOFF_S=3600   # after a 401, 403 or 429

now() { if [ -n "$NV_NOW" ]; then echo "$NV_NOW"; else date +%s; fi; }
log() { $NV_LOGGER -t london-nordvpn "$*"; }

# api URL [USER:PASS]: the body on stdout. Returns 0 on 200, 2 on a refusal
# (401, 403, 429), 1 on anything else.
api() {
	if [ -n "${2:-}" ]; then
		out=$(curl -g -s -m 15 -w '\n%{http_code}' -u "$2" "$1") || return 1
	else
		out=$(curl -g -s -m 15 -w '\n%{http_code}' "$1") || return 1
	fi
	code=$(printf '%s' "$out" | tail -n 1)
	printf '%s' "$out" | sed '$d'
	case "$code" in
	200) return 0 ;;
	401 | 403 | 429) return 2 ;;
	*) return 1 ;;
	esac
}

refused() {
	echo $(($(now) + BACKOFF_S)) >"$NV_RUN/backoff"
	log "refresh stopped: NordVPN refused the $1 request (HTTP $code); next try in $BACKOFF_S s"
	return 1
}

refresh() {
	mkdir -p "$NV_RUN"
	t=$(now)
	if [ -f "$NV_RUN/backoff" ] && [ "$t" -lt "$(cat "$NV_RUN/backoff")" ]; then
		log "refresh skipped: backing off after a refusal"
		return 1
	fi
	token=$(cat "$NV_TOKEN_FILE" 2>/dev/null)
	[ -n "$token" ] || { log "refresh failed: no token in $NV_TOKEN_FILE"; return 1; }
	echo "$t" >"$NV_RUN/refreshed"

	creds=$(api "https://api.nordvpn.com/v1/users/services/credentials" "token:$token")
	case $? in 0) ;; 2) refused credentials; return 1 ;; *) log "refresh failed: credentials request"; return 1 ;; esac
	key=$(printf '%s' "$creds" | jsonfilter -e '@.nordlynx_private_key')

	servers=$(api "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=$COUNTRY&filters[servers_technologies][identifier]=wireguard_udp&limit=1")
	case $? in 0) ;; 2) refused servers; return 1 ;; *) log "refresh failed: server request"; return 1 ;; esac
	host=$(printf '%s' "$servers" | jsonfilter -e '@[0].hostname')
	station=$(printf '%s' "$servers" | jsonfilter -e '@[0].station')
	pub=$(printf '%s' "$servers" | jsonfilter -e '@[0].technologies[@.identifier="wireguard_udp"].metadata[@.name="public_key"].value')

	if [ -z "$key" ] || [ -z "$station" ] || [ -z "$pub" ]; then
		log "refresh failed: NordVPN's answer had no key or server"
		return 1
	fi
	uci set network.$IFACE.private_key="$key"
	uci set network.${IFACE}_server.public_key="$pub"
	uci set network.${IFACE}_server.endpoint_host="$station"
	uci commit network
	$NV_IFUP $IFACE
	log "refreshed: $host ($station)"
}

watchdog() {
	mkdir -p "$NV_RUN"
	t=$(now)
	if [ ! -f "$NV_RUN/refreshed" ]; then
		# After a boot /tmp is empty while the tunnel comes up: start the clock only.
		echo "$t" >"$NV_RUN/refreshed"
		return 0
	fi
	last=$(cat "$NV_RUN/refreshed")
	hs=$(wg show $IFACE latest-handshakes 2>/dev/null | awk '{print $2; exit}')
	if [ -z "$hs" ]; then
		reason="no tunnel"
	elif [ "$hs" = 0 ]; then
		[ $((t - last)) -ge $FIRST_S ] || return 0
		reason="no handshake"
	elif [ $((t - hs)) -ge $STALE_S ]; then
		reason="last handshake $((t - hs)) s ago"
	else
		return 0
	fi
	[ $((t - last)) -ge $COOLDOWN_S ] || return 0
	log "tunnel down ($reason), refreshing"
	refresh
}

apply() {
	ipset create lr_media hash:mac -exist
	iptables -t mangle -C PREROUTING -i br-lan -m set --match-set lr_media src -j MARK --set-xmark $MARK/$MARK 2>/dev/null ||
		iptables -t mangle -I PREROUTING -i br-lan -m set --match-set lr_media src -j MARK --set-xmark $MARK/$MARK
	# Kill switch: a media player may leave only through the tunnel, to Sofia,
	# or to the LANs. IPv6 has no tunnel (NordVPN carries IPv4 only), so its
	# IPv6 internet is refused and the apps fall back to IPv4.
	for ipt in iptables ip6tables; do
		$ipt -N london_nordvpn 2>/dev/null
		$ipt -F london_nordvpn
		for dev in $IFACE wgclient1 br-lan br-guest; do
			$ipt -A london_nordvpn -o "$dev" -j RETURN
		done
		$ipt -A london_nordvpn -m limit --limit 20/min -j LOG --log-prefix london-nordvpn-blocked:
		$ipt -A london_nordvpn -j REJECT
		$ipt -C forwarding_lan_rule -m set --match-set lr_media src -j london_nordvpn 2>/dev/null ||
			$ipt -A forwarding_lan_rule -m set --match-set lr_media src -j london_nordvpn
	done
}

case "${1:-}" in
apply) apply ;;
refresh) refresh ;;
watchdog) watchdog ;;
*)
	echo "usage: london-nordvpn apply|refresh|watchdog" >&2
	exit 64
	;;
esac
