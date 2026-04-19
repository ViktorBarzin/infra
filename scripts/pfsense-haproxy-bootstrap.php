<?php
// pfSense HAProxy bootstrap — configures the mailserver PROXY-v2 path
// (bd code-yiu, Phases 2/3 + 5).
//
// WHY THIS EXISTS
//   pfSense HAProxy config is stored XML-in-`/cf/conf/config.xml` under
//   `<installedpackages><haproxy>`. That file IS picked up by the nightly
//   `daily-backup` on the PVE host (see `scripts/daily-backup.sh` → `scp
//   root@10.0.20.1:/cf/conf/config.xml`) and synced to Synology. This script
//   is the canonical reproducer: run it to rebuild the pfSense HAProxy config
//   from scratch (DR restore, fresh pfSense install, etc.).
//
// WHAT IT BUILDS
//   4 backend pools — one per mail port:
//     mailserver_nodes_smtp  → k8s-node1..4:30125 (container :2525 postscreen)
//     mailserver_nodes_smtps → k8s-node1..4:30126 (container :4465 smtps)
//     mailserver_nodes_sub   → k8s-node1..4:30127 (container :5587 submission)
//     mailserver_nodes_imaps → k8s-node1..4:30128 (container :10993 IMAPS)
//   Each server uses `send-proxy-v2` and TCP health-check every 120s.
//   4 frontends on pfSense 10.0.20.1:{25,465,587,993} TCP mode.
//   + 1 legacy test frontend on :2525 (kept for validation; safe to remove later).
//
// USAGE (on pfSense host, via SSH as admin)
//   scp infra/scripts/pfsense-haproxy-bootstrap.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-haproxy-bootstrap.php'
//
// IDEMPOTENCY
//   Removes any existing entries named mailserver_* before re-adding, so
//   repeat runs are safe and behave as reset-to-declared.

require_once('/etc/inc/config.inc');
require_once('/usr/local/pkg/haproxy/haproxy.inc');
require_once('/usr/local/pkg/haproxy/haproxy_utils.inc');

global $config;
parse_config(true);

if (!is_array($config['installedpackages']['haproxy'])) {
    $config['installedpackages']['haproxy'] = [];
}
$h = &$config['installedpackages']['haproxy'];

$h['enable']  = 'yes';
$h['maxconn'] = '1000';

// Our declared object names (anything starting with mailserver_ is ours)
$POOL_NAMES = [
    'mailserver_nodes',          // legacy (Phase 2/3 test)
    'mailserver_nodes_smtp',
    'mailserver_nodes_smtps',
    'mailserver_nodes_sub',
    'mailserver_nodes_imaps',
];
$FRONTEND_NAMES = [
    'mailserver_proxy_test',     // legacy (Phase 2/3 test, :2525)
    'mailserver_proxy_25',
    'mailserver_proxy_465',
    'mailserver_proxy_587',
    'mailserver_proxy_993',
];

// k8s workers. Not in the cluster: master (control-plane) and node5
// (doesn't exist in this topology).
$NODES = [
    ['k8s-node1', '10.0.20.101'],
    ['k8s-node2', '10.0.20.102'],
    ['k8s-node3', '10.0.20.103'],
    ['k8s-node4', '10.0.20.104'],
];

function build_pool(string $name, string $nodeport, array $nodes): array {
    $servers = [];
    foreach ($nodes as $n) {
        $servers[] = [
            'name'       => $n[0],
            'address'    => $n[1],
            'port'       => $nodeport,
            'weight'     => '10',
            'ssl'        => '',
            // check every 2 min — send-proxy-v2 check + close generates
            // noise on postscreen, not worth doing more often.
            'checkinter' => '120000',
            'advanced'   => 'send-proxy-v2',
            'status'     => 'active',
        ];
    }
    return [
        'name'                   => $name,
        'balance'                => 'roundrobin',
        'check_type'             => 'TCP',
        'checkinter'             => '120000',
        'retries'                => '3',
        'ha_servers'             => ['item' => $servers],
        'advanced_bind'          => '',
        'persist_cookie_enabled' => '',
        'transparent_clientip'   => '',
        'advanced'               => '',
    ];
}

function build_frontend(string $name, string $descr, string $extaddr, string $port, string $pool): array {
    return [
        'name'      => $name,
        'descr'     => $descr,
        'status'    => 'active',
        'secondary' => '',
        'type'      => 'tcp',
        'a_extaddr' => ['item' => [[
            'extaddr'          => $extaddr,
            'extaddr_port'     => $port,
            'extaddr_ssl'      => '',
            'extaddr_advanced' => '',
        ]]],
        'backend_serverpool' => $pool,
        'ha_acls'    => '',
        'dontlognull'=> '',
        'httpclose'  => '',
        'forwardfor' => '',
        'advanced'   => '',
    ];
}

// ── Backend pools ───────────────────────────────────────────────────────
if (!is_array($h['ha_pools']))         $h['ha_pools']         = ['item' => []];
if (!is_array($h['ha_pools']['item'])) $h['ha_pools']['item'] = [];
$h['ha_pools']['item'] = array_values(array_filter(
    $h['ha_pools']['item'],
    fn($p) => !in_array($p['name'] ?? '', $POOL_NAMES, true)
));

// Legacy test pool (still used by the :2525 test frontend for manual SMTP roundtrip).
$h['ha_pools']['item'][] = build_pool('mailserver_nodes',       '30125', $NODES);

// Production pools — one per mail port.
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_smtp',  '30125', $NODES);
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_smtps', '30126', $NODES);
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_sub',   '30127', $NODES);
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_imaps', '30128', $NODES);

// ── Frontends ───────────────────────────────────────────────────────────
if (!is_array($h['ha_backends']))         $h['ha_backends']         = ['item' => []];
if (!is_array($h['ha_backends']['item'])) $h['ha_backends']['item'] = [];
$h['ha_backends']['item'] = array_values(array_filter(
    $h['ha_backends']['item'],
    fn($f) => !in_array($f['name'] ?? '', $FRONTEND_NAMES, true)
));

// Legacy test frontend — :2525 — retained so SMTP roundtrip tests keep working
// without touching the real :25. Safe to remove once fully validated.
$h['ha_backends']['item'][] = build_frontend(
    'mailserver_proxy_test',
    'code-yiu Phase 2/3 test — PROXY v2 to k8s mailserver NodePort 30125 (alt port :2525)',
    '10.0.20.1', '2525',
    'mailserver_nodes'
);

// Production frontends — 4 ports listening on pfSense VLAN20 IP 10.0.20.1.
$h['ha_backends']['item'][] = build_frontend(
    'mailserver_proxy_25',
    'code-yiu Phase 4/5 — external SMTP (:25) via PROXY v2 → pod :2525 postscreen',
    '10.0.20.1', '25',
    'mailserver_nodes_smtp'
);
$h['ha_backends']['item'][] = build_frontend(
    'mailserver_proxy_465',
    'code-yiu Phase 4/5 — external SMTPS (:465) via PROXY v2 → pod :4465 smtpd',
    '10.0.20.1', '465',
    'mailserver_nodes_smtps'
);
$h['ha_backends']['item'][] = build_frontend(
    'mailserver_proxy_587',
    'code-yiu Phase 4/5 — external submission (:587) via PROXY v2 → pod :5587 smtpd',
    '10.0.20.1', '587',
    'mailserver_nodes_sub'
);
$h['ha_backends']['item'][] = build_frontend(
    'mailserver_proxy_993',
    'code-yiu Phase 4/5 — external IMAPS (:993) via PROXY v2 → pod :10993 Dovecot',
    '10.0.20.1', '993',
    'mailserver_nodes_imaps'
);

write_config('code-yiu: mailserver HAProxy — 4 production frontends + legacy :2525 test');

$messages = '';
$rc = haproxy_check_and_run($messages, true);
echo 'haproxy_check_and_run rc=' . ($rc ? 'OK' : 'FAIL') . "\n";
echo "messages: $messages\n";
