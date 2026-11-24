#!/bin/sh
# BitTorrent WAN block on the London Flint (docs/architecture/london-site.md, "BitTorrent").
#
# The flat's ISP objects to BitTorrent. Stremio plays torrent rows from the
# Sofia streaming server ("P2P via Sofia", stacks/servarr/aiostreams), so no
# London device should torrent. This is the net under that: GL's DPI agent
# netifyd marks a flow it recognises as BitTorrent with connmark $BT_MARK (flow
# action london-bittorrent, set up by provision.sh), and the chain below lets
# such a flow into the tunnel to Sofia or the LANs and rejects it on the WAN.
# Recognition takes the first payload, so the first packet of each connection
# still leaves, and a torrent netifyd does not recognise is not blocked.
#
#   london-bittorrent apply   (re)build the chain; the firewall include runs it
#
# Installed by scripts/london-flint/provision.sh as /usr/bin/london-bittorrent.
set -u

BT_MARK=0x1000000 # free in GL's (0xf000, 0xf00, 0xf00000) and netifyd's marks

apply() {
	for ipt in iptables ip6tables; do
		$ipt -N london_bittorrent 2>/dev/null
		$ipt -F london_bittorrent
		for dev in wgclient1 br-lan br-guest; do
			$ipt -A london_bittorrent -o "$dev" -j RETURN
		done
		$ipt -A london_bittorrent -m limit --limit 20/min -j LOG --log-prefix london-bittorrent-blocked:
		$ipt -A london_bittorrent -j REJECT
		# First in FORWARD, before the ESTABLISHED accept: by the time a flow is
		# recognised it is already established.
		$ipt -C FORWARD -m connmark --mark $BT_MARK/$BT_MARK -j london_bittorrent 2>/dev/null ||
			$ipt -I FORWARD 1 -m connmark --mark $BT_MARK/$BT_MARK -j london_bittorrent
	done
}

case "${1:-}" in
apply) apply ;;
*)
	echo "usage: london-bittorrent apply" >&2
	exit 64
	;;
esac
