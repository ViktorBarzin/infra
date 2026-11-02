<?php
/*
 * pfsense-ipv6-ingress-config.php — idempotent configurator for the config.xml
 * side of public IPv6 ingress. Shipped and invoked by playbooks/pfsense-haproxy.yml,
 * after the HAProxy package holds the IPv6 frontends.
 *
 * What it manages:
 *   1. system/webgui/disablehttpredirect. pfSense's nginx generator writes its
 *      only port-80 listeners ("listen 80; listen [::]:80;") inside the
 *      HTTP-to-HTTPS redirect block and skips that block when this key is set
 *      (src/etc/inc/system.inc:2012 on 2.7.2). With it set, no regeneration of
 *      the webConfigurator config (boot, package re-sync, certificate or GUI
 *      change) can take port 80 on the HE tunnel address from HAProxy.
 *      Side effect: http://<pfsense>/ no longer redirects to the :8443 GUI.
 *   2. Removes what the retired standalone IPv6 bridge needed: the boot
 *      <shellcmd> running /usr/local/etc/ipv6_proxy.sh and the 5-minute
 *      watchdog cron entry (2026-11-02,
 *      docs/research/2026-11-02-reliable-ipv6-ingress.md).
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
$who     = 'ansible (pfsense-haproxy)';

$LEGACY_BOOT_CMD  = '/bin/sh /usr/local/etc/ipv6_proxy.sh';
$LEGACY_CRON_CMD  = '/bin/sh /usr/local/etc/ipv6_proxy_watchdog.sh';

/* ── 1. No webConfigurator HTTP redirect (frees port 80) ──────────────── */
$restart_webgui = false;
if (!isset($config['system']['webgui']['disablehttpredirect'])) {
    $changes[] = 'system.webgui.disablehttpredirect: ADD (nginx stops listening on port 80)';
    if (!$check) {
        $config['system']['webgui']['disablehttpredirect'] = '';
        $restart_webgui = true;
    }
}

/* ── 2a. Legacy boot shellcmd ──────────────────────────────────────────── */
// The live entry was <system><shellcmd><cmd>…</cmd><cmdtype>shellcmd</cmdtype>;
// a single string or a list of either shape are handled too.
$sc = $config['system']['shellcmd'] ?? null;
$is_legacy = function ($e) use ($LEGACY_BOOT_CMD) {
    return $e === $LEGACY_BOOT_CMD || (is_array($e) && ($e['cmd'] ?? null) === $LEGACY_BOOT_CMD);
};
if ($sc !== null) {
    if ($is_legacy($sc)) {
        $changes[] = "system.shellcmd: DELETE '$LEGACY_BOOT_CMD'";
        if (!$check) {
            unset($config['system']['shellcmd']);
        }
    } elseif (is_array($sc) && array_is_list($sc)) {
        $kept = array_values(array_filter($sc, fn($e) => !$is_legacy($e)));
        if (count($kept) !== count($sc)) {
            $changes[] = "system.shellcmd[]: DELETE '$LEGACY_BOOT_CMD'";
            if (!$check) {
                $config['system']['shellcmd'] = $kept;
            }
        }
    }
}

/* ── 2b. Legacy watchdog cron entry ────────────────────────────────────── */
$cron_changed = false;
$items = $config['cron']['item'] ?? [];
if (is_array($items)) {
    $kept = array_values(array_filter($items, fn($it) => ($it['command'] ?? '') !== $LEGACY_CRON_CMD));
    if (count($kept) !== count($items)) {
        $changes[] = "cron.item: DELETE '$LEGACY_CRON_CMD'";
        if (!$check) {
            $config['cron']['item'] = $kept;
            $cron_changed = true;
        }
    }
}

$changed = count($changes) > 0;
if ($changed && !$check) {
    write_config("$who: no GUI redirect on :80, retire standalone IPv6 bridge hooks");
    if ($cron_changed) {
        configure_cron();
    }
    if ($restart_webgui) {
        // Regenerates /var/etc/nginx-webConfigurator.conf without the redirect
        // block. Backgrounded: it restarts the nginx serving the GUI.
        mwexec_bg('/etc/rc.restart_webgui');
    }
}

echo json_encode(['changed' => $changed, 'changes' => $changes]), "\n";
