<?php
/*
 * Set OPNsense's NTP servers in config.xml, idempotently. Used by tasks/opnsense/ntp.yml.
 * argv: servers (space separated), pool servers (space separated), interfaces
 * (comma separated, empty = all), check|apply. Prints "changed: ..." or "unchanged".
 */
require_once 'config.inc';
require_once 'util.inc';

use OPNsense\Core\Config;

[$self, $servers, $pools, $ifs, $mode] = array_pad($argv, 5, '');
$servers = trim($servers);
$prefer = explode(' ', $servers)[0];
$cfg = Config::getInstance()->object();
if (!isset($cfg->ntpd)) {
    $cfg->addChild('ntpd');
}
$want = [
    'timeservers' => $servers,
    'ispool' => trim($pools),
    'prefer' => $prefer,
    'interface' => trim($ifs),
];
$cur = [
    'timeservers' => (string)$cfg->system->timeservers,
    'ispool' => (string)$cfg->ntpd->ispool,
    'prefer' => (string)$cfg->ntpd->prefer,
    'interface' => (string)$cfg->ntpd->interface,
];
$diff = [];
foreach ($want as $k => $v) {
    if ($cur[$k] !== $v) {
        $diff[] = "$k: '{$cur[$k]}' -> '$v'";
    }
}
if (empty($diff)) {
    echo "unchanged\n";
    exit(0);
}
echo "changed: " . implode('; ', $diff) . "\n";
if ($mode !== 'apply') {
    exit(0);
}
$cfg->system->timeservers = $want['timeservers'];
$cfg->ntpd->ispool = $want['ispool'];
$cfg->ntpd->prefer = $want['prefer'];
if ($want['interface'] === '') {
    unset($cfg->ntpd->interface);
} else {
    $cfg->ntpd->interface = $want['interface'];
}
Config::getInstance()->save();
exec('/usr/local/sbin/pluginctl -s ntpd restart 2>&1', $out, $rc);
if ($rc !== 0) {
    echo "error: ntpd restart failed: " . implode(' ', $out) . "\n";
    exit(1);
}
