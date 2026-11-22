#!/bin/sh
# London device roles and names on the Flint (docs/plans/2026-11-22-london-network-roles-design.md).
#
# Every London device is a guest unless the wifi app (stacks/wifi,
# wifi.viktorbarzin.me) gives its MAC a role. This agent keeps one ipset per
# role, and the london_roles chain decides which NEW connections from London
# may enter the tunnel to Sofia. Replies to connections Sofia opens are
# ESTABLISHED and never reach the chain, so Sofia can still reach every device.
#
# A device the app names gets a uci dhcp host section lr_<mac hex> with its
# name and, when the app fixes one, its address. dnsmasq gives the address,
# and the DNS import (stacks/phpipam) publishes <name>.viktorbarzin.lan.
#
#   london-roles run           long-poll loop (procd service london-roles)
#   london-roles once          one poll; for tests and by hand
#   london-roles apply         load the saved list into the ipsets (boot)
#   london-roles firewall      (re)build the chain; the firewall include runs it
#   london-roles push-leases   send the lease table now (DHCP hotplug)
#   london-roles leases-body | leases-hash
#
# Installed by scripts/london-flint/provision.sh as /usr/bin/london-roles.
# Config in /etc/london-roles.conf (LR_URL, LR_MODE=log|enforce); the app's
# bearer token in /etc/london-roles.token (mode 600).
set -u

LR_CONF=${LR_CONF:-/etc/london-roles.conf}
LR_TOKEN_FILE=${LR_TOKEN_FILE:-/etc/london-roles.token}
LR_LIST=${LR_LIST:-/etc/london-roles.list}
LR_LEASES=${LR_LEASES:-/tmp/dhcp.leases}
LR_RUN=${LR_RUN:-/tmp/london-roles}
# Tests point this at a stand-in: busybox sh runs its own ip applet first.
LR_IP=${LR_IP:-ip}
LR_UCI=${LR_UCI:-uci}
LR_DNSMASQ=${LR_DNSMASQ:-/etc/init.d/dnsmasq}
LR_URL=https://wifi.viktorbarzin.me
LR_MODE=log
# shellcheck disable=SC1090 # the config file is the router's own
[ -f "$LR_CONF" ] && . "$LR_CONF"

ROLES="admin storage iot infra-ha infra-k8s"
SIGNIN_IP=10.0.20.215

log() { logger -t london-roles "$*"; }

set_name() { echo "lr_$(echo "$1" | tr - _)"; }

token() { tr -d '\n' <"$LR_TOKEN_FILE"; }

# The device table as the app receives it: "mac ip hostname", sorted. DHCP
# leases first; then the London neighbour entries, for devices with a fixed
# address and no lease (ha-london); then reserved addresses, for devices that
# are offline now (dell-worker), so they can get a role before they rejoin. A
# MAC keeps the first line found for it.
leases_body() {
	{
		[ -f "$LR_LEASES" ] && awk 'NF >= 4 { print tolower($2), $3, $4 }' "$LR_LEASES"
		"$LR_IP" -4 neigh show | awk '$1 ~ /^192\.168\.(8|9)\./ { for (i = 2; i < NF; i++) if ($i == "lladdr") print tolower($(i + 1)), $1, "*" }'
		"$LR_UCI" -q show dhcp | awk -F= '
			{ split($1, k, "."); v = $2; gsub(/\047/, "", v) }
			k[3] == "name" { name[k[2]] = v }
			k[3] == "mac" { mac[k[2]] = tolower(v) }
			k[3] == "ip" { ip[k[2]] = v }
			END { for (h in ip) if (h in mac && mac[h] !~ / /) print mac[h], ip[h], (h in name ? name[h] : "*") }
		'
	} | awk '!($1 in seen) { seen[$1] = 1; print }' | sort
}

leases_hash() { leases_body | sha256sum | cut -d' ' -f1; }

push_leases() {
	mkdir -p "$LR_RUN"
	leases_body >"$LR_RUN/leases.put"
	out=$(curl -sS --max-time 20 -X PUT -H "Content-Type: text/plain" \
		-H "Authorization: Bearer $(token)" --data-binary "@$LR_RUN/leases.put" \
		-w '\n%{http_code}' "$LR_URL/api/router/leases" 2>&1)
	code=$(printf '%s' "$out" | tail -n 1)
	[ "$code" = 204 ] || [ "$code" = 200 ] || { log "lease upload failed: HTTP $code"; return 1; }
}

version_of() { [ -f "$1" ] && sed -n 's/^version \([0-9][0-9]*\)$/\1/p' "$1" | head -n 1; }

role_of() { # file mac; a guest has no role
	awk -v m="$2" 'NR > 1 && $1 == m && $2 != "guest" { print $2 }' "$1"
}

ip_of() { # mac
	[ -f "$LR_LEASES" ] && awk -v m="$1" 'tolower($2) == m { print $3; exit }' "$LR_LEASES"
}

# Build every role's set from a list file and swap it in at once.
apply_list() {
	file=$1
	for role in $ROLES; do
		s=$(set_name "$role")
		ipset create "$s" hash:mac -exist
		ipset create "${s}_new" hash:mac -exist
		ipset flush "${s}_new"
		awk -v r="$role" 'NR > 1 && $2 == r { print $1 }' "$file" | while read -r mac; do
			ipset add "${s}_new" "$mac" -exist
		done
		ipset swap "${s}_new" "$s"
		ipset destroy "${s}_new"
	done
}

# A device whose role changed or went away keeps no open connection to Sofia
# that its new role would not allow.
drop_changed() { # old new
	[ -f "$1" ] || return 0
	awk 'NR > 1 { print $1 }' "$1" | while read -r mac; do
		[ "$(role_of "$1" "$mac")" = "$(role_of "$2" "$mac")" ] && continue
		ip=$(ip_of "$mac")
		[ -n "$ip" ] || continue
		conntrack -D -s "$ip" -d 10.0.0.0/8 >/dev/null 2>&1
		conntrack -D -s "$ip" -d 192.168.1.0/24 >/dev/null 2>&1
		log "role of $mac changed: closed its Sofia connections"
	done
}

# A header, then "mac role" lines (format 1) or "mac role|guest name|- address|-"
# lines (format 2). A name is one lowercase DNS label; an address is a host on
# 192.168.8.0/24 other than the router.
valid_list() { # file
	awk -v roles=" $ROLES " '
		NR == 1 { if ($0 !~ /^version [0-9]+$/) bad = 1; next }
		$1 !~ /^([0-9a-f][0-9a-f]:){5}[0-9a-f][0-9a-f]$/ { bad = 1 }
		NF == 2 { if (index(roles, " " $2 " ") == 0) bad = 1; next }
		NF != 4 { bad = 1; next }
		$2 != "guest" && index(roles, " " $2 " ") == 0 { bad = 1 }
		$3 != "-" && ($3 !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/ || length($3) > 63) { bad = 1 }
		$4 != "-" {
			n = split($4, o, ".")
			if (n != 4 || o[1] != 192 || o[2] != 168 || o[3] != 8 || o[4] !~ /^[1-9][0-9]*$/ || o[4] < 2 || o[4] > 254) bad = 1
		}
		END { exit bad }
	' "$1"
}

# The lr_* dhcp host sections as "section name mac address|-" lines, sorted:
# wanted from a list file, or as uci has them now. dnsmasq refuses to start
# on two reservations of one address, so a wanted address that another host
# section (the GL.iNet UI's, provision.sh's) reserves is left out.
names_wanted() { # file
	{
		"$LR_UCI" -q show dhcp | awk -F= '
			{ split($1, k, "."); v = $2; gsub(/\047/, "", v) }
			k[2] !~ /^lr_/ && k[3] == "ip" { print "reserved", v }
		'
		awk 'NR > 1 && NF == 4 && $3 != "-" { print "want", $1, $3, $4 }' "$1"
	} | awk '
		$1 == "reserved" { reserved[$2] = 1; next }
		{ s = $2; gsub(/:/, "", s); ip = $4 in reserved ? "-" : $4; print "lr_" s, $3, $2, ip }
	' | sort
}

names_have() {
	"$LR_UCI" -q show dhcp | awk -F= '
		{ split($1, k, "."); v = $2; gsub(/\047/, "", v) }
		k[2] !~ /^lr_/ { next }
		k[3] == "" { sec[k[2]] = 1 }
		k[3] == "name" { name[k[2]] = v }
		k[3] == "mac" { mac[k[2]] = v }
		k[3] == "ip" { ip[k[2]] = v }
		END { for (s in sec) print s, name[s], mac[s], (s in ip ? ip[s] : "-") }
	' | sort
}

# Make the lr_* sections match the list; dnsmasq reloads only on a change.
apply_names() { # file
	want=$(names_wanted "$1")
	have=$(names_have)
	[ "$want" = "$have" ] && return 0
	for sec in $(printf '%s\n' "$have" | cut -d' ' -f1); do
		"$LR_UCI" -q delete "dhcp.$sec"
	done
	printf '%s\n' "$want" | while read -r sec name mac ip; do
		[ -n "$sec" ] || continue
		"$LR_UCI" set "dhcp.$sec=host"
		"$LR_UCI" set "dhcp.$sec.name=$name"
		"$LR_UCI" set "dhcp.$sec.mac=$mac"
		[ "$ip" = - ] || "$LR_UCI" set "dhcp.$sec.ip=$ip"
	done
	"$LR_UCI" commit dhcp
	"$LR_DNSMASQ" reload
	log "device names updated"
}

poll_once() {
	mkdir -p "$LR_RUN"
	since=$(version_of "$LR_LIST")
	# A list saved in format 1 (before names) is fetched again in full.
	awk 'NR > 1 && NF == 4 { found = 1 } END { exit !found }' "$LR_LIST" 2>/dev/null || since=0
	since=${since:-0}
	out=$(curl -sS --max-time 65 -H "Authorization: Bearer $(token)" \
		-w '\n%{http_code}' "$LR_URL/api/router/roles?since=$since&leases=$(leases_hash)&format=2" 2>&1)
	code=$(printf '%s' "$out" | tail -n 1)
	body=$(printf '%s' "$out" | sed '$d')
	if [ "$code" != 200 ]; then
		log "role poll failed: HTTP $code"
		return 2
	fi
	head1=$(printf '%s\n' "$body" | sed -n 1p)
	head2=$(printf '%s\n' "$body" | sed -n 2p)
	if [ "$head2" = "leases needed" ]; then
		push_leases || true
	fi
	case "$head1" in
	"version "*)
		printf '%s\n' "$head1" >"$LR_RUN/list.new"
		printf '%s\n' "$body" | sed -n '3,$p' | sed '/^$/d' >>"$LR_RUN/list.new"
		if ! valid_list "$LR_RUN/list.new"; then
			log "refused a malformed role list ($head1)"
			return 3
		fi
		if ! cmp -s "$LR_RUN/list.new" "$LR_LIST"; then
			drop_changed "$LR_LIST" "$LR_RUN/list.new"
			apply_list "$LR_RUN/list.new"
			apply_names "$LR_RUN/list.new"
			mv "$LR_RUN/list.new" "$LR_LIST"
			log "roles now at $head1"
		fi
		;;
	"unchanged "*) ;;
	*)
		log "unexpected reply: $head1"
		return 3
		;;
	esac
	date +%s >"$LR_RUN/lastsync"
}

# Which NEW connections from London may enter the tunnel. A RETURN goes back
# to the zone's lan -> wgclient1 ACCEPT; the end of the chain logs, and in
# enforce mode rejects.
firewall() {
	for role in $ROLES; do ipset create "$(set_name "$role")" hash:mac -exist; done
	iptables -N london_roles 2>/dev/null
	iptables -F london_roles
	iptables -A london_roles -m set --match-set lr_admin src -j RETURN
	iptables -A london_roles -m set --match-set lr_storage src -d 192.168.1.13 -p tcp --dport 445 -j RETURN
	iptables -A london_roles -m set --match-set lr_infra_ha src -d 192.168.1.127 -p tcp --dport 2049 -j RETURN
	iptables -A london_roles -m set --match-set lr_infra_ha src -d 10.0.20.200 -p tcp --dport 19532 -j RETURN
	# The robot vacuum camera (stacks/ecovacs-video-proxy): RTSP and its HTTP side.
	iptables -A london_roles -m set --match-set lr_infra_ha src -d 10.0.20.200 -p tcp --dport 8554 -j RETURN
	iptables -A london_roles -m set --match-set lr_infra_ha src -d 10.0.20.200 -p tcp --dport 8080 -j RETURN
	iptables -A london_roles -m set --match-set lr_infra_k8s src -d 10.0.20.0/24 -j RETURN
	# Every device may open the sign-in page.
	iptables -A london_roles -d "$SIGNIN_IP" -p tcp --dport 443 -j RETURN
	if [ "$LR_MODE" = enforce ]; then
		iptables -A london_roles -m limit --limit 20/min -j LOG --log-prefix london-roles-blocked:
		iptables -A london_roles -j REJECT --reject-with icmp-admin-prohibited
	else
		iptables -A london_roles -m limit --limit 20/min -j LOG --log-prefix london-roles-would-block:
	fi
	for chain in forwarding_lan_rule forwarding_guest_rule; do
		iptables -C "$chain" -o wgclient1 -j london_roles 2>/dev/null ||
			iptables -I "$chain" -o wgclient1 -j london_roles
	done
}

run() {
	[ -f "$LR_LIST" ] && apply_list "$LR_LIST"
	firewall
	push_leases || true
	wait_s=5
	while :; do
		if poll_once; then
			wait_s=5
		else
			sleep "$wait_s"
			wait_s=$((wait_s * 2))
			[ "$wait_s" -gt 60 ] && wait_s=60
		fi
	done
}

case "${1:-}" in
run) run ;;
once) poll_once ;;
apply) [ -f "$LR_LIST" ] && apply_list "$LR_LIST" ;;
firewall) firewall ;;
push-leases) push_leases ;;
leases-body) leases_body ;;
leases-hash) leases_hash ;;
*)
	echo "usage: london-roles run|once|apply|firewall|push-leases|leases-body|leases-hash" >&2
	exit 64
	;;
esac
