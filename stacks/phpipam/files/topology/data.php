<?php
// Live data for the network topology page (index.html), as JSON.
//
// Subnets and network devices come from phpIPAM's database, which the
// phpipam-import CronJob refreshes every 5 minutes. Device status is measured
// on every request: each network device address is pinged once through the
// cluster's blackbox exporter, all in parallel, so a request takes about as
// long as the slowest answer (3 s at most for an address that does not reply).
//
// Served by phpIPAM's own Apache at /topology/data.php; through Traefik it sits
// behind the same Authentik login as phpIPAM.

header('Content-Type: application/json');
header('Cache-Control: no-store');

// devices.yaml types that are drawn and probed. Servers and VMs are not.
const NETWORK_TYPES = ['Router', 'Firewall', 'Wireless', 'Switch'];
const PROBE_TIMEOUT_S = 3;

function fail(int $code, string $message): void
{
    http_response_code($code);
    echo json_encode(['error' => $message]);
    exit;
}

try {
    $db = new PDO(
        'mysql:host=' . getenv('IPAM_DATABASE_HOST') . ';dbname=' . getenv('IPAM_DATABASE_NAME'),
        getenv('IPAM_DATABASE_USER'),
        getenv('IPAM_DATABASE_PASS'),
        // dbaas serves a self-signed certificate.
        [PDO::MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => false, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
} catch (PDOException $e) {
    fail(503, 'phpIPAM database unreachable');
}

$subnets = [];
$rows = $db->query(
    'SELECT s.id, s.sectionId, s.subnet, s.mask, COALESCE(s.description, \'\') AS description, l.name AS location,'
    . ' COUNT(i.id) AS addresses,'
    . ' COALESCE(SUM(i.lastSeen >= UTC_TIMESTAMP() - INTERVAL 1 HOUR), 0) AS seen_hour'
    . ' FROM subnets s LEFT JOIN locations l ON l.id = s.location LEFT JOIN ipaddresses i ON i.subnetId = s.id'
    . ' WHERE s.isFolder = 0 GROUP BY s.id'
);
foreach ($rows as $r) {
    // phpIPAM stores addresses as decimal strings; anything past 32 bits is IPv6.
    if ($r['subnet'] === null || $r['subnet'] === '' || strlen($r['subnet']) > 10 || (float)$r['subnet'] > 4294967295) {
        continue;
    }
    $subnets[] = [
        'id' => (int)$r['id'],
        'section' => (int)$r['sectionId'],
        'cidr' => long2ip((int)$r['subnet']) . '/' . (int)$r['mask'],
        'description' => $r['description'],
        'location' => $r['location'],
        'addresses' => (int)$r['addresses'],
        'seen_hour' => (int)$r['seen_hour'],
    ];
}

$placeholders = implode(',', array_fill(0, count(NETWORK_TYPES), '?'));
$stmt = $db->prepare(
    'SELECT d.id, d.hostname, t.tname, IF(d.Vendor <> \'\' AND d.Model <> \'\', CONCAT(d.Vendor, \' \', d.Model), \'\') AS model, l.name AS location, i.ip_addr, i.subnetId'
    . ' FROM devices d JOIN deviceTypes t ON t.tid = d.type LEFT JOIN locations l ON l.id = d.location'
    . " JOIN ipaddresses i ON i.switch = d.id WHERE t.tname IN ($placeholders) ORDER BY d.id, i.ip_addr"
);
$stmt->execute(NETWORK_TYPES);
$devices = [];
foreach ($stmt as $r) {
    $id = (int)$r['id'];
    $devices[$id] ??= ['id' => $id, 'name' => $r['hostname'], 'type' => $r['tname'], 'model' => $r['model'], 'location' => $r['location'], 'addresses' => []];
    $devices[$id]['addresses'][] = ['ip' => long2ip((int)$r['ip_addr']), 'subnet' => (int)$r['subnetId'], 'probe' => null];
}

// One ICMP probe per address, in parallel. A probe that could not run at all
// (blackbox down) stays null and the page shows the device as unknown.
$multi = curl_multi_init();
$handles = [];
foreach ($devices as $d) {
    foreach ($d['addresses'] as $a) {
        if (isset($handles[$a['ip']])) {
            continue;
        }
        $h = curl_init(getenv('BLACKBOX_URL') . '/probe?module=icmp_egress&target=' . urlencode($a['ip']));
        curl_setopt_array($h, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => PROBE_TIMEOUT_S + 2,
            // blackbox bounds the probe by the timeout Prometheus would send.
            CURLOPT_HTTPHEADER => ['X-Prometheus-Scrape-Timeout-Seconds: ' . PROBE_TIMEOUT_S],
        ]);
        curl_multi_add_handle($multi, $h);
        $handles[$a['ip']] = $h;
    }
}
do {
    $status = curl_multi_exec($multi, $running);
    if ($running) {
        curl_multi_select($multi, 1.0);
    }
} while ($running && $status === CURLM_OK);

$probes = [];
foreach ($handles as $ip => $h) {
    $body = curl_multi_getcontent($h);
    if (curl_getinfo($h, CURLINFO_HTTP_CODE) === 200 && preg_match('/^probe_success (\S+)$/m', $body, $m)) {
        $up = (float)$m[1] === 1.0;
        $ms = null;
        if ($up && preg_match('/^probe_icmp_duration_seconds\{phase="rtt"\} (\S+)$/m', $body, $rtt)) {
            $ms = round((float)$rtt[1] * 1000, 1);
        }
        $probes[$ip] = ['up' => $up, 'ms' => $ms];
    }
    curl_multi_remove_handle($multi, $h);
}
curl_multi_close($multi);

foreach ($devices as &$d) {
    foreach ($d['addresses'] as &$a) {
        $a['probe'] = $probes[$a['ip']] ?? null;
    }
}
unset($d, $a);

echo json_encode([
    'generated' => gmdate('c'),
    'probes' => count($probes) . '/' . count($handles),
    'subnets' => $subnets,
    'devices' => array_values($devices),
]);
