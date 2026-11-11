<?php
/*
 * Turn on OPNsense's built-in 2 GB swap file (System > Settings > Miscellaneous,
 * config.xml system/use_swap_file), idempotently, and activate it without a
 * reboot. Used by tasks/opnsense/swap.yml.
 * argv: check|apply. Prints "changed: ..." or "unchanged".
 *
 * Why: a Suricata rule reload briefly holds two copies of the detection engine
 * (about 1 GB more), which left under 200 MB free on the 8 GB VM with no swap
 * (2026-11-11). Swap absorbs that, so reloads and restarts need no quiet hour.
 */
require_once 'config.inc';
require_once 'util.inc';

use OPNsense\Core\Config;

$mode = $argv[1] ?? 'check';
$cfg = Config::getInstance()->object();
$diff = [];
if ((string)$cfg->system->use_swap_file !== '2048') {
    $diff[] = "use_swap_file: '" . (string)$cfg->system->use_swap_file . "' -> '2048'";
}
exec('/usr/sbin/swapinfo 2>/dev/null | /usr/bin/grep -c /dev/md98', $out, $rc);
$active = (int)trim($out[0] ?? '0') > 0;
if (!$active) {
    $diff[] = 'swap file not active';
}
if (empty($diff)) {
    echo "unchanged\n";
    exit(0);
}
echo "changed: " . implode('; ', $diff) . "\n";
if ($mode !== 'apply') {
    exit(0);
}
if ((string)$cfg->system->use_swap_file !== '2048') {
    $cfg->system->use_swap_file = '2048';
    Config::getInstance()->save();
}
if (!$active) {
    // The same script OPNsense runs at boot: creates /usr/swap0 and swaps on md98.
    exec('/bin/sh /usr/local/etc/rc.subr.d/swapon 2>&1', $out2, $rc2);
    exec('/usr/sbin/swapinfo 2>/dev/null | /usr/bin/grep -c /dev/md98', $out3);
    if ((int)trim($out3[0] ?? '0') === 0) {
        echo "error: swap file did not activate: " . implode(' ', $out2) . "\n";
        exit(1);
    }
}
