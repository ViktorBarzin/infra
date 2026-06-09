<?php
// REVERT of pfsense-nat-mailserver-haproxy-flip.php.
// Moves mail-port NAT rdr target from 10.0.20.1 (pfSense HAProxy) back to
// <mailserver> alias (10.0.20.202 MetalLB LB IP). bd code-yiu rollback.
//
// USE THIS IF: external mail breaks after the flip, any postscreen
// PROXY timeouts show up in logs, or you need to back out before Phase 6.

require_once('/etc/inc/config.inc');
require_once('/etc/inc/filter.inc');

global $config;
parse_config(true);

$PORTS_TO_REVERT = ['25', '465', '587', '993'];
$OLD_TARGET      = '10.0.20.1';
$NEW_TARGET      = 'mailserver';

$changed = 0;
foreach ($config['nat']['rule'] as $i => &$r) {
    $iface = $r['interface'] ?? '';
    $lport = $r['local-port'] ?? '';
    $tgt   = $r['target'] ?? '';

    if ($iface !== 'wan') continue;
    if (!in_array($lport, $PORTS_TO_REVERT, true)) continue;
    if ($tgt !== $OLD_TARGET) {
        printf("rule %d (dport=%s) target=%s — not reverting (already %s or unexpected)\n",
               $i, $lport, $tgt, $NEW_TARGET);
        continue;
    }

    $r['target'] = $NEW_TARGET;
    $changed++;
    printf("rule %d (dport=%s): target %s → %s\n", $i, $lport, $OLD_TARGET, $NEW_TARGET);
}
unset($r);

if ($changed === 0) {
    echo "No changes. (Already reverted.)\n";
    exit(0);
}

write_config("code-yiu: NAT rdr — mail ports {$changed} reverted to <mailserver> alias");

$rc = filter_configure();
printf("filter_configure rc=%s\n", var_export($rc, true));
echo "done.\n";
