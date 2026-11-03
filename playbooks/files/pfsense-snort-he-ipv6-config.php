<?php
/*
 * pfsense-snort-he-ipv6-config.php — keeps Snort inspecting public IPv6 the
 * way it inspects public IPv4. Shipped and invoked by
 * playbooks/pfsense-k8s-ipv6.yml.
 *
 * How IPv6 is inspected: by the WAN instance (vtnet0). Public IPv6 reaches
 * pfSense as 6in4, IPv4 protocol 41 from the HE tunnel server, and Snort
 * decodes the inner IPv6 there (its "IP4/IP6" counter: about 60M packets by
 * 2026-11-03, 57M of them TCP6). Rules that target $HOME_NET only match when
 * HOME_NET holds the IPv6 destinations, and Snort reads HOME_NET at start.
 *
 * Measured 2026-11-03, while adding this: the WAN instance had run since
 * 2026-10-29 with a HOME_NET that predated the VLAN 20 /64, so a Log4j probe
 * over IPv6 to Traefik's ::203 raised no alert while the same probe over IPv4
 * did. A second instance on gif0 is no use: Snort 2 decodes gif's DLT_NULL
 * frames as IPv4 only (it counted 5,122 packets as IP4 with 0 TCP and 0 IP6).
 *
 * What it manages:
 *   1. No Snort instance on HE_IPv6 (gif0). Deletes one if present: stops it,
 *      removes its config entry and its directories.
 *   2. The WAN instance runs with its current snort.conf. sync_snort_package_config()
 *      regenerates every snort.conf (HOME_NET follows the interfaces' current
 *      addresses). The sha256 of the snort.conf the instance last loaded is
 *      kept in /var/run/snort_<uuid>.conf.sha256; when the file's hash
 *      differs (or the stamp is missing, as after a boot), the instance is told
 *      to reload (SIGHUP, snort_reload_config()) and the stamp is rewritten.
 *
 *   --check   report the diff, write nothing (Ansible --check)
 * Output: one JSON line {"changed": bool, "changes": [...]} (last line).
 */

require_once('config.inc');
require_once('util.inc');
require_once('functions.inc');
require_once('/usr/local/pkg/snort/snort.inc');

global $config;
// Never name a variable $g here: it is pfSense's global settings array.

$opts    = getopt('', ['check']);
$check   = array_key_exists('check', $opts);
$changes = [];
$who     = 'ansible (pfsense-k8s-ipv6 snort)';
$NET6    = '2001:470:5a7f:20::/64';

function sn_fail($msg)
{
    fwrite(STDERR, "$msg\n");
    echo json_encode(['changed' => false, 'error' => $msg, 'changes' => []]), "\n";
    exit(2);
}

$if_he = null;
foreach ($config['interfaces'] ?? [] as $k => $ifc) {
    if (($ifc['if'] ?? '') === 'gif0') {
        $if_he = $k;
    }
}
$rules = $config['installedpackages']['snortglobal']['rule'] ?? [];
if (!is_array($rules)) {
    sn_fail('no Snort interfaces configured');
}

/* ── 1. No instance on gif0 ─────────────────────────────────────────────── */
$keep = [];
$gone = [];
foreach ($rules as $r) {
    if ($if_he !== null && ($r['interface'] ?? '') === $if_he) {
        $changes[] = "snort: DELETE instance on $if_he (gif0), uuid " . ($r['uuid'] ?? '?');
        $gone[] = $r;
        continue;
    }
    $keep[] = $r;
}
if ($gone && !$check) {
    foreach ($gone as $r) {
        snort_stop($r, 'gif0');
        $uuid = $r['uuid'] ?? '';
        if (preg_match('/^[0-9]+$/', $uuid)) {
            mwexec('/bin/rm -rf ' . escapeshellarg(SNORTDIR . "/snort_{$uuid}_gif0") . ' '
                . escapeshellarg(SNORTLOGDIR . "/snort_gif0{$uuid}"));
        }
    }
    $config['installedpackages']['snortglobal']['rule'] = $keep;
    write_config("$who: no Snort instance on HE_IPv6 (WAN decodes the 6in4 traffic)");
}

/* ── 2. WAN instance runs with its current snort.conf ───────────────────── */
$wan = null;
foreach ($keep as $r) {
    if (($r['interface'] ?? '') === 'wan') {
        $wan = $r;
    }
}
if ($wan === null || ($wan['enable'] ?? '') !== 'on') {
    sn_fail('the WAN Snort instance is missing or disabled');
}
if (!$check) {
    sync_snort_package_config();
}
$conf = SNORTDIR . "/snort_{$wan['uuid']}_vtnet0/snort.conf";
$home = '';
foreach (@file($conf) ?: [] as $line) {
    if (strpos($line, 'ipvar HOME_NET ') === 0) {
        $home = $line;
    }
}
if (strpos($home, $NET6) === false) {
    $changes[] = "snort: WAN snort.conf HOME_NET lacks $NET6" . ($check ? ' (regenerated on apply)' : '');
}
$pid = trim((string) @file_get_contents("/var/run/snort_{$wan['uuid']}.pid"));
if (!preg_match('/^[0-9]+$/', $pid) || !posix_kill((int) $pid, 0)) {
    sn_fail('the WAN Snort instance is not running');
}
$stamp = "/var/run/snort_{$wan['uuid']}.conf.sha256";
$hash  = hash_file('sha256', $conf);
$was   = trim((string) @file_get_contents($stamp));
if ($hash !== $was) {
    $changes[] = 'snort: RELOAD WAN instance (snort.conf ' . substr($hash, 0, 12) . ' differs from the loaded '
        . ($was === '' ? 'unknown' : substr($was, 0, 12)) . ')';
    if (!$check) {
        snort_reload_config($wan);
        file_put_contents($stamp, "$hash\n");
    }
}

$changed = count($changes) > 0;
echo json_encode(['changed' => $changed, 'check_mode' => $check, 'changes' => $changes]), "\n";
exit(0);
