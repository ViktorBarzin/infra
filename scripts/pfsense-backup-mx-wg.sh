#!/bin/sh
# pfSense backup-mx WireGuard peer bootstrap + boot-recovery (ADR-0019).
#
# Adds the Oracle Always-Free backup-MX relay (mx2) as a road-warrior
# WireGuard peer on tun_wg0 so it can DRAIN queued mail to the primary over the
# encrypted tunnel (mx2 -> 10.0.20.1:25, the mailserver HAProxy frontend),
# adding NO new WAN mail port. Oracle blocks egress TCP/25 tenancy-wide, but
# the drain is UDP-encapsulated to :51821 so the block never sees TCP/25.
#
# DURABILITY — the important bit (root-caused 2026-07-18). The pfSense WireGuard
# PACKAGE regenerates /usr/local/etc/wireguard/tun_wg0.conf from config.xml on
# every boot. mx2 is intentionally a HAND-ADDED peer (not a package peer), so
# appending it to tun_wg0.conf is NOT durable — the package wipes it on the next
# boot. This is exactly what broke the drain during the 2026-07-18 Sofia power
# outage: pfSense rebooted, the package regenerated the conf without mx2, and
# mx2's queue stuck with "connect to 10.0.20.1[10.0.20.1]:25: Connection timed
# out". The DURABLE fix is a BOOT-RECOVERY shellcmd (installed by step 2 below):
# a bare-string system/shellcmd entry that pfSense core runs on boot, which
# backgrounds, waits for a site peer to reappear (= the package's WG sync is
# done), then re-adds mx2 live. See docs/runbooks/backup-mx.md.
#
# WHY HAND-ADDED (not a package peer): mx2 is a disposable Oracle relay; keeping
# it out of the package config avoids touching the site-to-site tunnel config.
# The trade-off is this boot-recovery hook. (Making it a proper package peer via
# the WireGuard UI would also work and remove the hook — future option.)
#
# NO FIREWALL RULE NEEDED: the opt2 (tun_wg0) interface already has an
# any->any "Allow all WireGuard VPN traffic" pass rule covering 10.3.2.0/24.
#
# USAGE (on pfSense as admin):
#   scp infra/scripts/pfsense-backup-mx-wg.sh admin@10.0.20.1:/tmp/
#   ssh admin@10.0.20.1 'sh /tmp/pfsense-backup-mx-wg.sh'
#
# IDEMPOTENT: safe to re-run (canonical reproducer for DR restore / fresh
# pfSense / mx2 rebuild). mx2's WG identity is Vault-persisted
# (secret/viktor/backup_mx_wg_*), so a mx2 VM rebuild does not require re-running
# this — the pubkey is stable.
set -e
IFACE=tun_wg0
PUBKEY="jxwL9ZmOEpQYH0eJrIE4RKA9l8xPPdmdgk+6NxO3u0M="
ALLOWED="10.3.2.10/32"
# london site peer — used only as the "package WG sync finished" signal in the
# boot-recovery wait loop (falls through after ~60s if it ever changes).
SYNC_SIGNAL_PEER="bDmcUteYQkne8Jo"

# 1. Apply the peer LIVE (immediate effect; no interface reconnect, does not
#    disturb the existing London/Sofia site peers).
wg set "$IFACE" peer "$PUBKEY" allowed-ips "$ALLOWED"
echo "peer applied live on $IFACE"

# 2. Install the durable BOOT-RECOVERY shellcmd (idempotent). Stored as a
#    bare-string system/shellcmd entry (pfSense core runs these via the shell on
#    boot). It backgrounds (>/dev/null 2>&1 &, so boot never blocks) and waits
#    for the site peer to reappear before re-adding mx2.
cat > /tmp/_mxwg_install.php <<'PHP'
<?php
require_once("config.inc");
require_once("util.inc");
$config = parse_config(true);
$loop = '( for i in 1 2 3 4 5 6 7 8 9 10 11 12; do /usr/bin/wg show tun_wg0 peers 2>/dev/null | grep -q bDmcUteYQkne8Jo && break; sleep 5; done; /usr/bin/wg set tun_wg0 peer jxwL9ZmOEpQYH0eJrIE4RKA9l8xPPdmdgk+6NxO3u0M= allowed-ips 10.3.2.10/32 ) >/dev/null 2>&1 &';
$sc = $config['system']['shellcmd'];
if (!is_array($sc)) { $sc = ($sc === '' ? array() : array($sc)); }
$new = array();
foreach ($sc as $e) {
    if (is_string($e) && strpos($e, 'jxwL9Zm') !== false) { continue; }
    if (is_array($e) && isset($e['cmd']) && strpos($e['cmd'], 'jxwL9Zm') !== false) { continue; }
    $new[] = $e;
}
$new[] = $loop;
$config['system']['shellcmd'] = $new;
write_config("backup-mx WG boot-recovery shellcmd (ADR-0019)");
echo "boot-recovery shellcmd installed\n";
PHP
php /tmp/_mxwg_install.php
rm -f /tmp/_mxwg_install.php

echo "done. current tun_wg0 peers:"
wg show "$IFACE" | grep -A2 "$PUBKEY" || true
