<?php
// pfSense HAProxy bootstrap — adds/refreshes the mailserver_proxy_test
// frontend + mailserver_nodes backend for code-yiu (PROXY-v2 SMTP path).
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
//   Backend pool `mailserver_nodes`: 4 k8s workers on NodePort 30125 with
//   `send-proxy-v2` + TCP health-check every 120s.
//   Frontend `mailserver_proxy_test`: listens on 10.0.20.1:2525, TCP mode,
//   forwards to the pool above.
//
// USAGE (on pfSense host, via SSH as admin)
//   scp infra/scripts/pfsense-haproxy-bootstrap.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-haproxy-bootstrap.php'
//
// IDEMPOTENCY
//   Removes any existing entries named `mailserver_nodes` / `mailserver_proxy_test`
//   before re-adding, so repeat runs are safe and behave as reset-to-declared.

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

// ── Backend pool ────────────────────────────────────────────────────────
if (!is_array($h['ha_pools'])) $h['ha_pools'] = ['item' => []];
if (!is_array($h['ha_pools']['item'])) $h['ha_pools']['item'] = [];
$h['ha_pools']['item'] = array_values(array_filter(
    $h['ha_pools']['item'],
    fn($p) => ($p['name'] ?? '') !== 'mailserver_nodes'
));

$servers = [];
foreach ([
    ['k8s-node1', '10.0.20.101'],
    ['k8s-node2', '10.0.20.102'],
    ['k8s-node3', '10.0.20.103'],
    ['k8s-node4', '10.0.20.104'],
] as $n) {
    $servers[] = [
        'name'       => $n[0],
        'address'    => $n[1],
        'port'       => '30125',
        'weight'     => '10',
        'ssl'        => '',
        // check every 2 minutes to avoid flooding postscreen with
        // send-proxy-v2 + immediate close connections (see bd code-yiu notes).
        'checkinter' => '120000',
        'advanced'   => 'send-proxy-v2',
        'status'     => 'active',
    ];
}

$h['ha_pools']['item'][] = [
    'name'                   => 'mailserver_nodes',
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

// ── Frontend (pfSense "ha_backends") ────────────────────────────────────
if (!is_array($h['ha_backends'])) $h['ha_backends'] = ['item' => []];
if (!is_array($h['ha_backends']['item'])) $h['ha_backends']['item'] = [];
$h['ha_backends']['item'] = array_values(array_filter(
    $h['ha_backends']['item'],
    fn($f) => ($f['name'] ?? '') !== 'mailserver_proxy_test'
));

$h['ha_backends']['item'][] = [
    'name'   => 'mailserver_proxy_test',
    'descr'  => 'code-yiu Phase 3 test — PROXY v2 to k8s mailserver NodePort 30125',
    'status' => 'active',
    'secondary' => '',
    'type'   => 'tcp',
    'a_extaddr' => ['item' => [[
        'extaddr'          => '10.0.20.1',
        'extaddr_port'     => '2525',
        'extaddr_ssl'      => '',
        'extaddr_advanced' => '',
    ]]],
    'backend_serverpool' => 'mailserver_nodes',
    'ha_acls'    => '',
    'dontlognull'=> '',
    'httpclose'  => '',
    'forwardfor' => '',
    'advanced'   => '',
];

write_config('code-yiu: mailserver_proxy HAProxy frontend + backend (bootstrap)');

$messages = '';
$rc = haproxy_check_and_run($messages, true);
echo 'haproxy_check_and_run rc=' . ($rc ? 'OK' : 'FAIL') . "\n";
echo "messages: $messages\n";
