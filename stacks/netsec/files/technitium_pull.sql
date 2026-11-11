-- Copies new rows of Technitium's Postgres query log (technitium.dns_logs on
-- pg-cluster) into netsec.technitium. Run by technitium_pull.sh with
-- {pw} (Vault static role pg-technitium), {lo} and {hi}: dlid > lo AND dlid <= hi.
-- lo sits OVERLAP rows below the newest dlid already copied, so a row whose
-- transaction committed after a higher dlid was copied is still picked up;
-- the NOT IN keeps each dlid to one copy, which keeps technitium_hourly exact.
-- Rows from the last minute wait for the next run.
-- dlid is selected bare: an alias such as toUInt64(dlid) AS dlid makes the
-- WHERE apply to the alias, which ClickHouse cannot send to Postgres, and
-- every run then reads the whole table (seen 2026-11-11: 8 GB per run).
-- Codes as Technitium and its Grafana dashboard use them: response_type 1-6,
-- of which 4-6 are blocks; rcode and qtype are DNS numbers.
INSERT INTO netsec.technitium
SELECT
    toDateTime64(timestamp, 6, 'UTC') AS ts,
    dlid,
    replaceRegexpOne(ifNull(server, ''), '-[a-z0-9]+-[a-z0-9]+$', '') AS instance,
    ifNull(server, '') AS server,
    toIPv6(client_ip) AS client_ip,
    transform(toInt32(protocol), [0, 1], ['udp', 'tcp'], toString(protocol)) AS protocol,
    transform(toInt32(response_type), [1, 2, 3, 4, 5, 6],
              ['authoritative', 'recursive', 'cached', 'blocked', 'upstream_blocked', 'upstream_blocked_cached'],
              toString(response_type)) AS response,
    response_type IN (4, 5, 6) AS blocked,
    transform(toInt32(rcode), [0, 1, 2, 3, 4, 5], ['NOERROR', 'FORMERR', 'SERVFAIL', 'NXDOMAIN', 'NOTIMP', 'REFUSED'],
              toString(rcode)) AS rcode,
    ifNull(qname, '') AS qname,
    transform(toInt32(ifNull(qtype, 0)), [1, 2, 5, 6, 12, 15, 16, 28, 33, 64, 65, 255],
              ['A', 'NS', 'CNAME', 'SOA', 'PTR', 'MX', 'TXT', 'AAAA', 'SRV', 'SVCB', 'HTTPS', 'ANY'],
              toString(ifNull(qtype, 0))) AS qtype,
    toFloat32(ifNull(response_rtt, 0)) AS response_rtt,
    ifNull(answer, '') AS answer
FROM postgresql('pg-cluster-rw.dbaas.svc.cluster.local:5432', 'technitium', 'dns_logs', 'technitium', {pw:String})
WHERE dlid > {lo:UInt64} AND dlid <= {hi:UInt64}
  AND timestamp < now() - INTERVAL 1 MINUTE
  AND dlid NOT IN (SELECT dlid FROM netsec.technitium WHERE dlid > {lo:UInt64});
