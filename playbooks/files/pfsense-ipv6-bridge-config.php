<?php
/*
 * pfsense-ipv6-bridge-config.php — idempotent configurator for the IPv6
 * HAProxy bridge's config.xml entries. Shipped and invoked by
 * playbooks/pfsense-ipv6-bridge.yml.
 *
 * What it manages:
 *   1. Checks that the boot entry running /usr/local/etc/ipv6_proxy.sh exists
 *      (present since 2026-05-30) and exits 2 if it does not.
 *   2. A cron item running /usr/local/etc/ipv6_proxy_watchdog.sh every 5
 *      minutes, which re-runs ipv6_proxy.sh whenever the bridge is not bound.
 *      Added 2026-11-02 after a WireGuard package re-sync regenerated the
 *      webConfigurator nginx config during boot and IPv6 ingress stayed
 *      down for 10 days.
 *
 *   --check   report the diff, write nothing (Ansible --check)
 * Output: JSON {"changed": bool, "changes": [...]}.
 */

require_once('config.inc');
require_once('util.inc');
require_once('functions.inc');
require_once('services.inc');

global $config;
// Never name a variable $g here: it is pfSense's global settings array.

$opts    = getopt('', ['check']);
$check   = array_key_exists('check', $opts);
$changes = [];
$who     = 'ansible (pfsense-ipv6-bridge)';

$BOOT_CMD = '/bin/sh /usr/local/etc/ipv6_proxy.sh';
$WANT_CRON = [
    'minute'  => '*/5',
    'hour'    => '*',
    'mday'    => '*',
    'month'   => '*',
    'wday'    => '*',
    'who'     => 'root',
    'command' => '/bin/sh /usr/local/etc/ipv6_proxy_watchdog.sh',
];

/* ── 1. Boot shellcmd (verified, not written) ───────────────────────────── */
// The live entry is <system><shellcmd><cmd>…</cmd><cmdtype>shellcmd</cmdtype>,
// a shape older than the Shellcmd package's <shellcmdsettings>. Rather than
// guess which shape a rebuilt box wants, only confirm it exists and fail loudly
// if not; add it by hand under Services > Shellcmd in that case.
$has_boot = false;
$boot_sources = [
    $config['system']['shellcmd'] ?? [],
    $config['installedpackages']['shellcmdsettings'] ?? [],
];
foreach ($boot_sources as $src) {
    if (is_string($src)) {
        $has_boot = $has_boot || $src === $BOOT_CMD;
        continue;
    }
    array_walk_recursive($src, function ($v) use (&$has_boot, $BOOT_CMD) {
        $has_boot = $has_boot || $v === $BOOT_CMD;
    });
}
if (!$has_boot) {
    fwrite(STDERR, "boot shellcmd '$BOOT_CMD' is missing from config.xml; add it under Services > Shellcmd\n");
    exit(2);
}

/* ── 2. Watchdog cron item ──────────────────────────────────────────────── */
if (!is_array($config['cron'] ?? null)) {
    $config['cron'] = [];
}
if (!is_array($config['cron']['item'] ?? null)) {
    $config['cron']['item'] = [];
}
$items = &$config['cron']['item'];
$idx = null;
foreach ($items as $i => $it) {
    if (($it['command'] ?? '') === $WANT_CRON['command']) {
        $idx = $i;
    }
}
if ($idx === null) {
    $changes[] = "cron.item: ADD '{$WANT_CRON['minute']} {$WANT_CRON['hour']} * * * {$WANT_CRON['command']}'";
    if (!$check) {
        $items[] = $WANT_CRON;
    }
} else {
    foreach ($WANT_CRON as $k => $v) {
        if (($items[$idx][$k] ?? null) !== $v) {
            $changes[] = "cron.item[$idx].$k: '" . ($items[$idx][$k] ?? '') . "' -> '$v'";
            if (!$check) {
                $items[$idx][$k] = $v;
            }
        }
    }
}

$changed = count($changes) > 0;
if ($changed && !$check) {
    write_config("$who: IPv6 bridge boot hook + watchdog cron");
    configure_cron();
}

echo json_encode(['changed' => $changed, 'changes' => $changes]), "\n";
