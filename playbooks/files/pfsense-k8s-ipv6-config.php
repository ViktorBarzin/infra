<?php
/*
 * pfsense-k8s-ipv6-config.php — idempotent configurator for the pfSense side
 * of cluster dual-stack, phase 1 of docs/plans/2026-11-02-cluster-dual-stack.md.
 * Shipped and invoked by playbooks/pfsense-k8s-ipv6.yml.
 *
 * What it manages (interface keys are looked up by device, not hard-coded):
 *   1. HE_IPv6 (gif0): MTU and MSS = --he-mtu (default 1480). pfSense derives
 *      the IPv6 clamp as "max-mss <mss - 60>" (filter.inc, redmine #11409), so
 *      MSS 1480 is what yields the 1420 the plan asks for. Today: 1280 -> 1220.
 *   2. dKubernetes (vtnet2): static 2001:470:5a7f:20::1/64, and router
 *      advertisements off for it (dhcpdv6.<key>.ramode = disabled). The
 *      interface already has a dhcpdv6 entry left over from an old ISP prefix
 *      (ramode stateless_dhcp, 2a00:4802:365:fc02::/64); radvd skips it only
 *      because the interface has no IPv6 address. Without the ramode change,
 *      adding the address would start radvd on VLAN 20 and advertise both
 *      prefixes to every VM there. The DHCPv6 server stays off (no 'enable').
 *   3. dKubernetes inet6 filter rules, in this order, after the existing
 *      (IPv4-only) dKubernetes rules: pass ICMPv6 from the /64; pass the /64 to
 *      the /64 (which includes pfSense's ::1); reject (pf "block return") every
 *      other IPv6 packet entering from VLAN 20. The reject matches any source,
 *      not only the /64, so a pod's ULA-sourced packet is refused at once too
 *      instead of dropped by the default deny. Replies to inbound connections
 *      match their state before any rule. The existing IPv4 rules are untouched
 *      (every rule here is ipprotocol inet6).
 *   4. HE_IPv6 inbound pass rules, inserted just before the existing
 *      "Block all other traffic on HE_IPv6 tunnel": TCP 80/443 + UDP 443 to
 *      ::203 (Traefik), TCP 25/465/587/993 to ::204 (mailserver-v6).
 *   5. Four IPv6 port forwards on HE_IPv6, TCP 25/465/587/993 to ::203 ->
 *      same port on ::204. Created disabled; --mail-forward=1 enables them
 *      (phase 6). No associated filter rule: the ::204 pass rules in (4) are
 *      what the translated packets match.
 *   6. A floating rule: block quick out on HE_IPv6, inet6, source fc00::/7.
 *
 * Every managed rule is found by its description, so the descriptions are
 * stable identifiers: do not edit them in the GUI.
 *
 *   --check            report the diff, write nothing (Ansible --check)
 *   --render           with --check: also print the pf lines filter.inc would
 *                      generate for the managed filter rules (debug aid; it
 *                      updates the GUI's filter-reload status text, nothing else)
 *   --he-mtu=N         gif0 MTU, 1280..1480 (default 1480)
 *   --mail-forward=0|1 enable the ::203 -> ::204 mail port forwards (default 0)
 * Output: one JSON line {"changed": bool, "changes": [...]} (last line).
 */

require_once('config.inc');
require_once('util.inc');
require_once('functions.inc');
require_once('filter.inc');
require_once('interfaces.inc');

global $config;
// Never name a variable $g here: it is pfSense's global settings array, and
// overwriting it makes write_config() emit a config with an empty root
// element, which it then rejects and "repairs" by restoring an older backup.

$opts    = getopt('', ['check', 'render', 'he-mtu:', 'mail-forward:']);
$render  = array_key_exists('render', $opts);
$check   = array_key_exists('check', $opts) || $render;
$he_mtu  = (int) ($opts['he-mtu'] ?? 1480);
$mail_on = in_array(strtolower((string) ($opts['mail-forward'] ?? '0')), ['1', 'true', 'yes'], true);
$changes = [];
$who     = 'ansible (pfsense-k8s-ipv6)';

function k6_fail($msg)
{
    fwrite(STDERR, "$msg\n");
    echo json_encode(['changed' => false, 'error' => $msg, 'changes' => []]), "\n";
    exit(2);
}

if ($he_mtu < 1280 || $he_mtu > 1480) {
    k6_fail("--he-mtu must be 1280..1480, got $he_mtu");
}

/* ── Desired state ──────────────────────────────────────────────────────── */
$K8S_DEV   = 'vtnet2';
$HE_DEV    = 'gif0';
$NET6      = '2001:470:5a7f:20::/64';
$GW6       = '2001:470:5a7f:20::1';
$PLEN6     = '64';
$TRAEFIK6  = '2001:470:5a7f:20::203';
$MAIL6     = '2001:470:5a7f:20::204';
$ULA       = 'fc00::/7';
$MAIL_PORTS = ['25', '465', '587', '993'];
// Hand-made 2026-03 rule closing the HE_IPv6 rule list; ours go before it.
$HE_BLOCK_ALL_DESCR = 'Block all other traffic on HE_IPv6 tunnel';

function k6_iface_key($dev)
{
    global $config;
    $keys = [];
    foreach ($config['interfaces'] ?? [] as $k => $ifc) {
        if (($ifc['if'] ?? '') === $dev) {
            $keys[] = $k;
        }
    }
    if (count($keys) !== 1) {
        k6_fail("expected exactly one interface on $dev, found " . count($keys));
    }
    return $keys[0];
}

$IF_K8S = k6_iface_key($K8S_DEV);
$IF_HE  = k6_iface_key($HE_DEV);

function k6_stamp($who)
{
    return ['time' => (string) time(), 'username' => $who];
}

/* ── 1. HE_IPv6: MTU and MSS ────────────────────────────────────────────── */
$mtu_changed = false;
foreach (['mtu' => (string) $he_mtu, 'mss' => (string) $he_mtu] as $k => $v) {
    $cur = $config['interfaces'][$IF_HE][$k] ?? '';
    if ($cur !== $v) {
        $changes[] = "interfaces.$IF_HE ($HE_DEV).$k: " . var_export($cur, true) . " -> '$v'"
            . ($k === 'mss' ? ' (IPv6 max-mss ' . ($he_mtu - 60) . ')' : '');
        $config['interfaces'][$IF_HE][$k] = $v;
        $mtu_changed = $mtu_changed || $k === 'mtu';
    }
}

/* ── 2. dKubernetes: static IPv6, no RA, no DHCPv6 server ───────────────── */
$addr_changed = false;
$old_v6 = $config['interfaces'][$IF_K8S]['ipaddrv6'] ?? '';
$old_pl = $config['interfaces'][$IF_K8S]['subnetv6'] ?? '';
if ($old_v6 !== $GW6 || $old_pl !== $PLEN6) {
    $changes[] = "interfaces.$IF_K8S ($K8S_DEV).ipaddrv6: " . ($old_v6 === '' ? 'none' : "'$old_v6/$old_pl'") . " -> '$GW6/$PLEN6'";
    $config['interfaces'][$IF_K8S]['ipaddrv6'] = $GW6;
    $config['interfaces'][$IF_K8S]['subnetv6'] = $PLEN6;
    $addr_changed = true;
}
if (!is_array($config['dhcpdv6'] ?? null)) {
    $config['dhcpdv6'] = [];
}
if (!is_array($config['dhcpdv6'][$IF_K8S] ?? null)) {
    $config['dhcpdv6'][$IF_K8S] = [];
}
$d6 = &$config['dhcpdv6'][$IF_K8S];
if (($d6['ramode'] ?? '') !== 'disabled') {
    $changes[] = "dhcpdv6.$IF_K8S.ramode: " . var_export($d6['ramode'] ?? null, true) . " -> 'disabled' (no radvd on VLAN 20)";
    $d6['ramode'] = 'disabled';
}
if (isset($d6['enable'])) {
    $changes[] = "dhcpdv6.$IF_K8S.enable: DELETE (no DHCPv6 server on VLAN 20)";
    unset($d6['enable']);
}
unset($d6);

/* ── Reconciling an ordered list of managed entries ─────────────────────── */
/*
 * $want: ordered [descr => entry]. Managed entries are pulled out of $list,
 * rebuilt from $want (keeping the bookkeeping keys in $keep from the live
 * entry), and put back as one contiguous block at $anchor($rest, $was_at),
 * where $rest is $list without them and $was_at is the index in $rest where
 * the first managed entry used to sit (null if none existed). Reports ADD /
 * UPDATE / DELETE duplicate / MOVE.
 */
function k6_reconcile(array $list, array $want, callable $anchor, array $keep, $label, array &$changes, callable $new_meta)
{
    $existing = [];
    $rest     = [];
    $was_at   = null;
    foreach ($list as $e) {
        $d = $e['descr'] ?? null;
        if ($d !== null && array_key_exists($d, $want)) {
            $was_at = $was_at ?? count($rest);
            if (array_key_exists($d, $existing)) {
                $changes[] = "$label: DELETE duplicate '$d'";
                continue;
            }
            $existing[$d] = $e;
            continue;
        }
        $rest[] = $e;
    }
    $block   = [];
    $touched = false;
    foreach ($want as $d => $w) {
        if (!array_key_exists($d, $existing)) {
            $changes[] = "$label: ADD '$d'";
            $block[]   = $w + $new_meta();
            $touched   = true;
            continue;
        }
        $old = $existing[$d];
        $cmp = array_diff_key($old, array_flip(array_merge($keep, ['updated'])));
        $new = $w;
        foreach ($keep as $k) {
            if (array_key_exists($k, $old)) {
                $new[$k] = $old[$k];
            }
        }
        if ($cmp != $w) {
            $keys = array_unique(array_merge(array_keys($cmp), array_keys($w)));
            // Presence matters too: 'disabled' => '' vs no 'disabled' key.
            $diff = array_values(array_filter($keys, fn($k) => !array_key_exists($k, $cmp)
                || !array_key_exists($k, $w) || $cmp[$k] != $w[$k]));
            $changes[] = "$label: UPDATE '$d' (" . implode(', ', $diff) . ')';
            $new['updated'] = k6_stamp($GLOBALS['who']);
            $touched = true;
        } elseif (array_key_exists('updated', $old)) {
            $new['updated'] = $old['updated'];
        }
        $block[] = $new;
    }
    $pos    = $anchor($rest, $was_at);
    $result = array_merge(array_slice($rest, 0, $pos), $block, array_slice($rest, $pos));
    if (!$touched && $result != $list) {
        $changes[] = "$label: MOVE managed entries into place";
    }
    return $result;
}

/* ── 3-6. Filter rules ──────────────────────────────────────────────────── */
$filter = $config['filter']['rule'] ?? [];
if (!is_array($filter)) {
    $filter = [];
}
$trackers = [];
foreach ($filter as $r) {
    if (isset($r['tracker'])) {
        $trackers[(string) $r['tracker']] = true;
    }
}
$next_tracker = time();
$filter_meta = function () use (&$trackers, &$next_tracker, $who) {
    while (isset($trackers[(string) $next_tracker])) {
        $next_tracker++;
    }
    $t = (string) $next_tracker;
    $trackers[$t] = true;
    return ['id' => '', 'tracker' => $t, 'created' => k6_stamp($who)];
};
$FILTER_KEEP = ['id', 'tracker', 'created'];

function k6_rule($iface, $type, $proto, array $src, array $dst, $descr, array $extra = [])
{
    $r = ['type' => $type, 'interface' => $iface, 'ipprotocol' => 'inet6'];
    if ($proto !== null) {
        $r['protocol'] = $proto;
    }
    return $r + ['statetype' => 'keep state', 'source' => $src, 'destination' => $dst, 'descr' => $descr] + $extra;
}

// pf labels carry the description and are capped at 63 bytes, so keep these short.
$want_k8s = [];
foreach ([
    k6_rule($IF_K8S, 'pass', 'icmp', ['address' => $NET6], ['any' => ''], 'k8s-ipv6: VLAN 20 ICMPv6'),
    k6_rule($IF_K8S, 'pass', null, ['address' => $NET6], ['address' => $NET6], 'k8s-ipv6: VLAN 20 to VLAN 20'),
    k6_rule($IF_K8S, 'reject', null, ['any' => ''], ['any' => ''], 'k8s-ipv6: reject other IPv6 from VLAN 20'),
] as $r) {
    $want_k8s[$r['descr']] = $r;
}

$want_he = [];
$he_pass = [
    ['tcp', $TRAEFIK6, '80', 'k8s-ipv6: HTTP to Traefik ::203'],
    ['tcp', $TRAEFIK6, '443', 'k8s-ipv6: HTTPS to Traefik ::203'],
    ['udp', $TRAEFIK6, '443', 'k8s-ipv6: QUIC to Traefik ::203'],
];
foreach ($MAIL_PORTS as $p) {
    $he_pass[] = ['tcp', $MAIL6, $p, "k8s-ipv6: mail $p to ::204"];
}
foreach ($he_pass as [$proto, $addr, $port, $descr]) {
    $want_he[$descr] = k6_rule($IF_HE, 'pass', $proto, ['any' => ''], ['address' => $addr, 'port' => $port], $descr);
}

$ula_descr  = 'k8s-ipv6: no ULA source out of HE_IPv6';
$want_float = [
    $ula_descr => k6_rule($IF_HE, 'block', null, ['address' => $ULA], ['any' => ''], $ula_descr,
        ['direction' => 'out', 'floating' => 'yes', 'quick' => 'yes']),
];

$last_index = function (array $rest, callable $pred) {
    $idx = -1;
    foreach ($rest as $i => $r) {
        if ($pred($r)) {
            $idx = $i;
        }
    }
    return $idx;
};
$is_if = fn($iface) => fn($r) => ($r['interface'] ?? '') === $iface && !isset($r['floating']);

// VLAN 20: where the block already sits (only inet rules share the list, so
// its place among them does not matter), else after the last VLAN 20 rule.
$filter = k6_reconcile($filter, $want_k8s, function ($rest, $was_at) use ($last_index, $is_if, $IF_K8S) {
    if ($was_at !== null) {
        return $was_at;
    }
    $i = $last_index($rest, $is_if($IF_K8S));
    return $i < 0 ? count($rest) : $i + 1;
}, $FILTER_KEEP, "filter($IF_K8S)", $changes, $filter_meta);

// HE_IPv6: always directly before the tunnel's block-all rule.
$filter = k6_reconcile($filter, $want_he, function ($rest, $was_at) use ($last_index, $is_if, $IF_HE, $HE_BLOCK_ALL_DESCR) {
    foreach ($rest as $i => $r) {
        if (($r['interface'] ?? '') === $IF_HE && !isset($r['floating']) && ($r['descr'] ?? '') === $HE_BLOCK_ALL_DESCR) {
            return $i;
        }
    }
    $i = $last_index($rest, $is_if($IF_HE));
    return $i < 0 ? count($rest) : $i + 1;
}, $FILTER_KEEP, "filter($IF_HE)", $changes, $filter_meta);

$filter = k6_reconcile($filter, $want_float, function ($rest, $was_at) use ($last_index) {
    if ($was_at !== null) {
        return $was_at;
    }
    $i = $last_index($rest, fn($r) => isset($r['floating']));
    return $i < 0 ? count($rest) : $i + 1;
}, $FILTER_KEEP, 'filter(floating)', $changes, $filter_meta);

$config['filter']['rule'] = $filter;

/* ── 5. Mail port forwards ::203 -> ::204 ───────────────────────────────── */
$nat = $config['nat']['rule'] ?? [];
if (!is_array($nat)) {
    $nat = [];
}
$want_rdr = [];
foreach ($MAIL_PORTS as $p) {
    $d = "k8s-ipv6: mail $p on ::203 to ::204";
    $r = [
        'source'             => ['any' => ''],
        'destination'        => ['address' => $TRAEFIK6, 'port' => $p],
        'ipprotocol'         => 'inet6',
        'protocol'           => 'tcp',
        'target'             => $MAIL6,
        'local-port'         => $p,
        'interface'          => $IF_HE,
        'descr'              => $d,
        'associated-rule-id' => '',
    ];
    if (!$mail_on) {
        $r['disabled'] = '';
    }
    $want_rdr[$d] = $r;
}
$nat = k6_reconcile($nat, $want_rdr, fn($rest, $was_at) => $was_at ?? count($rest), ['created'],
    "nat.rule($IF_HE, " . ($mail_on ? 'enabled' : 'disabled') . ')', $changes,
    fn() => ['created' => k6_stamp($who)]);
$config['nat']['rule'] = $nat;

/* ── Render (debug) ─────────────────────────────────────────────────────── */
$rendered = null;
if ($render) {
    // In memory only: $config now holds the candidate, which is never written
    // in check mode. Explicit addresses make the lines independent of whether
    // the interface already holds its IPv6 address.
    filter_generate_optcfg_array();
    $rendered = [];
    foreach ($filter as $r) {
        if (strpos($r['descr'] ?? '', 'k8s-ipv6: ') === 0) {
            $rendered[] = trim(filter_generate_user_rule($r));
        }
    }
}

/* ── Commit ─────────────────────────────────────────────────────────────── */
$changed = count($changes) > 0;
$result  = ['changed' => $changed, 'check_mode' => $check, 'changes' => $changes];
if ($rendered !== null) {
    $result['pf'] = $rendered;
}

if ($changed && !$check) {
    /* Render and re-parse before writing. write_config() restores the newest
     * file in /cf/conf/backup when its own re-parse fails, and that file can
     * be older than the live config, so a config that does not parse must
     * never reach it (same guard as pfsense-vermont-alias-config.php). */
    $tmp = '/tmp/pfsense-k8s-ipv6-candidate.xml';
    file_put_contents($tmp, dump_xml_config($config, g_get('xml_rootobj')));
    $parsed = parse_xml_config($tmp, g_get('xml_rootobj'));
    if (!is_array($parsed)) {
        k6_fail("candidate config does not parse; nothing written ($tmp kept)");
    }
    unlink($tmp);

    write_config("$who: k8s VLAN IPv6, HE MTU $he_mtu, mail forward " . ($mail_on ? 'on' : 'off'));

    // Targeted live changes, not interface_configure(): that would strip and
    // re-add vtnet2's IPv4 address (the cluster's gateway) and gif0's tunnel
    // address (the HAProxy IPv6 frontends). These are the same commands
    // interface_gif_configure() and interface_configure() run for each value.
    if ($mtu_changed) {
        mwexec('/sbin/ifconfig ' . escapeshellarg($HE_DEV) . ' mtu ' . escapeshellarg((string) $he_mtu));
    }
    if ($addr_changed) {
        if (is_ipaddrv6($old_v6) && $old_v6 !== $GW6) {
            mwexec('/sbin/ifconfig ' . escapeshellarg($K8S_DEV) . ' inet6 ' . escapeshellarg($old_v6) . ' delete');
        }
        mwexec('/sbin/ifconfig ' . escapeshellarg($K8S_DEV) . ' inet6 ' . escapeshellarg($GW6) . ' prefixlen ' . escapeshellarg($PLEN6));
    }
    // radvd is not restarted: it skips this interface today (no IPv6 address)
    // and ramode=disabled, written in the same revision, keeps it skipped on
    // every later regeneration.
    //
    // The MSS clamp is a scrub rule, so it rides on the filter reload too.
    filter_configure();
    $result['applied'] = true;
}

echo json_encode($result, JSON_UNESCAPED_SLASHES), "\n";
