#!/bin/sh
# pfSense Mladost 3 site WireGuard peer — canonical reproducer.
#
# Adds the Mladost 3 OpenWrt router (TP-Link TL-WDR4300, tunnel IP 10.3.2.7,
# LAN 192.168.3.0/24) as a spoke on the tun_wg0 hub, plus the gateway and static
# route that send 192.168.3.0/24 down the tunnel. Same shape as the Valchedrym
# spoke (gateway `valchedrym` 10.3.2.5, route 192.168.0.0/24).
#
# The peer is a WireGuard PACKAGE peer (config.xml installedpackages/wireguard),
# so it survives reboots — see scripts/pfsense-backup-mx-wg.sh for why a hand
# peer does not. The router dials in (keepalive 25s), so the peer carries no
# endpoint. No firewall rule is needed: opt2 (tun_wg0) already allows any->any.
#
# GUI equivalent: Services > WireGuard > Peers > Add (tun_wg0, pubkey below,
# Allowed IPs 10.3.2.7/32 + 192.168.3.0/24); System > Routing > Gateways > Add
# (opt2, 10.3.2.7, name mladost3); System > Routing > Static Routes > Add
# (192.168.3.0/24 via mladost3).
#
# Keys: Vault secret/viktor mladost3_wg_private_key / mladost3_wg_public_key.
#
# USAGE (on pfSense as admin; idempotent):
#   scp infra/scripts/pfsense-mladost3-wg.sh admin@10.0.20.1:/tmp/
#   ssh admin@10.0.20.1 'sh /tmp/pfsense-mladost3-wg.sh'
set -e
PUBKEY="GONv96IzbE2PRxnXsz6cmnjhH2pRq7FRhiuxKB+JRi0="

cat > /tmp/_m3wg.php <<'PHP'
<?php
require_once("globals.inc");
require_once("config.inc");
require_once("util.inc");
require_once("system.inc");
require_once("gwlb.inc");
require_once("/usr/local/pkg/wireguard/includes/wg.inc");
$PUB = 'GONv96IzbE2PRxnXsz6cmnjhH2pRq7FRhiuxKB+JRi0=';
// Never name a variable $g or $config (pfSense globals) here: $g is
// the global path table, and overwriting it makes write_config write to /.
$config = parse_config(true);
$changed = array();

$peers = $config['installedpackages']['wireguard']['peers']['item'] ?? array();
$have_peer = false;
foreach ($peers as $p) {
    if (($p['publickey'] ?? '') === $PUB) { $have_peer = true; }
}
if (!$have_peer) {
    $peers[] = array(
        'allowedips' => array('row' => array(
            array('address' => '10.3.2.7', 'mask' => '32', 'descr' => 'mladost3 tunnel'),
            array('address' => '192.168.3.0', 'mask' => '24', 'descr' => 'mladost3 lan'),
        )),
        'enabled' => 'yes',
        'tun' => 'tun_wg0',
        'descr' => 'mladost3 (OpenWrt WDR4300)',
        'persistentkeepalive' => '25',
        'publickey' => $PUB,
        'presharedkey' => '',
    );
    $config['installedpackages']['wireguard']['peers']['item'] = $peers;
    $changed[] = 'peer';
}

$gws = $config['gateways']['gateway_item'] ?? array();
$have_gw = false;
foreach ($gws as $gw) {
    if (($gw['name'] ?? '') === 'mladost3') { $have_gw = true; }
}
if (!$have_gw) {
    $gws[] = array(
        'interface' => 'opt2',
        'gateway' => '10.3.2.7',
        'name' => 'mladost3',
        'weight' => '1',
        'ipprotocol' => 'inet',
        'descr' => 'mladost3',
        'monitor_disable' => '',
        'gw_down_kill_states' => '',
    );
    $config['gateways']['gateway_item'] = $gws;
    $changed[] = 'gateway';
}

$routes = $config['staticroutes']['route'] ?? array();
$have_route = false;
foreach ($routes as $rt) {
    if (($rt['network'] ?? '') === '192.168.3.0/24') { $have_route = true; }
}
if (!$have_route) {
    $routes[] = array('network' => '192.168.3.0/24', 'gateway' => 'mladost3', 'descr' => 'mladost3 lan');
    $config['staticroutes']['route'] = $routes;
    $changed[] = 'route';
}

if (!$changed) { echo "mladost3 peer, gateway and route already present (no-op)\n"; exit(0); }
write_config("Add Mladost 3 site: WG peer 10.3.2.7, gateway mladost3, route 192.168.3.0/24 (" . implode(',', $changed) . ")");
echo "added: " . implode(', ', $changed) . "\n";
// Apply the peer in place (regenerate conf + wg syncconf, no interface
// teardown, so the other site peers do not blip), then routes + monitor.
$sync = wg_tunnel_sync(array('tun_wg0'), false, true, false);
echo "wg apply ret_code: " . ($sync['ret_code'] ?? '?') . "\n";
setup_gateways_monitor();
system_staticroutes_configure();
PHP
php /tmp/_m3wg.php
rm -f /tmp/_m3wg.php

echo "done."
wg show tun_wg0 | grep -A3 "$PUBKEY" || true
netstat -rn -f inet | grep '192.168.3' || true
