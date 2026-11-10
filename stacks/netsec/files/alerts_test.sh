#!/bin/sh
# Test for files/alerts.sql: runs it read-only against the live netsec
# ClickHouse with netsec.eve swapped for fixed rows, and checks which alerts
# become Alertmanager alerts.
#
#   sh stacks/netsec/files/alerts_test.sh
set -eu
here=$(dirname "$0")
fixture="(SELECT * FROM values('ts DateTime64(6, ''UTC''), event_type String, src_ip IPv6, dest_ip IPv6, signature_id UInt32, signature String, category String',
  (now64(6) - 60, 'alert', '::ffff:10.0.20.104', '::ffff:50.16.16.211', 1, 'Feodo Tracker: potential QakBot CnC Traffic detected', 'A Network Trojan was detected'),
  (now64(6) - 30, 'alert', '::ffff:10.0.20.104', '::ffff:50.16.16.211', 1, 'Feodo Tracker: potential QakBot CnC Traffic detected', 'A Network Trojan was detected'),
  (now64(6) - 60, 'alert', '::ffff:1.2.3.4', '::ffff:10.0.10.10', 2, 'SSLBL: Malicious SSL certificate detected (Dridex C2)', 'A Network Trojan was detected'),
  (now64(6) - 60, 'alert', '::ffff:202.165.25.8', '::ffff:10.0.20.200', 3, 'ET COMPROMISED Known Compromised or Hostile Host Traffic group 8', 'Misc Attack'),
  (now64(6) - 60, 'alert', '::ffff:10.0.10.10', '::ffff:10.0.10.1', 4, 'ET INFO External IP Lookup Domain in DNS Lookup (icanhazip .com)', 'Device Retrieving External IP Address Detected'),
  (now64(6) - 1200, 'alert', '::ffff:10.0.20.105', '::ffff:50.16.16.211', 5, 'Feodo Tracker: potential Emotet CnC Traffic detected', 'A Network Trojan was detected'),
  (now64(6) - 60, 'dns', '::ffff:10.0.20.105', '::ffff:10.0.20.1', 0, '', '')))"
# awk, not sed: the fixture spans lines and holds characters sed treats as special.
query=$(FIXTURE="$fixture" awk '/^ *FROM netsec\.eve *$/ { sub(/netsec\.eve/, ""); $0 = $0 ENVIRON["FIXTURE"] } { print }' "$here/alerts.sql")
out=$(homelab netsec sql "$query FORMAT TSVRaw")
echo "$out"
fail() { echo "FAIL: $1" >&2; exit 1; }
n=$(echo "$out" | grep -o '"alertname":"NetsecHomeHostMalware"' | wc -l)
[ "$n" -eq 2 ] || fail "want 2 alerts, got $n"
echo "$out" | grep -q '"host":"10.0.20.104","signature_id":"1"' || fail "Feodo hit from 10.0.20.104 missing"
echo "$out" | grep -q '"host":"10.0.10.10","signature_id":"2"' || fail "SSLBL hit on 10.0.10.10 missing"
echo "$out" | grep -q '"lane":"security"' || fail "lane label missing"
echo "$out" | grep -q '2 alerts in 15 min' || fail "hit count missing from the Feodo description"
echo "$out" | grep -q '"endsAt":"20' || fail "endsAt missing"
echo "PASS"
