-- netsec-alerts (stacks/netsec CronJob, network IDS plan decision 9): Suricata
-- malware and C2 alerts that involve one of our hosts, from the last 15
-- minutes, as an Alertmanager v2 payload. One alert per host and signature;
-- Alertmanager dedupes by labels and resolves it 15 minutes after the last hit.
-- Test: sh stacks/netsec/files/alerts_test.sh
WITH
    -- Our address space as stored in netsec.eve (IPv4 is IPv4-mapped IPv6).
    ['::ffff:10.0.0.0/104', '::ffff:192.168.0.0/112', '::ffff:100.64.0.0/106',
     '2001:470:5a7f::/48', '2001:470:6f:43d::/64', 'fdfe:e989:d3ce::/48', 'fd7a:115c:a1e0::/48'] AS ours
SELECT toJSONString(groupArray(CAST(
    (
        ('NetsecHomeHostMalware', 'security', 'critical', host, toString(signature_id)),
        (
            concat('Home host ', host, ': ', sig),
            concat(sig, ' (', cat, '): ', host, ' and ', arrayStringConcat(peers, ', '),
                   ', ', toString(hits), ' alerts in 15 min, last at ',
                   formatDateTime(last_ts, '%Y-%m-%d %H:%i:%S', 'UTC'), ' UTC. Details: homelab netsec sql',
                   ' "SELECT * FROM netsec.eve WHERE signature_id = ', toString(signature_id),
                   ' ORDER BY ts DESC LIMIT 20" (docs/runbooks/network-ids.md).')
        ),
        formatDateTime(now() + INTERVAL 15 MINUTE, '%Y-%m-%dT%H:%i:%SZ', 'UTC')
    ),
    'Tuple(labels Tuple(alertname String, lane String, severity String, host String, signature_id String), annotations Tuple(summary String, description String), endsAt String)'
)))
FROM
(
    SELECT
        arrayExists(c -> isIPAddressInRange(IPv6NumToString(src_ip), c), ours) AS src_ours,
        replaceRegexpOne(IPv6NumToString(if(src_ours, src_ip, dest_ip)), '^::ffff:', '') AS host,
        signature_id,
        any(signature) AS sig,
        any(category) AS cat,
        count() AS hits,
        max(ts) AS last_ts,
        groupUniqArray(3)(replaceRegexpOne(IPv6NumToString(if(src_ours, dest_ip, src_ip)), '^::ffff:', '')) AS peers
    FROM netsec.eve
    WHERE event_type = 'alert'
      AND ts > now() - INTERVAL 15 MINUTE
      AND (arrayExists(c -> isIPAddressInRange(IPv6NumToString(src_ip), c), ours)
           OR arrayExists(c -> isIPAddressInRange(IPv6NumToString(dest_ip), c), ours))
      AND (
            signature LIKE 'Feodo Tracker:%'
         OR signature LIKE 'SSLBL:%'
         OR signature LIKE 'URLhaus%'
         OR signature LIKE 'ET MALWARE %'
         OR signature LIKE 'ET TROJAN %'
         OR signature LIKE 'ET MOBILE_MALWARE %'
         OR signature LIKE 'ET CNC %'
         -- ET COMPROMISED only when our host starts it: inbound it is a scanner.
         OR (signature LIKE 'ET COMPROMISED %'
             AND arrayExists(c -> isIPAddressInRange(IPv6NumToString(src_ip), c), ours)
             AND NOT arrayExists(c -> isIPAddressInRange(IPv6NumToString(dest_ip), c), ours))
      )
    GROUP BY src_ours, host, signature_id
)
