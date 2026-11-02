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
//   + 6 public IPv6 frontends on the HE tunnel address 2001:470:6e:43d::2
//     (2026-11-02): 443/80 -> Traefik 10.0.20.203 and 25/465/587/993 -> the
//     mail pools above, all send-proxy-v2. They replace the standalone
//     HAProxy bridge (ipv6_proxy.sh, ipv6-haproxy.cfg, rc.d/ipv6proxy and its
//     watchdog), which broke twice: pfSense's nginx took [::]:80 on a config
//     regeneration, and the package's own stop runs `killall haproxy`. Here the
//     package starts, reloads and restarts the one process itself. See
//     docs/research/2026-11-02-reliable-ipv6-ingress.md.
//
// USAGE
//   ansible-playbook -i playbooks/inventory.ini playbooks/pfsense-haproxy.yml --check --diff
//   ansible-playbook -i playbooks/inventory.ini playbooks/pfsense-haproxy.yml
//   (by hand: php -f pfsense-haproxy-bootstrap.php -- [--check])
//
// IDEMPOTENCY
//   Removes the entries it declares (by name) before re-adding them, so
//   repeat runs are safe and behave as reset-to-declared. --check reports
//   which declared entries would change and writes nothing.
//   Output: JSON {"changed": bool, "changes": [...]} (plus haproxy messages).

require_once('/etc/inc/config.inc');
require_once('/usr/local/pkg/haproxy/haproxy.inc');
require_once('/usr/local/pkg/haproxy/haproxy_utils.inc');

global $config;
parse_config(true);

$opts  = getopt('', ['check']);
$check = array_key_exists('check', $opts);
// Snapshot of the declared entries before this run, for --check and "changed".
function declared_snapshot(array $h, array $pools, array $fes): array {
    $snap = [];
    foreach (($h['ha_pools']['item'] ?? []) as $p) {
        if (in_array($p['name'] ?? '', $pools, true)) $snap['pool:' . $p['name']] = json_encode($p);
    }
    foreach (($h['ha_backends']['item'] ?? []) as $f) {
        if (in_array($f['name'] ?? '', $fes, true)) $snap['frontend:' . $f['name']] = json_encode($f);
    }
    $snap['enable']  = $h['enable']  ?? '';
    $snap['maxconn'] = $h['maxconn'] ?? '';
    return $snap;
}

if (!is_array($config['installedpackages']['haproxy'])) {
    $config['installedpackages']['haproxy'] = [];
}
$h = &$config['installedpackages']['haproxy'];

$want_enable  = 'yes';
$want_maxconn = '1000';

// Our declared object names (anything starting with mailserver_ is ours)
$POOL_NAMES = [
    'webgui_traefik_443',        // SNI-routed 443: hostname traffic -> Traefik
    'pfsense_webgui_8443',       // SNI-routed 443: no-SNI / pfsense.* -> webgui
    'mailserver_nodes',          // legacy (Phase 2/3 test)
    'mailserver_nodes_smtp',
    'mailserver_nodes_smtps',
    'mailserver_nodes_sub',
    'mailserver_nodes_imaps',
    'traefik_80',                // public IPv6 :80 -> Traefik web (2026-11-02)
];
$FRONTEND_NAMES = [
    'internal_https_443',        // SNI-routed internal 443 (2026-06-10)
    'mailserver_proxy_test',     // legacy (Phase 2/3 test, :2525)
    'mailserver_proxy_25',
    'mailserver_proxy_465',
    'mailserver_proxy_587',
    'mailserver_proxy_993',
    'ipv6_https_443',            // public IPv6 frontends (2026-11-02)
    'ipv6_http_80',
    'ipv6_smtp_25',
    'ipv6_smtps_465',
    'ipv6_submission_587',
    'ipv6_imaps_993',
];

$before = declared_snapshot($h, $POOL_NAMES, $FRONTEND_NAMES);

// k8s workers. Not in the cluster: master (control-plane) and node5
// (doesn't exist in this topology).
$NODES = [
    ['k8s-node1', '10.0.20.101'],
    ['k8s-node2', '10.0.20.102'],
    ['k8s-node3', '10.0.20.103'],
    ['k8s-node4', '10.0.20.104'],
];

// Build a pool with optional split healthcheck path.
//
// $check_port: if non-null, HAProxy sends health probes to that NodePort
//   (which Service `mailserver-proxy` maps to the pod's stock no-PROXY
//   listener — see infra/stacks/mailserver/.../mailserver_proxy ports
//   30145/30146/30147). Real client traffic still goes to $nodeport with
//   PROXY v2 framing.
// $check_type: 'TCP' for plain accept-on-port checks, 'ESMTP' for
//   `option smtpchk EHLO <monitor_domain>` (real SMTP banner+EHLO+250).
//
// Why split: smtpd-proxy587/4465 fatal on every PROXY-v2-aware health
// probe with `smtpd_peer_hostaddr_to_sockaddr: ... Servname not supported`
// — the daemon respawns get throttled by Postfix master and real clients
// land mid-respawn → 6s TCP timeout. Routing health probes to the stock
// no-PROXY port sidesteps the bug entirely while data path still gets
// PROXY v2 for CrowdSec/Postfix client-IP visibility. The HAProxy package
// has no `checkport` field, so `port N` is appended via the server's
// `advanced` string (HAProxy parses server keywords in any order).
function build_pool(
    string $name,
    string $nodeport,
    array $nodes,
    string $check_type = 'TCP',
    ?string $check_port = null,
    string $monitor_domain = ''
): array {
    $advanced_check = $check_port !== null
        ? "send-proxy-v2 port {$check_port}"
        : 'send-proxy-v2';
    $servers = [];
    foreach ($nodes as $n) {
        $servers[] = [
            'name'       => $n[0],
            'address'    => $n[1],
            'port'       => $nodeport,
            'weight'     => '10',
            'ssl'        => '',
            // 5s = sub-block-window failover when a NodePort goes sour.
            // Safe to be aggressive once health probes don't fatal smtpd.
            'checkinter' => '5000',
            'advanced'   => $advanced_check,
            'status'     => 'active',
        ];
    }
    return [
        'name'                   => $name,
        'balance'                => 'roundrobin',
        'check_type'             => $check_type,
        'monitor_domain'         => $monitor_domain,
        'checkinter'             => '5000',
        'retries'                => '3',
        // 1h idle limit on the server side (HAProxy default 30s). The IPv6
        // frontends allow 1h client idle, as the retired standalone bridge
        // did; the IPv4 mail frontends keep 30s client idle, so their
        // behaviour does not change.
        'server_timeout'         => '3600000',
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
//
// All SMTP/SMTPS/Submission backends use plain TCP checks against
// dedicated non-PROXY healthcheck NodePorts (30145/30146/30147 → pod
// stock 25/465/587) so probes hit the no-PROXY listeners and avoid
// the smtpd_peer_hostaddr_to_sockaddr fatal that fires on PROXY-v2
// LOCAL frames. Real client traffic still goes to 30125-30128 with
// PROXY v2 for client-IP visibility.
//
// We tried `option smtpchk EHLO` initially — it works on the plain
// `submission` daemon (587) but flaps the `postscreen` listener on
// port 25 (multi-line greet + DNSBL silence + anti-pre-greet
// detection makes HAProxy's simple smtpchk parser hit L7RSP). A
// plain TCP accept-on-port check is enough for both: HAProxy still
// gets fast failover when the listener actually goes away, and we
// stop triggering the Postfix fatal entirely.
//
// IMAPS stays on its existing TCP-check-with-PROXY-frame for now —
// Dovecot's PROXY parser doesn't show the same fatal pattern; adding
// a separate IMAP healthcheck path would require another svc port.
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_smtp',  '30125', $NODES, 'TCP', '30145');
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_smtps', '30126', $NODES, 'TCP', '30146');
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_sub',   '30127', $NODES, 'TCP', '30147');
$h['ha_pools']['item'][] = build_pool('mailserver_nodes_imaps', '30128', $NODES);

// ── SNI-routed internal :443 pools (2026-06-10) ─────────────────────────
// Completes the internal port table of 10.0.20.1 so mail.viktorbarzin.me
// (internal A record -> 10.0.20.1) serves webmail too. Routing rule
// (Viktor's design): TLS with a hostname (SNI present) -> Traefik; bare-IP
// /no-SNI (admin hitting https://10.0.20.1) -> pfSense webgui, which moved
// to :8443 to free the socket. pfsense.viktorbarzin.{lan,me} SNI is
// excepted back to the webgui. Traefik leg mirrors the IPv6 bridge:
// send-proxy-v2 (Traefik trusts 10.0.20.1), NO health check (PROXY-
// expecting receivers reject bare probes — see runbook gotcha).
$h['ha_pools']['item'][] = [
    'name'                   => 'webgui_traefik_443',
    'balance'                => '',
    'check_type'             => 'none',
    'monitor_domain'         => '',
    'checkinter'             => '',
    'retries'                => '',
    // 1h idle limit on the server side, as the retired IPv6 bridge had
    // (HAProxy default 30s): a request Traefik answers slowly (a large upload
    // still processing) or a quiet websocket is not cut at 30s.
    'server_timeout'         => '3600000',
    'ha_servers'             => ['item' => [[
        'name'     => 'traefik',
        'address'  => '10.0.20.203',
        'port'     => '443',
        'weight'   => '10',
        'ssl'      => '',
        'advanced' => 'send-proxy-v2',
        'status'   => 'active',
    ]]],
    'advanced_bind'          => '',
    'persist_cookie_enabled' => '',
    'transparent_clientip'   => '',
    'advanced'               => '',
];
$h['ha_pools']['item'][] = [
    'name'                   => 'pfsense_webgui_8443',
    'balance'                => '',
    'check_type'             => 'none',
    'monitor_domain'         => '',
    'checkinter'             => '',
    'retries'                => '',
    'ha_servers'             => ['item' => [[
        'name'     => 'webgui',
        'address'  => '127.0.0.1',
        'port'     => '8443',
        'weight'   => '10',
        'ssl'      => '',
        'advanced' => '',
        'status'   => 'active',
    ]]],
    'advanced_bind'          => '',
    'persist_cookie_enabled' => '',
    'transparent_clientip'   => '',
    'advanced'               => '',
];

// ── Public IPv6 :80 pool (2026-11-02) ───────────────────────────────────
// Same shape as webgui_traefik_443: Traefik trusts PROXY v2 from 10.0.20.1,
// and there is no health check because a bare probe on a PROXY-expecting
// listener fails (runbook gotcha).
$h['ha_pools']['item'][] = [
    'name'                   => 'traefik_80',
    'balance'                => '',
    'check_type'             => 'none',
    'monitor_domain'         => '',
    'checkinter'             => '',
    'retries'                => '',
    // 1h idle limit on the server side, as the retired IPv6 bridge had
    // (HAProxy default 30s): a request Traefik answers slowly (a large upload
    // still processing) or a quiet websocket is not cut at 30s.
    'server_timeout'         => '3600000',
    'ha_servers'             => ['item' => [[
        'name'     => 'traefik',
        'address'  => '10.0.20.203',
        'port'     => '80',
        'weight'   => '10',
        'ssl'      => '',
        'advanced' => 'send-proxy-v2',
        'status'   => 'active',
    ]]],
    'advanced_bind'          => '',
    'persist_cookie_enabled' => '',
    'transparent_clientip'   => '',
    'advanced'               => '',
];

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

// ── SNI-routed internal :443 frontend (2026-06-10) ──────────────────────
// Binds both internal interface IPs so IP-based GUI access works from
// either VLAN. mode tcp + SNI inspection; TLS passthrough on both legs
// (Traefik serves the real certs; the webgui keeps its self-signed one).
$h['ha_backends']['item'][] = [
    'name'      => 'internal_https_443',
    'descr'     => 'SNI-routed internal 443: hostname->Traefik (proxy-v2), no-SNI/pfsense.*->webgui:8443',
    'status'    => 'active',
    'secondary' => '',
    'type'      => 'tcp',
    'a_extaddr' => ['item' => [
        ['extaddr' => 'custom', 'extaddr_custom' => '10.0.20.1', 'extaddr_port' => '443', 'extaddr_ssl' => '', 'extaddr_advanced' => ''],
        ['extaddr' => 'custom', 'extaddr_custom' => '10.0.10.1', 'extaddr_port' => '443', 'extaddr_ssl' => '', 'extaddr_advanced' => ''],
    ]],
    'backend_serverpool' => 'pfsense_webgui_8443',
    'ha_acls'   => ['item' => [
        ['name' => 'sni_pfsense', 'expression' => 'custom', 'value' => 'req.ssl_sni -i -m str pfsense.viktorbarzin.lan pfsense.viktorbarzin.me', 'casesensitive' => '', 'not' => ''],
        ['name' => 'sni_any',     'expression' => 'custom', 'value' => 'req.ssl_sni -m found', 'casesensitive' => '', 'not' => ''],
    ]],
    'a_actionitems' => ['item' => [
        ['action' => 'use_backend', 'use_backendbackend' => 'pfsense_webgui_8443', 'acl' => 'sni_pfsense'],
        ['action' => 'use_backend', 'use_backendbackend' => 'webgui_traefik_443',  'acl' => 'sni_any'],
    ]],
    'dontlognull'=> '',
    'httpclose'  => '',
    'forwardfor' => '',
    'advanced'   => base64_encode("tcp-request inspect-delay 5s\n\ttcp-request content accept if { req.ssl_hello_type 1 } || !{ req.ssl_hello_type 1 }"),
];

// ── Public IPv6 frontends on the HE tunnel address (2026-11-02) ─────────
// One frontend per port so each reads clearly in the GUI and stats. All bind
// with `transparent` (IPV6_BINDANY, compiled into this HAProxy): the bind
// succeeds even if gif0 has not got its address yet at boot, so a slow tunnel
// can never stop the package process, and with it IPv4 mail, from starting.
// The mail frontends share the IPv4 pools and their health checks. The IPv4
// mail frontends bind ':<port>' (all IPv4 addresses), so these never collide.
$TUNNEL_IPV6 = '2001:470:6e:43d::2';
$ipv6_frontends = [
    ['ipv6_https_443',      '443', 'webgui_traefik_443',     'public IPv6 HTTPS -> Traefik :443 (proxy-v2)'],
    ['ipv6_http_80',        '80',  'traefik_80',             'public IPv6 HTTP -> Traefik :80 (proxy-v2)'],
    ['ipv6_smtp_25',        '25',  'mailserver_nodes_smtp',  'public IPv6 SMTP -> mail NodePort 30125 (proxy-v2)'],
    ['ipv6_smtps_465',      '465', 'mailserver_nodes_smtps', 'public IPv6 SMTPS -> mail NodePort 30126 (proxy-v2)'],
    ['ipv6_submission_587', '587', 'mailserver_nodes_sub',   'public IPv6 submission -> mail NodePort 30127 (proxy-v2)'],
    ['ipv6_imaps_993',      '993', 'mailserver_nodes_imaps', 'public IPv6 IMAPS -> mail NodePort 30128 (proxy-v2)'],
];
foreach ($ipv6_frontends as [$name, $port, $pool, $descr]) {
    $h['ha_backends']['item'][] = [
        'name'      => $name,
        'descr'     => $descr,
        'status'    => 'active',
        'secondary' => '',
        'type'      => 'tcp',
        'a_extaddr' => ['item' => [[
            'extaddr'          => 'custom',
            'extaddr_custom'   => $TUNNEL_IPV6,
            'extaddr_port'     => $port,
            'extaddr_ssl'      => '',
            'extaddr_advanced' => 'transparent',
        ]]],
        'backend_serverpool' => $pool,
        // 1h client idle, as the retired standalone bridge had (default 30s).
        'client_timeout'     => '3600000',
        'ha_acls'    => '',
        'dontlognull'=> '',
        'httpclose'  => '',
        'forwardfor' => '',
        'advanced'   => '',
    ];
}

$h['enable']  = $want_enable;
$h['maxconn'] = $want_maxconn;

$after   = declared_snapshot($h, $POOL_NAMES, $FRONTEND_NAMES);
$changes = [];
foreach (array_unique(array_merge(array_keys($before), array_keys($after))) as $k) {
    $b = $before[$k] ?? null;
    $a = $after[$k]  ?? null;
    if ($b === $a) continue;
    $changes[] = ($b === null ? 'ADD ' : ($a === null ? 'DELETE ' : 'UPDATE ')) . $k;
}
$changed = count($changes) > 0;

if ($check) {
    echo json_encode(['changed' => $changed, 'changes' => $changes]), "\n";
    exit(0);
}

$rc = true;
$messages = '';
if ($changed) {
    write_config('ansible (pfsense-haproxy): mail + internal 443 + public IPv6 frontends');
    $rc = haproxy_check_and_run($messages, true);
}
echo json_encode(['changed' => $changed, 'changes' => $changes, 'rc' => $rc ? 'OK' : 'FAIL', 'messages' => trim((string) $messages)]), "\n";
exit($rc ? 0 : 1);
