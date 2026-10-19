<?php
/*
 * pfsense-vermont-alias-config.php — idempotent configurator for the route to
 * the Vermont complex alias 10.77.1.0/24 (ADR-0035). Shipped and invoked by
 * playbooks/pfsense-vermont-alias.yml.
 *
 * What it manages:
 *   1. Removes the disabled gateway `4g_router` (it pointed at 192.168.1.10,
 *      which is now rpi-sofia; the 4G router answers at .7) and its disabled
 *      static route 34.117.118.44/32. Viktor, 2026-10-17.
 *   2. Gateway `rpi_sofia` = 192.168.1.10 on WAN, monitoring off. A static
 *      route stays installed when its gateway is down, and with monitoring off
 *      there is no dpinger and no down alert; complex traffic just times out
 *      while the Pi is down.
 *   3. Static route 10.77.1.0/24 via rpi_sofia.
 *   4. Outbound NAT: no NAT from the allowed sources to 10.77.1.0/24 (hybrid
 *      mode, manual rules run first). Two reasons: pfSense's automatic rule
 *      "let out anything from firewall host itself" carries route-to the
 *      TP-Link for source 192.168.1.2, so NATed traffic would never reach the
 *      Pi; and the Pi's allowlist can then name real sources.
 *   5. A floating block, quick, out on WAN: anything to 10.77.1.0/24 whose
 *      source is not an allowed client. Out on WAN is where every path
 *      (LAN, k8s VLAN, WireGuard, tailnet) converges, after NAT, so a source
 *      that was NATed to .2 is blocked here too.
 *
 *   --check   report the diff, write nothing (Ansible --check)
 * Output: JSON {"changed": bool, "changes": [...]}.
 */

require_once('config.inc');
require_once('util.inc');
require_once('functions.inc');
require_once('filter.inc');
require_once('gwlb.inc');
require_once('system.inc');

global $config;
// Never name a variable $g here: it is pfSense's global settings array, and
// overwriting it makes write_config() emit a config with an empty root
// element, which it then rejects and "repairs" by restoring an older backup.

$opts    = getopt('', ['check', 'validate-only']);
// --validate-only: build the new config in memory, render and re-parse it,
// write nothing. Used to test the configurator safely.
$validate_only = array_key_exists('validate-only', $opts);
$check   = array_key_exists('check', $opts) && !$validate_only;
$changes = [];
$who     = 'ansible (pfsense-vermont-alias)';

/* ── Desired state ──────────────────────────────────────────────────────── */
$ALIAS_CIDR     = '10.77.1.0/24';
$PI_ADDR        = '192.168.1.10';
$GW_NAME        = 'rpi_sofia';
$CLIENTS_ALIAS  = 'vermont_complex_clients';
$TARGET_ALIAS   = 'vermont_complex_alias';
// Only the devvm. The k8s nodes were removed on 2026-10-19 with the cluster
// iVMS (stacks/ivms retired; iVMS runs on VM 300, which reaches the Pi
// directly). Keep in step with vermont_allowed_sources in
// playbooks/rpi-sofia-netmap.yml.
$CLIENTS = [
    '10.0.10.10/32'  => 'devvm',
];
$NONAT_DESCR = 'no NAT to Vermont complex alias (ADR-0035)';
// The rule is found by this description, so the text stays as first written.
$BLOCK_DESCR = 'Vermont complex alias: only k8s nodes and devvm (ADR-0035)';
$ROUTE_DESCR = 'Vermont complex alias via rpi-sofia (ADR-0035)';

function note(&$changes, $msg)
{
    $changes[] = $msg;
}

function stamp($who)
{
    return ['time' => (string) time(), 'username' => $who];
}

/* ── 1. Remove the stale 4g_router gateway and its route ────────────────── */
$gws = &$config['gateways']['gateway_item'];
if (!is_array($gws)) {
    $gws = [];
}
foreach ($gws as $i => $gw) {
    if (($gw['name'] ?? '') === '4g_router') {
        note($changes, "gateways[$i]: DELETE 4g_router (" . ($gw['gateway'] ?? '?') . ', disabled)');
        if (!$check) {
            unset($gws[$i]);
        }
    }
}

$routes = &$config['staticroutes']['route'];
if (!is_array($routes)) {
    $routes = [];
}
foreach ($routes as $i => $r) {
    if (($r['gateway'] ?? '') === '4g_router') {
        note($changes, "staticroutes[$i]: DELETE " . ($r['network'] ?? '?') . ' via 4g_router (disabled)');
        if (!$check) {
            unset($routes[$i]);
        }
    }
}

/* ── 2. Gateway rpi_sofia ───────────────────────────────────────────────── */
$want_gw = [
    'interface'       => 'wan',
    'gateway'         => $PI_ADDR,
    'name'            => $GW_NAME,
    'weight'          => '1',
    'ipprotocol'      => 'inet',
    'descr'           => 'rpi-sofia, path to the Vermont complex alias (ADR-0035)',
    'monitor_disable' => '',
];
$gw_idx = null;
foreach ($gws as $i => $gw) {
    if (($gw['name'] ?? '') === $GW_NAME) {
        $gw_idx = $i;
    }
}
if ($gw_idx === null) {
    note($changes, "gateways: ADD $GW_NAME = $PI_ADDR on wan, monitoring off");
    if (!$check) {
        $gws[] = $want_gw;
    }
} else {
    foreach ($want_gw as $k => $v) {
        if (($gws[$gw_idx][$k] ?? null) !== $v) {
            note($changes, "gateways[$gw_idx].$k -> " . var_export($v, true));
            if (!$check) {
                $gws[$gw_idx][$k] = $v;
            }
        }
    }
    if (isset($gws[$gw_idx]['disabled'])) {
        note($changes, "gateways[$gw_idx]: enable");
        if (!$check) {
            unset($gws[$gw_idx]['disabled']);
        }
    }
}

/* ── 3. Static route ────────────────────────────────────────────────────── */
$route_idx = null;
foreach ($routes as $i => $r) {
    if (($r['network'] ?? '') === $ALIAS_CIDR) {
        $route_idx = $i;
    }
}
$want_route = ['network' => $ALIAS_CIDR, 'gateway' => $GW_NAME, 'descr' => $ROUTE_DESCR];
if ($route_idx === null) {
    note($changes, "staticroutes: ADD $ALIAS_CIDR via $GW_NAME");
    if (!$check) {
        $routes[] = $want_route;
    }
} else {
    foreach ($want_route as $k => $v) {
        if (($routes[$route_idx][$k] ?? null) !== $v) {
            note($changes, "staticroutes[$route_idx].$k -> $v");
            if (!$check) {
                $routes[$route_idx][$k] = $v;
            }
        }
    }
    if (isset($routes[$route_idx]['disabled'])) {
        note($changes, "staticroutes[$route_idx]: enable");
        if (!$check) {
            unset($routes[$route_idx]['disabled']);
        }
    }
}

/* ── Aliases used by the NAT and filter rules ───────────────────────────── */
$aliases = &$config['aliases']['alias'];
if (!is_array($aliases)) {
    $aliases = [];
}
$want_aliases = [
    $CLIENTS_ALIAS => [
        'name'    => $CLIENTS_ALIAS,
        'type'    => 'network',
        'address' => implode(' ', array_keys($CLIENTS)),
        'descr'   => 'May reach the Vermont complex alias (ADR-0035)',
        'detail'  => implode('||', array_values($CLIENTS)),
    ],
    $TARGET_ALIAS => [
        'name'    => $TARGET_ALIAS,
        'type'    => 'network',
        'address' => $ALIAS_CIDR,
        'descr'   => 'Vermont complex alias, NETMAP on rpi-sofia (ADR-0035)',
        'detail'  => '10.77.1.x = complex 192.168.1.x',
    ],
];
foreach ($want_aliases as $name => $want) {
    $idx = null;
    foreach ($aliases as $i => $a) {
        if (($a['name'] ?? '') === $name) {
            $idx = $i;
        }
    }
    if ($idx === null) {
        note($changes, "aliases: ADD $name = {$want['address']}");
        if (!$check) {
            $aliases[] = $want;
        }
        continue;
    }
    foreach ($want as $k => $v) {
        if (($aliases[$idx][$k] ?? null) !== $v) {
            note($changes, "aliases[$name].$k -> $v");
            if (!$check) {
                $aliases[$idx][$k] = $v;
            }
        }
    }
}

/* ── 4. Outbound NAT: no NAT from the clients to the alias ──────────────── */
$nat = &$config['nat']['outbound']['rule'];
if (!is_array($nat)) {
    $nat = [];
}
if (($config['nat']['outbound']['mode'] ?? '') !== 'hybrid') {
    note($changes, 'WARNING: outbound NAT mode is not hybrid; the no-NAT rule may not apply');
}
$want_nonat = [
    'source'          => ['network' => $CLIENTS_ALIAS],
    'sourceport'      => '',
    'descr'           => $NONAT_DESCR,
    'target'          => '',
    'target_subnet'   => '',
    'interface'       => 'wan',
    'poolopts'        => '',
    'source_hash_key' => '',
    'nonat'           => '',
    'ipprotocol'      => 'inet',
    'destination'     => ['network' => $TARGET_ALIAS],
];
$nonat_idx = null;
foreach ($nat as $i => $r) {
    if (($r['descr'] ?? '') === $NONAT_DESCR) {
        $nonat_idx = $i;
    }
}
if ($nonat_idx === null) {
    note($changes, "nat.outbound: ADD no-NAT $CLIENTS_ALIAS -> $TARGET_ALIAS on wan (first)");
    if (!$check) {
        array_unshift($nat, $want_nonat + ['created' => stamp($who)]);
    }
} else {
    foreach ($want_nonat as $k => $v) {
        if (($nat[$nonat_idx][$k] ?? null) !== $v) {
            note($changes, "nat.outbound[$nonat_idx].$k changed");
            if (!$check) {
                $nat[$nonat_idx][$k] = $v;
            }
        }
    }
}

/* ── 5. Floating block for every other source ───────────────────────────── */
$filter = &$config['filter']['rule'];
if (!is_array($filter)) {
    $filter = [];
}
$want_block = [
    'type'        => 'block',
    'interface'   => 'wan',
    'ipprotocol'  => 'inet',
    'statetype'   => 'keep state',
    'direction'   => 'out',
    'floating'    => 'yes',
    'quick'       => 'yes',
    'source'      => ['address' => $CLIENTS_ALIAS, 'not' => ''],
    'destination' => ['address' => $TARGET_ALIAS],
    'descr'       => $BLOCK_DESCR,
];
$block_idx = null;
foreach ($filter as $i => $r) {
    if (($r['descr'] ?? '') === $BLOCK_DESCR) {
        $block_idx = $i;
    }
}
if ($block_idx === null) {
    note($changes, "filter: ADD floating block quick out on wan from !$CLIENTS_ALIAS to $TARGET_ALIAS");
    if (!$check) {
        $filter[] = $want_block + ['id' => '', 'tracker' => (string) time(), 'created' => stamp($who)];
    }
} else {
    foreach ($want_block as $k => $v) {
        if (($filter[$block_idx][$k] ?? null) !== $v) {
            note($changes, "filter[$block_idx].$k changed");
            if (!$check) {
                $filter[$block_idx][$k] = $v;
            }
        }
    }
    if (isset($filter[$block_idx]['disabled'])) {
        note($changes, "filter[$block_idx]: enable");
        if (!$check) {
            unset($filter[$block_idx]['disabled']);
        }
    }
}

/* ── Commit ─────────────────────────────────────────────────────────────── */
$result = ['changed' => count($changes) > 0, 'check_mode' => $check, 'changes' => $changes];

if (!$check && count($changes) > 0) {
    $gws    = array_values($gws);
    $routes = array_values($routes);
    /* Render and re-parse before writing. write_config() restores the newest
     * file in /cf/conf/backup when its own re-parse fails, and that file can
     * be older than the live config (2026-10-17: it rolled back a hand-edited
     * revision), so a config that does not parse must never reach it. */
    $tmp = '/tmp/pfsense-vermont-alias-candidate.xml';
    file_put_contents($tmp, dump_xml_config($config, g_get('xml_rootobj')));
    $parsed = parse_xml_config($tmp, g_get('xml_rootobj'));
    if (!is_array($parsed)) {
        fwrite(STDERR, "candidate config does not parse; nothing written ($tmp kept)\n");
        echo json_encode(['changed' => false, 'error' => 'candidate config does not parse', 'changes' => $changes]) . "\n";
        exit(2);
    }
    unlink($tmp);
    if ($validate_only) {
        echo json_encode(['changed' => false, 'validated' => true, 'changes' => $changes], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
        exit(0);
    }
    write_config('Vermont complex alias route (ansible, ADR-0035)');
    system_routing_configure();
    setup_gateways_monitor();
    filter_configure();
    $result['applied'] = true;
}

echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
