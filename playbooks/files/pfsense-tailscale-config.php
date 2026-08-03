<?php
/*
 * pfsense-tailscale-config.php — idempotent configurator for the pfSense
 * Tailscale subnet router. Shipped and invoked by playbooks/pfsense-tailscale.yml.
 *
 * WHY PHP AND NOT pfsensible.core: three of the four objects this manages
 * (the stale outbound-NAT rule, the pre-existing any->any filter rule, and the
 * whole <tailscale> package block) have EMPTY descriptions or no module at all,
 * and pfsensible.core addresses rules by `descr`. Managing them declaratively
 * here also avoids adding a pinned external collection dependency.
 *
 * Design: docs/plans/2026-08-03-pfsense-tailscale-subnet-router-design.md
 * Runbook: docs/runbooks/pfsense-tailscale-subnet-router.md
 *
 * Idempotent: computes desired state, applies only differences, and reports
 * what it changed as JSON on stdout ({"changed": bool, "changes": [...]}).
 *
 *   --check        report the diff, write nothing (Ansible --check)
 *   --authkey=KEY  set the Headscale pre-auth key (registration only)
 *   --blank-key    clear the stored pre-auth key after registration
 *
 * NEVER commit a pre-auth key into this file or into config.xml long-term: the
 * daily backup copies config.xml to NFS and Synology.
 */

require_once('config.inc');
require_once('util.inc');
require_once('functions.inc');
require_once('filter.inc');
require_once('/usr/local/pkg/tailscale/tailscale.inc');

global $config;

$opts      = getopt('', ['check', 'authkey:', 'blank-key']);
$check     = array_key_exists('check', $opts);
$authkey   = $opts['authkey'] ?? null;
$blank_key = array_key_exists('blank-key', $opts);
$changes   = [];

/* ── Desired state ──────────────────────────────────────────────────────────
 * Routes advertised to the tailnet. Sofia's three local subnets plus the three
 * WireGuard-transited remote LANs. Deliberately NOT 10.0.0.0/8: a blanket /8
 * hijacks a client's own 10.x network (office / hotel / CGNAT), and swallows
 * the CCTV segment (10.0.30.0/24, ADR-0017), the k8s pod CIDR (10.10.0.0/16)
 * and service CIDR (10.96.0.0/12), neither of which pfSense can route.
 * 0.0.0.0/0 is NOT listed here — exit-node advertisement is its own flag.
 *
 * Every route here must also appear in autoApprovers.routes in
 * stacks/headscale/acl.hujson, or it registers unapproved and silently
 * carries no traffic.
 */
$DESIRED_ROUTES = [
    '192.168.1.0/24' => 'sofia lan',
    '10.0.10.0/24'   => 'mgmt vlan',
    '10.0.20.0/24'   => 'k8s vlan',
    '192.168.0.0/24' => 'valchedrym (via wg)',
    '192.168.8.0/24' => 'london lan (via wg)',
    '192.168.9.0/24' => 'london guest (via wg)',
];

$LOGIN_SERVER = 'https://headscale.viktorbarzin.me/';
$CCTV_NET     = '10.0.30.0/24';
$TAILNET      = '100.64.0.0/10';

function note(&$changes, $msg)
{
    $changes[] = $msg;
}

/* ── 1. Tailscale package block ─────────────────────────────────────────── */
function desired_tailscale_block(): array
{
    global $DESIRED_ROUTES;
    $rows = [];
    foreach ($DESIRED_ROUTES as $cidr => $descr) {
        // No trailing empty row: the rc map joins rows with ',' unconditionally,
        // so a blank row emits "--advertise-routes=a,b," with a trailing comma.
        $rows[] = ['advertisedroutevalue' => $cidr, 'advertisedroutedescr' => $descr];
    }

    return [
        'enable'     => 'on',
        'listenport' => '41641',
        'statedir'   => '/usr/local/pkg/tailscale/state',
        'keepconfig' => 'on',
        // A firewall must not take DNS from the VPN control plane: --accept-dns
        // makes tailscaled rewrite /etc/resolv.conf to MagicDNS, and pfSense
        // regenerates resolv.conf on interface events, so the two fight.
        // MUST be present-and-not-'on': tailscale_get_config() defaults this
        // key to 'on' when ABSENT, so unsetting it silently re-enables it.
        'acceptdns' => '',
        // A subnet router advertises routes; it does not accept them. Leaving
        // this on lets any approved mesh peer inject routes into the firewall's
        // kernel routing table.
        'acceptroutes'   => '',
        'exitnode'       => 'on',
        'row'            => $rows,
        'syslogenable'   => 'on',
        'syslogpriority' => 'warning',
        'syslogfacility' => 'daemon',
    ];
}

$desired = desired_tailscale_block();
$current = $config['installedpackages']['tailscale']['config'][0] ?? [];

foreach ($desired as $k => $v) {
    $have = $current[$k] ?? null;
    if ($k === 'row') {
        $have_rows = [];
        foreach (($have ?? []) as $r) {
            if (($r['advertisedroutevalue'] ?? '') !== '') {
                $have_rows[] = $r['advertisedroutevalue'];
            }
        }
        $want_rows = array_keys($GLOBALS['DESIRED_ROUTES']);
        if ($have_rows !== $want_rows) {
            note($changes, 'tailscale.advertise-routes: [' . implode(',', $have_rows) .
                          '] -> [' . implode(',', $want_rows) . ']');
            if (!$check) {
                $config['installedpackages']['tailscale']['config'][0]['row'] = $v;
            }
        }
        continue;
    }
    if ($have !== $v) {
        note($changes, sprintf('tailscale.%s: %s -> %s', $k,
             var_export($have, true), var_export($v, true)));
        if (!$check) {
            $config['installedpackages']['tailscale']['config'][0][$k] = $v;
        }
    }
}

/* login server lives in the separate tailscaleauth block */
$auth_cur = $config['installedpackages']['tailscaleauth']['config'][0] ?? [];
if (($auth_cur['loginserver'] ?? '') !== $LOGIN_SERVER) {
    note($changes, 'tailscaleauth.loginserver -> ' . $LOGIN_SERVER);
    if (!$check) {
        $config['installedpackages']['tailscaleauth']['config'][0]['loginserver'] = $LOGIN_SERVER;
    }
}

/* pre-auth key: set for registration, blank afterwards. Single-use and
 * short-lived by design (see the design doc, D5) — nothing long-lived is
 * stored here. */
if ($authkey !== null && ($auth_cur['preauthkey'] ?? '') !== $authkey) {
    note($changes, 'tailscaleauth.preauthkey: set (value not logged)');
    if (!$check) {
        $config['installedpackages']['tailscaleauth']['config'][0]['preauthkey'] = $authkey;
    }
}
if ($blank_key && ($auth_cur['preauthkey'] ?? '') !== '') {
    note($changes, 'tailscaleauth.preauthkey: cleared');
    if (!$check) {
        $config['installedpackages']['tailscaleauth']['config'][0]['preauthkey'] = '';
    }
}

/* ── 2. Outbound NAT ────────────────────────────────────────────────────── */
$nat = &$config['nat']['outbound']['rule'];
if (!is_array($nat)) {
    $nat = [];
}

/* 2a. Drop the stale rule that masquerades to 100.64.0.3 — that was pfSense's
 *     own tailnet address in a previous registration and now belongs to a
 *     family laptop. It has an empty descr, so it can only be matched by
 *     target. */
foreach ($nat as $i => $r) {
    if (($r['target'] ?? '') === '100.64.0.3') {
        note($changes, "nat.outbound[$i]: DELETE stale rule (target 100.64.0.3, iface " .
                       ($r['interface'] ?? '?') . ')');
        if (!$check) {
            unset($nat[$i]);
        }
    }
}
if (!$check) {
    $nat = array_values($nat);
}

/* 2b. SNAT tailnet -> WireGuard sites to the tunnel address (10.3.2.1).
 *     The London and Valchedrym routers list only 10.0.0.0/8 + 192.168.x in
 *     their Sofia peer's AllowedIPs, so WireGuard drops inbound packets
 *     sourced from 100.64.0.0/10 and has no route back. Masquerading at the
 *     hub fixes both without touching either remote router.
 *     Interface opt2 = tun_wg0; target 'opt2ip' = its interface address. */
$WG_NAT_DESCR = 'tailnet -> WG sites: SNAT to tunnel address (see design 2026-08-03)';
$have_wg_nat  = false;
foreach ($nat as $r) {
    if (($r['descr'] ?? '') === $WG_NAT_DESCR) {
        $have_wg_nat = true;
    }
}
if (!$have_wg_nat) {
    note($changes, 'nat.outbound: ADD tailnet -> WG-sites SNAT (opt2, src ' . $TAILNET . ', target opt2ip)');
    if (!$check) {
        $nat[] = [
            'interface'       => 'opt2',
            'source'          => ['network' => $TAILNET],
            'sourceport'      => '',
            'destination'     => ['any' => ''],
            'target'          => 'opt2ip',
            'target_subnet'   => '',
            'poolopts'        => '',
            'source_hash_key' => '',
            'ipprotocol'      => 'inet',
            'descr'           => $WG_NAT_DESCR,
            'created'         => ['time' => (string) time(), 'username' => 'ansible (pfsense-tailscale)'],
            'updated'         => ['time' => (string) time(), 'username' => 'ansible (pfsense-tailscale)'],
        ];
    }
}

/* 2c. Assert the exit-node WAN rule still exists. It also carries the return
 *     path for the Sofia LAN: 192.168.1.0/24 hosts default-route to the
 *     TP-Link at .1, not to pfSense, so without SNAT to the WAN leg (.2) their
 *     replies to 100.64.x would be dropped. Never delete this rule. */
$have_wan_nat = false;
foreach ($nat as $r) {
    if (($r['interface'] ?? '') === 'wan' && ($r['source']['network'] ?? '') === $TAILNET) {
        $have_wan_nat = true;
    }
}
if (!$have_wan_nat) {
    note($changes, 'WARNING: exit-node/Sofia-LAN WAN SNAT rule for ' . $TAILNET . ' is MISSING');
}

/* ── 3. Firewall rules on the Tailscale interface group ─────────────────── */
$filter = &$config['filter']['rule'];
if (!is_array($filter)) {
    $filter = [];
}

$BLOCK_DESCR = 'tailnet -> CCTV blocked (ADR-0017 keeps that segment isolated)';
$PASS_DESCR  = 'tailnet -> homelab (subnet routes + exit node)';

$have_block = false;
$pass_idx   = null;
foreach ($filter as $i => $r) {
    if (($r['interface'] ?? '') !== 'Tailscale') {
        continue;
    }
    if (($r['descr'] ?? '') === $BLOCK_DESCR) {
        $have_block = true;
    }
    // The pre-existing pass rule has an empty descr; adopt it in place so its
    // tracker and ordering survive, rather than delete-and-recreate.
    if (($r['type'] ?? '') === 'pass' && ($r['descr'] ?? '') !== $BLOCK_DESCR) {
        $pass_idx = $i;
    }
}

/* 3a. Tighten the pass rule: source any -> the tailnet only, and give it a
 *     description so it is identifiable next time. */
if ($pass_idx !== null) {
    $r = $filter[$pass_idx];
    if (($r['source']['network'] ?? '') !== $TAILNET) {
        note($changes, "filter[$pass_idx]: pass source " .
                       json_encode($r['source'] ?? []) . " -> $TAILNET");
        if (!$check) {
            $filter[$pass_idx]['source'] = ['network' => $TAILNET];
        }
    }
    if (($r['descr'] ?? '') !== $PASS_DESCR) {
        note($changes, "filter[$pass_idx]: pass descr set");
        if (!$check) {
            $filter[$pass_idx]['descr'] = $PASS_DESCR;
        }
    }
}

/* 3b. Insert the CCTV block BEFORE the pass rule. pfSense rules are
 *     first-match-wins per interface, so order is load-bearing: after the pass
 *     rule this block would never be evaluated. This is defence in depth — the
 *     Headscale ACL already withholds RFC1918 from family exit-node grants, but
 *     group:admin's *:* rule would otherwise reach the cameras. */
if (!$have_block) {
    $block = [
        'id'          => '',
        'tracker'     => (string) time(),
        'type'        => 'block',
        'interface'   => 'Tailscale',
        'ipprotocol'  => 'inet',
        'statetype'   => 'keep state',
        'source'      => ['network' => $TAILNET],
        'destination' => ['network' => $CCTV_NET],
        'descr'       => $BLOCK_DESCR,
        'created'     => ['time' => (string) time(), 'username' => 'ansible (pfsense-tailscale)'],
        'updated'     => ['time' => (string) time(), 'username' => 'ansible (pfsense-tailscale)'],
    ];
    $at = $pass_idx !== null ? $pass_idx : count($filter);
    note($changes, "filter[$at]: ADD block $TAILNET -> $CCTV_NET (before the pass rule)");
    if (!$check) {
        array_splice($filter, $at, 0, [$block]);
    }
}

/* ── 4. Commit ──────────────────────────────────────────────────────────── */
$result = ['changed' => count($changes) > 0, 'check_mode' => $check, 'changes' => $changes];

if (!$check && count($changes) > 0) {
    write_config('pfsense-tailscale subnet router (ansible)');
    // Regenerate both rc.conf.d files from config.xml and restart tailscaled if
    // they changed. This is the package's own sync entry point — the reason the
    // settings survive a reboot at all.
    tailscale_resync_config_hook();
    filter_configure();
    $result['applied'] = true;
}

echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
