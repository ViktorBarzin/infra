<?php
// pfSense NAT — LAN-side redirect for mail ports landing on the Traefik LB IP.
//
// WHY THIS EXISTS
//   Technitium serves Barzini WiFi (192.168.1.0/24) clients a split-horizon
//   answer: `mail.viktorbarzin.me CNAME viktorbarzin.me A 10.0.20.203`.
//   .203 is Traefik's dedicated LB IP — it serves Roundcube on :443 but does
//   NOT listen on mail ports. iOS Mail (which uses 993/465/587) silently
//   hangs.
//
//   Existing pfSense rules redirect WAN-IP:{25,465,587,993} -> 10.0.20.1
//   (pfSense's mail HAProxy listener). But 192.168.1.x clients send to
//   10.0.20.203, not the WAN IP, so those rules don't match.
//
//   This script adds 4 NAT rules that match dst=10.0.20.203 on mail ports
//   and redirect them to 10.0.20.1 — same target as the public-Internet path.
//   Roundcube traffic to :443 stays on Traefik (.203) untouched.
//
// USAGE (on pfSense host, via SSH as admin)
//   scp infra/scripts/pfsense-nat-mail-lan-redirect.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-nat-mail-lan-redirect.php'
//
// IDEMPOTENT — removes prior copies of our rules (by descr prefix) before
// re-adding. Safe to re-run.

require_once('/etc/inc/config.inc');
require_once('/etc/inc/filter.inc');

global $config;
parse_config(true);

$TRAEFIK_LB    = '10.0.20.203';
$MAIL_HAPROXY  = '10.0.20.1';
$DESCR_PREFIX  = 'mail-lan-redirect-';

// One rule per port; protocols match the existing WAN-IP rules so we
// behave identically once the dst is rewritten.
$PORTS = [
    ['25',  'tcp',     'mail-lan-redirect-25  (SMTP)'],
    ['465', 'tcp/udp', 'mail-lan-redirect-465 (SMTPS)'],
    ['587', 'tcp',     'mail-lan-redirect-587 (submission)'],
    ['993', 'tcp/udp', 'mail-lan-redirect-993 (IMAPS)'],
];

// Strip any prior copies we added (descr starts with our prefix).
$kept    = [];
$removed = 0;
foreach (($config['nat']['rule'] ?? []) as $r) {
    if (strpos($r['descr'] ?? '', $DESCR_PREFIX) === 0) {
        $removed++;
        continue;
    }
    $kept[] = $r;
}
printf("Removed %d prior copies\n", $removed);

// Append new rules.
foreach ($PORTS as [$port, $proto, $descr]) {
    $kept[] = [
        'source'      => ['any' => ''],
        'destination' => [
            'address' => $TRAEFIK_LB,
            'port'    => $port,
        ],
        'ipprotocol'        => 'inet',
        'protocol'          => $proto,
        'target'            => $MAIL_HAPROXY,
        'local-port'        => $port,
        'interface'         => 'wan',
        'descr'             => $descr,
        'associated-rule-id'=> 'pass',
        'created'           => [
            'time'     => (string)time(),
            'username' => 'pfsense-nat-mail-lan-redirect.php',
        ],
        'updated'           => [
            'time'     => (string)time(),
            'username' => 'pfsense-nat-mail-lan-redirect.php',
        ],
    ];
    printf("Added: %s (%s %s:%s -> %s:%s)\n", $descr, $proto, $TRAEFIK_LB, $port, $MAIL_HAPROXY, $port);
}

$config['nat']['rule'] = $kept;

write_config('NAT: LAN-side mail redirects — 10.0.20.203:{25,465,587,993} -> 10.0.20.1 for Barzini WiFi clients');

$rc = filter_configure();
printf("filter_configure rc=%s\n", var_export($rc, true));
echo "Done.\n";
