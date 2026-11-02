#!/bin/sh
# Watchdog for the pfSense IPv6 HAProxy bridge (see scripts/pfsense-ipv6-proxy.sh
# and docs/architecture/networking.md -> "IPv6 Ingress").
#
# Runs on pfSense from cron every 5 minutes; the cron entry is declared in
# config.xml by playbooks/pfsense-ipv6-bridge.yml, which also deploys this file
# to /usr/local/etc/ipv6_proxy_watchdog.sh.
#
# Why it exists: ipv6_proxy.sh runs only at boot, but pfSense regenerates
# /var/etc/nginx-webConfigurator.conf whenever the webConfigurator restarts
# (package install or re-sync, certificate or GUI change). The regenerated file
# listens on wildcard [::]:80, which also covers the tunnel address, so the
# HAProxy bridge cannot bind [TUNNEL]:80 and, because HAProxy binds every
# frontend or none, all six frontends (web and mail) go dark. On 2026-10-23 a
# WireGuard package re-sync did exactly this an hour after boot, and IPv6
# ingress stayed down for 10 days until 2026-11-02.
#
# Each run: if any bridge port is unbound, or the nginx config has a wildcard
# IPv6 listener again, re-run ipv6_proxy.sh (idempotent). Then push the state
# to the Prometheus pushgateway so alerts fire if the repair does not hold.
#   ipv6_bridge_up                          1 = all six frontends bound
#   ipv6_bridge_last_run_timestamp_seconds  every run (staleness alert)
#   ipv6_bridge_last_heal_timestamp_seconds only when this run repaired it
TUNNEL_IPV6="2001:470:6e:43d::2"
# Overridable so the repair path can be tested without breaking the bridge.
NGINX_CONF="${NGINX_CONF:-/var/etc/nginx-webConfigurator.conf}"
REPAIR="${REPAIR:-/usr/local/etc/ipv6_proxy.sh}"
PUSH_URL="${PUSH_URL:-http://10.0.20.100:30091/metrics/job/pfsense-ipv6-bridge}"
PORTS="443 80 25 465 587 993"

bound() {
    /usr/bin/sockstat -6 -l 2>/dev/null | grep -q " ${TUNNEL_IPV6}:$1 "
}

healthy() {
    for p in $PORTS; do
        bound "$p" || return 1
    done
    ! grep -q 'listen \[::\]:' "$NGINX_CONF" 2>/dev/null
}

healed=0
if ! healthy; then
    missing=""
    for p in $PORTS; do
        bound "$p" || missing="$missing $p"
    done
    /usr/bin/logger -t ipv6_proxy_watchdog "bridge unhealthy (unbound:${missing:- none}); re-running ${REPAIR}"
    /bin/sh "$REPAIR"
    healed=1
fi

up=0
healthy && up=1
now=$(date +%s)

body="# TYPE ipv6_bridge_up gauge
ipv6_bridge_up ${up}
# TYPE ipv6_bridge_last_run_timestamp_seconds gauge
ipv6_bridge_last_run_timestamp_seconds ${now}
"
if [ "$healed" = 1 ]; then
    body="${body}# TYPE ipv6_bridge_last_heal_timestamp_seconds gauge
ipv6_bridge_last_heal_timestamp_seconds ${now}
"
    if [ "$up" = 1 ]; then
        /usr/bin/logger -t ipv6_proxy_watchdog "bridge repaired"
    else
        /usr/bin/logger -t ipv6_proxy_watchdog "ERROR: bridge still down after repair"
    fi
fi

# POST (not PUT) replaces only the metrics sent, so the last heal timestamp
# survives runs that did not need to heal.
printf '%s' "$body" | /usr/local/bin/curl -s -m 10 --data-binary @- "$PUSH_URL" >/dev/null 2>&1 || true
