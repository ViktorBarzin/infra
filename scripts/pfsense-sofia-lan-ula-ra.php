<?php
// pfSense router advertisement on the WAN leg — a private IPv6 prefix for the
// Sofia home LAN (192.168.1.0/24), so the front-door Matter lock stays
// reachable (infra #102).
//
//   pfSense vtnet0 (WAN, 192.168.1.2) radvd → RA on the home LAN:
//     prefix fdfe:e989:d3ce:1::/64, on-link + autonomous (SLAAC)
//     router lifetime 0, M and O flags off, no RDNSS, no DNSSL
//
// WHY: Matter is IPv6-only, and the lock (ASSA ABLOY/Yale, 192.168.1.61,
// MAC b0:44:9c:14:0d:e5) never answers on its link-local address, so it needs
// a routable address on the LAN. Until 2026-09-22 it used a bogus 6to4 prefix
// (2002::/64) that the TP-Link AX6000 advertised from a stale static LAN
// setting. A router reload that night moved that RA off the wired side, so
// ha-sofia lost its route to the lock and lock.front_door_matter was
// unavailable for 12 h. The AX6000 cannot carry this prefix: its prefix field
// rejects anything that does not start with 2 or 3, and it has no
// router-lifetime setting.
//
// The prefix is a ULA (RFC 4193; global ID fdfe:e989:d3ce generated
// 2026-09-23, subnet 1 = the home LAN). A host whose only IPv6 address is a
// ULA keeps using IPv4 for every name that has an A record (RFC 6724 rule 5),
// so devices get a local IPv6 address and no IPv6 internet. Router lifetime 0
// keeps pfSense off every host's default-router list, and radvd-dns=disabled
// keeps pfSense's resolver out of every client's DNS configuration.
//
// ONE THING pfSense ADDS ON ITS OWN: services_radvd_configure() writes
// `route ::/0` into every RA it generates (a route information option, RFC
// 4191), and no setting omits it. Linux, Windows and Android kernels install
// an IPv6 default route from that option even at router lifetime 0. Traffic
// that follows it is dropped at pfSense's WAN, and RFC 6724 still puts IPv4
// first for dual-stack names. rapriority=low makes that route lose to any real
// IPv6 router that appears on the LAN later, for example native A1 IPv6 on
// the AX6000.
//
// THE GUI EQUIVALENT: Interfaces > WAN, IPv6 Configuration Type = Static IPv6,
// address fdfe:e989:d3ce:1::1/64, no gateway. Then Services > Router
// Advertisement > WAN tab (it appears once WAN has a static IPv6): Router mode
// Unmanaged, Router priority Low, Router lifetime 0, "Provide DNS configuration
// via radvd" unchecked.
//
// GOTCHA: do not save the WAN Router Advertisement page in the GUI. Its Router
// lifetime input has min=1 in the HTML, so the browser refuses 0, and the only
// way past that is to clear the field. A blank lifetime becomes
// 3 x MaxRtrAdvInterval = 1800 s, which makes pfSense the default router for
// the whole home LAN. Re-run this script instead.
//
// APPLYING WITHOUT A WAN BOUNCE: interface_configure('wan') restarts dhclient
// on WAN, so this script adds the address with ifconfig and lets
// services_radvd_configure() send radvd a HUP. A HUP reload sends no shutdown
// RA, so the management LAN's RA on vtnet1 does not blip. At boot pfSense
// applies the static address from config.xml itself.
//
// USAGE
//   scp infra/scripts/pfsense-sofia-lan-ula-ra.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-sofia-lan-ula-ra.php'
//
// REVERT: Interfaces > WAN, IPv6 Configuration Type = None (it was 6to4 before
// this script, which did nothing because WAN's IPv4 address is private), and
// clear the WAN Router Advertisement settings, then Save/Apply. Hosts drop the
// address when its valid lifetime runs out, within 24 h.
//
// IDEMPOTENT: re-runs converge. Nothing is written or reloaded when config,
// interface address and radvd.conf already match.
//
// Checking it: `grep -A25 'interface vtnet0' /var/etc/radvd.conf` on pfSense.
// On the PVE host, `tcpdump -i vmbr0 -nn -vv 'icmp6 and ip6[40]==134'` shows
// the RA from pfSense's WAN link-local fe80::be24:11ff:fed7:3fba.

require_once('/etc/inc/config.inc');
require_once('/etc/inc/interfaces.inc');
require_once('/etc/inc/services.inc');
require_once('/etc/inc/filter.inc');
require_once('/etc/inc/util.inc');

global $config;
parse_config(true);

$IFACE    = 'wan';
$ULA_ADDR = 'fdfe:e989:d3ce:1::1';
$ULA_PLEN = '64';
$RA = [
    'ramode'               => 'unmanaged',  // on-link + autonomous prefix, M and O off
    'rapriority'           => 'low',        // the forced route ::/0 loses to a real router
    'raadvdefaultlifetime' => '0',          // not a default router
    'radvd-dns'            => 'disabled',   // no RDNSS, no DNSSL
];

if (!isset($config['interfaces'][$IFACE]) || !is_array($config['interfaces'][$IFACE])) {
    fwrite(STDERR, "ERROR: no interfaces/{$IFACE} in config; refusing to guess.\n");
    exit(1);
}

$changes = [];

$wan = &$config['interfaces'][$IFACE];
if (($wan['ipaddrv6'] ?? '') !== $ULA_ADDR || ($wan['subnetv6'] ?? '') !== $ULA_PLEN) {
    $changes[] = sprintf("interfaces/%s ipv6: '%s/%s' -> '%s/%s'", $IFACE,
                         $wan['ipaddrv6'] ?? '', $wan['subnetv6'] ?? '', $ULA_ADDR, $ULA_PLEN);
    $wan['ipaddrv6'] = $ULA_ADDR;
    $wan['subnetv6'] = $ULA_PLEN;
}

if (!isset($config['dhcpdv6'][$IFACE]) || !is_array($config['dhcpdv6'][$IFACE])) {
    $config['dhcpdv6'][$IFACE] = [];
}
$ra = &$config['dhcpdv6'][$IFACE];
foreach ($RA as $key => $want) {
    if (($ra[$key] ?? null) !== $want) {
        $changes[] = sprintf("dhcpdv6/%s/%s: %s -> '%s'", $IFACE, $key,
                             var_export($ra[$key] ?? null, true), $want);
        $ra[$key] = $want;
    }
}

if ($changes) {
    write_config("Sofia LAN ULA router advertisement on WAN (infra #102)");
}

// Put the address on the interface now; see APPLYING WITHOUT A WAN BOUNCE.
$realif = get_real_interface($IFACE);
$have = false;
foreach (pfSense_getall_interface_addresses($realif) as $entry) {
    $ip = explode('/', $entry)[0];
    if (is_ipaddrv6($ip) && inet_pton($ip) === inet_pton($ULA_ADDR)) {
        $have = true;
    }
}
if (!$have) {
    mwexec('/sbin/ifconfig ' . escapeshellarg($realif) . ' inet6 ' . escapeshellarg($ULA_ADDR) .
           ' prefixlen ' . escapeshellarg($ULA_PLEN) . ' alias');
    $changes[] = "added {$ULA_ADDR}/{$ULA_PLEN} to {$realif}";
}

$radvdconf = (string)@file_get_contents('/var/etc/radvd.conf');
if ($changes || strpos($radvdconf, "interface {$realif} {") === false) {
    services_radvd_configure();
    filter_configure();
    $radvdconf = (string)@file_get_contents('/var/etc/radvd.conf');
}

echo $changes ? implode("\n", $changes) . "\n" : "already converged, nothing changed.\n";

// Print the stanza radvd is now running for WAN.
$start = strpos($radvdconf, "interface {$realif} {");
if ($start === false) {
    fwrite(STDERR, "ERROR: radvd.conf has no stanza for {$realif}.\n");
    exit(1);
}
$end = strpos($radvdconf, "\n};", $start);
echo substr($radvdconf, $start, ($end === false ? strlen($radvdconf) : $end + 3) - $start) . "\n";
echo "done.\n";
