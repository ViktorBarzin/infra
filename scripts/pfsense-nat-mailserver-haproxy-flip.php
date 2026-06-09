<?php
// pfSense NAT redirect flip — mail ports 25/465/587/993 from
// <mailserver> alias (10.0.20.202 MetalLB LB) to pfSense's own HAProxy
// listener (10.0.20.1). bd code-yiu.
//
// THIS IS THE CUTOVER. After this script:
//   Internet → pfSense WAN:{25,465,587,993} → rdr → 10.0.20.1:{...}
//   (pfSense HAProxy) → send-proxy-v2 → k8s-node:{30125..30128} NodePort
//   → kube-proxy → mailserver pod alt listeners (2525/4465/5587/10993)
//   → Postfix/Dovecot parse PROXY v2 → real client IP recovered.
//
// Internal clients (Roundcube, email-roundtrip-monitor CronJob) continue
// using the existing mailserver ClusterIP Service on the stock ports
// (25/465/587/993) which hit container stock listeners WITHOUT PROXY.
// No change to internal traffic paths.
//
// USAGE
//   scp infra/scripts/pfsense-nat-mailserver-haproxy-flip.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-nat-mailserver-haproxy-flip.php'
//
// REVERT — run pfsense-nat-mailserver-haproxy-unflip.php (companion script).
//
// IDEMPOTENT — re-runs converge. Flips nothing if already pointed at 10.0.20.1.

require_once('/etc/inc/config.inc');
require_once('/etc/inc/filter.inc');

global $config;
parse_config(true);

$PORTS_TO_FLIP = ['25', '465', '587', '993'];
$OLD_TARGET    = 'mailserver';
$NEW_TARGET    = '10.0.20.1';

$changed = 0;
foreach ($config['nat']['rule'] as $i => &$r) {
    $iface = $r['interface'] ?? '';
    $lport = $r['local-port'] ?? '';
    $tgt   = $r['target'] ?? '';

    if ($iface !== 'wan') continue;
    if (!in_array($lport, $PORTS_TO_FLIP, true)) continue;
    if ($tgt !== $OLD_TARGET) {
        printf("rule %d (dport=%s) target=%s — not flipping (already %s or unexpected)\n",
               $i, $lport, $tgt, $NEW_TARGET);
        continue;
    }

    $r['target'] = $NEW_TARGET;
    // Also unset the 'associated-rule-id' linked filter rule target if any —
    // actually pfSense regenerates the associated rule from NAT rule on apply,
    // so leaving associated-rule-id intact is fine.
    $changed++;
    printf("rule %d (dport=%s): target %s → %s\n", $i, $lport, $OLD_TARGET, $NEW_TARGET);
}
unset($r);

if ($changed === 0) {
    echo "No changes. (Already flipped? Run unflip script to revert.)\n";
    exit(0);
}

write_config("code-yiu: NAT rdr — mail ports {$changed} flipped to HAProxy (10.0.20.1)");

// Rebuild pf rules & reload.
$rc = filter_configure();
printf("filter_configure rc=%s\n", var_export($rc, true));
echo "done.\n";
