#!/bin/sh
# pfSense backup-mx WireGuard peer bootstrap (ADR-0019).
#
# Adds the Oracle Always-Free backup-MX relay (mx2) as a road-warrior
# WireGuard peer on tun_wg0 so it can DRAIN queued mail to the primary over the
# encrypted tunnel (mx2 -> 10.0.20.1:25, the mailserver HAProxy frontend),
# adding NO new WAN mail port. Oracle blocks egress TCP/25 tenancy-wide, but
# the drain is UDP-encapsulated to :51821 so the block never sees TCP/25.
#
# WHY A SCRIPT: pfSense WireGuard here is hand-configured (kernel `wg` via
# /usr/local/etc/wireguard/tun_wg0.conf + an `earlyshellcmd` boot hook), NOT
# the pfSense package. This is the canonical, idempotent reproducer for the
# peer (disposability: DR restore / fresh pfSense / mx2 rebuild). mx2's WG
# identity is Vault-persisted (secret/viktor/backup_mx_wg_*), so a mx2 VM
# rebuild does NOT require re-running this — the pubkey is stable.
#
# NO FIREWALL RULE NEEDED: the opt2 (tun_wg0) interface already has an
# any->any "Allow all WireGuard VPN traffic" pass rule covering 10.3.2.0/24.
#
# USAGE (on pfSense as admin):
#   scp infra/scripts/pfsense-backup-mx-wg.sh admin@10.0.20.1:/tmp/
#   ssh admin@10.0.20.1 'sh /tmp/pfsense-backup-mx-wg.sh'
#
# IDEMPOTENT: re-running is a no-op if the peer is already present. Adding the
# peer with `wg set` is done LIVE and does NOT restart the interface or disturb
# the existing London/Sofia site peers.
set -e
CONF=/usr/local/etc/wireguard/tun_wg0.conf
IFACE=tun_wg0
PUBKEY="jxwL9ZmOEpQYH0eJrIE4RKA9l8xPPdmdgk+6NxO3u0M="
ALLOWED="10.3.2.10/32"
NAME="backup-mx (Oracle mx2, ADR-0019)"

# 1. Persist in the conf so it survives reboot / wireguardd restart.
if ! grep -q "$PUBKEY" "$CONF"; then
  cat >> "$CONF" <<EOF

# Peer: $NAME
[Peer]
PublicKey = $PUBKEY
AllowedIPs = $ALLOWED
EOF
  echo "peer appended to $CONF"
else
  echo "peer already present in $CONF (no-op)"
fi

# 2. Apply live — `wg set` adds the peer in place, no interface reconnect.
wg set "$IFACE" peer "$PUBKEY" allowed-ips "$ALLOWED"
echo "peer applied live on $IFACE:"
wg show "$IFACE" | grep -A2 "$PUBKEY" || true
