#!/bin/sh
# IPv6-to-IPv4 bridge: HE tunnel IPv6 -> Traefik (.203) + mailserver via HAProxy
# with PROXY-v2 so real client IPs propagate (CrowdSec). Patches pfSense nginx
# off the tunnel IPv6 first, then starts the HAProxy bridge (rc.d ipv6proxy).
#
# Runs on pfSense (10.0.20.1) as the config.xml <shellcmd> boot entrypoint.
# Deploy:  scp scripts/pfsense-ipv6-proxy.sh root@10.0.20.1:/usr/local/etc/ipv6_proxy.sh
# Tracked here so the guard below stays reviewable — see
# docs/architecture/networking.md -> "IPv6 Ingress" for the as-built and for
# the symptoms of a bridge that failed to start.
TUNNEL_IPV6="2001:470:6e:43d::2"
LAN_IPV6="2001:470:6f:43d::1"
NGINX_CONF="/var/etc/nginx-webConfigurator.conf"
sleep 5

# Move every wildcard IPv6 listener ("listen [::]:<port>") onto the LAN IPv6 so
# the HE tunnel address stays free for HAProxy.
#
# Port-agnostic on purpose. This guard used to test for the literal '[::]:443'.
# When the webConfigurator moved to 8443 the test stopped matching, the rebind
# was skipped, nginx kept wildcard *:80, and HAProxy could no longer bind
# [TUNNEL]:80 -- which takes down ALL six frontends, since HAProxy aborts if any
# bind fails. That went unnoticed until the next reboot (2026-07-18).
if grep -q 'listen \[::\]:' "$NGINX_CONF" 2>/dev/null; then
    sed -i '' -e "s|listen \[::\]:|listen [${LAN_IPV6}]:|g" "$NGINX_CONF"
    /usr/local/sbin/nginx -s reload -c "$NGINX_CONF" 2>/dev/null
    logger -t ipv6_proxy "Patched nginx wildcard IPv6 listeners onto ${LAN_IPV6}"
    sleep 2
fi

pkill -f "socat.*${TUNNEL_IPV6}" 2>/dev/null
sleep 1
/usr/local/etc/rc.d/ipv6proxy onestart

# Confirm the bridge actually came up. A silent bind failure here is what made
# the 2026-07-18 outage invisible for 29 days, so record the outcome either way.
sleep 2
if sockstat -6 -l 2>/dev/null | grep -q "${TUNNEL_IPV6}:443"; then
    logger -t ipv6_proxy "IPv6 HAProxy bridge started via rc.d (listening on ${TUNNEL_IPV6}:443)"
else
    logger -t ipv6_proxy "ERROR: IPv6 HAProxy bridge did NOT bind ${TUNNEL_IPV6}:443 - check for a port conflict on 80/443/25/465/587/993"
fi
