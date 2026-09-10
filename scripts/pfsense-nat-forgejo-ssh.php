<?php
// pfSense NAT redirect — git SSH on WAN:22 to the Forgejo SSH service.
//
//   Internet → pfSense WAN:22 → rdr → k8s_shared_lb (10.0.20.200):22
//   → MetalLB → forgejo-ssh Service → forgejo pod :2222 (built-in SSH server)
//
// WHY: forgejo.viktorbarzin.me is moving behind Cloudflare so the crawlers
// that walk its git history meet an edge instead of our origin. Cloudflare
// caps request bodies at 100 MB on our plan and a full push of infra.git is
// 183 MB, so git has to stop riding HTTPS first. SSH never touches Cloudflare,
// so neither the body cap nor the 100 s first-byte timeout applies to git.
//
// Clone URLs use git.viktorbarzin.me, an A record straight to the WAN IP
// (stacks/forgejo/main.tf, cloudflare_record.git). forgejo.viktorbarzin.me
// will resolve to Cloudflare addresses, which carry no SSH.
//
// EXPOSURE: Forgejo's built-in SSH server registers a PublicKeyHandler and no
// password or keyboard-interactive handler (modules/ssh/ssh.go), so it is
// key-only and there is no credential to brute force. CrowdSec's
// cs-firewall-bouncer already drops known-bad addresses in nftables on the
// nodes, which covers non-HTTP traffic like this.
//
// THE GUI EQUIVALENT: Firewall > NAT > Port Forward > Add — interface WAN,
// protocol TCP, destination WAN address port 22, redirect target
// k8s_shared_lb port 22.
//
// USAGE
//   scp infra/scripts/pfsense-nat-forgejo-ssh.php admin@10.0.20.1:/tmp/
//   ssh admin@10.0.20.1 'php /tmp/pfsense-nat-forgejo-ssh.php'
//
// REVERT: Firewall > NAT > Port Forward, delete the rule described
// "Forgejo git SSH", then Apply. Or delete it from config.xml and
// filter_configure().
//
// IDEMPOTENT — re-runs converge; adds nothing if a WAN:22 rdr already exists.
//
// NOT SUFFICIENT ON ITS OWN (found 2026-09-06). pfSense is not the edge: its
// WAN address is 192.168.1.2 and the public address 176.12.22.76 belongs to
// the ISP router at 192.168.1.1, which forwards 443/80/25/465/587/993 down to
// pfSense but not 22. Verified from a genuine external vantage through the UK
// egress proxy: port 443 connects in 0.002 s, port 22 does not connect at all.
// So this rule is correct and loaded, and git SSH still only works from the
// LAN, the cluster and WireGuard until someone adds a matching forward on
// 192.168.1.1.
//
// Checking it: `pfctl -sn | grep ssh` — pfctl prints port 22 by its service
// name, so grepping for "port = 22" finds nothing and looks like failure.

require_once('/etc/inc/config.inc');
require_once('/etc/inc/filter.inc');
require_once('/etc/inc/util.inc');

global $config;
parse_config(true);

$IFACE  = 'wan';
$PORT   = '22';
$TARGET = 'k8s_shared_lb';
$DESCR  = 'Forgejo git SSH — git.viktorbarzin.me';

if (!isset($config['nat']['rule']) || !is_array($config['nat']['rule'])) {
    fwrite(STDERR, "ERROR: no NAT rule array in config; refusing to guess.\n");
    exit(1);
}

// Idempotence: bail if anything already redirects WAN:22.
foreach ($config['nat']['rule'] as $i => $r) {
    if (($r['interface'] ?? '') !== $IFACE) continue;
    $dport = $r['destination']['port'] ?? ($r['local-port'] ?? '');
    if ((string)$dport === $PORT) {
        printf("rule %d already redirects %s:%s -> %s:%s (%s) — nothing to do.\n",
               $i, $IFACE, $PORT, $r['target'] ?? '?', $r['local-port'] ?? '?',
               $r['descr'] ?? '');
        exit(0);
    }
}

$rule = [
    'interface'   => $IFACE,
    'protocol'    => 'tcp',
    'target'      => $TARGET,
    'local-port'  => $PORT,
    'descr'       => $DESCR,
    'associated-rule-id' => 'pass',   // auto-create the matching WAN pass rule
    'source'      => ['any' => ''],
    'destination' => ['network' => 'wanip', 'port' => $PORT],
];

$config['nat']['rule'][] = $rule;

write_config("NAT rdr: WAN:22 -> {$TARGET}:22 (Forgejo git SSH)");

$rc = filter_configure();
printf("added WAN:%s -> %s:%s (%s); filter_configure rc=%s\n",
       $PORT, $TARGET, $PORT, $DESCR, var_export($rc, true));
echo "done.\n";
