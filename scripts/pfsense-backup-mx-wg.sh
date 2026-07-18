#!/bin/sh
# pfSense backup-mx WireGuard peer — canonical reproducer (ADR-0019).
#
# Adds the Oracle Always-Free backup-MX relay (mx2) as a WireGuard peer on
# tun_wg0 so it can DRAIN queued mail to the primary over the encrypted tunnel
# (mx2 -> 10.0.20.1:25, the mailserver HAProxy frontend), adding NO new WAN mail
# port. Oracle blocks egress TCP/25 tenancy-wide, but the drain is
# UDP-encapsulated to :51821, so the block never sees TCP/25.
#
# mx2 is a proper WireGuard **PACKAGE peer** — identical to the London/Sofia site
# peers: stored in config.xml under installedpackages/wireguard/peers, so the
# WireGuard package regenerates it into /usr/local/etc/wireguard/tun_wg0.conf on
# every boot. It therefore survives reboots and config restores natively — no
# boot hook or shellcmd needed. (A 2026-07-18 regression added it only as a
# hand/live peer, which the package wiped on the outage reboot and broke the
# drain; making it a package peer is the fix. See docs/runbooks/backup-mx.md.)
#
# THE GUI EQUIVALENT of this script: Services > WireGuard > Peers > Add —
# tunnel tun_wg0, public key below, Allowed IPs 10.3.2.10/32, then Apply. This
# script is the CLI reproducer for DR onto a fresh pfSense (idempotent).
#
# NO FIREWALL RULE NEEDED: opt2 (tun_wg0) already has an any->any allow.
# mx2's WG identity is Vault-persisted (secret/viktor/backup_mx_wg_*), so a mx2
# VM rebuild does NOT require re-running this — the pubkey is stable.
#
# USAGE (on pfSense as admin; requires the WireGuard package + tun_wg0 to exist):
#   scp infra/scripts/pfsense-backup-mx-wg.sh admin@10.0.20.1:/tmp/
#   ssh admin@10.0.20.1 'sh /tmp/pfsense-backup-mx-wg.sh'
set -e
PUBKEY="jxwL9ZmOEpQYH0eJrIE4RKA9l8xPPdmdgk+6NxO3u0M="

cat > /tmp/_mxwg_pkgpeer.php <<'PHP'
<?php
require_once("globals.inc");
require_once("config.inc");
require_once("util.inc");
require_once("/usr/local/pkg/wireguard/includes/wg.inc");
$PUB = 'jxwL9ZmOEpQYH0eJrIE4RKA9l8xPPdmdgk+6NxO3u0M=';
$config = parse_config(true);
$peers = $config['installedpackages']['wireguard']['peers']['item'] ?? array();
foreach ($peers as $p) {
    if (($p['publickey'] ?? '') === $PUB) { echo "mx2 already a WG package peer (no-op)\n"; exit(0); }
}
$peers[] = array(
    'allowedips' => array('row' => array(
        array('address' => '10.3.2.10', 'mask' => '32', 'descr' => ''),
    )),
    'enabled' => 'yes',
    'tun' => 'tun_wg0',
    'descr' => 'backup-mx (Oracle mx2, ADR-0019)',
    'persistentkeepalive' => '25',
    'publickey' => $PUB,
    'presharedkey' => '',
);
$config['installedpackages']['wireguard']['peers']['item'] = $peers;
write_config("Add backup-mx (mx2) as a WireGuard package peer on tun_wg0 (ADR-0019)");
echo "mx2 added as WG package peer (" . count($peers) . " peers)\n";
// Apply in place (regenerate the conf from config + `wg syncconf`; no interface
// teardown, so the site peers do not blip).
$r = wg_tunnel_sync(array('tun_wg0'), false, true, false);
echo "apply ret_code: " . ($r['ret_code'] ?? '?') . "\n";
PHP
php /tmp/_mxwg_pkgpeer.php
rm -f /tmp/_mxwg_pkgpeer.php

echo "done. tun_wg0 peers:"
wg show tun_wg0 | grep -A2 "$PUBKEY" || true
