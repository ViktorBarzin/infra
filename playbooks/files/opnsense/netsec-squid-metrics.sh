#!/bin/sh
# Installed as /usr/local/bin/netsec-squid-metrics by
# playbooks/tasks/opnsense/squid.yml and run every minute from
# /usr/local/etc/cron.d/netsec-squid. Writes node_exporter textfile metrics for
# the Squid intercept (docs/runbooks/network-ids.md):
#   netsec_squid_ca_not_after_seconds  expiry of the signing intermediate
#   netsec_squid_up                    1 when a squid process runs
#   netsec_opted_in_members            addresses in the pf table opted_in
# and Suricata's capture counters from the last block of stats.log (written
# every 5 minutes; they reset when Suricata restarts, so they are counters):
#   netsec_suricata_capture_kernel_packets_total  packets the capture saw
#   netsec_suricata_capture_kernel_drops_total    packets it missed
#   netsec_suricata_flow_bypassed_packets_total   packets skipped after the
#                                                 stream depth (bypass)
set -eu
dir=/var/tmp/node_exporter
out="$dir/netsec_squid.prom"
tmp="$out.$$"
mkdir -p "$dir"

not_after=$(/usr/local/bin/php -r '
  $pem = @file_get_contents("/var/squid/ssl/ca.pem");
  $c = $pem ? @openssl_x509_parse($pem) : false;
  echo $c ? $c["validTo_time_t"] : "";')
if pgrep -x squid >/dev/null 2>&1; then up=1; else up=0; fi
members=$(/sbin/pfctl -t opted_in -T show 2>/dev/null | grep -c . || true)
stats=/var/log/suricata/stats.log
# Read only the newest block: Suricata leaves zero counters out of a block, so
# an older block's value would otherwise stand in for a zero (seen 2026-11-11:
# no capture.kernel_drops line at all after the restart).
counter() { [ -r "$stats" ] && tail -n 600 "$stats" | awk -v k="$1" '/^Date:/ {v = ""} $1 == k {v = $NF} END {if (v != "") print v}'; }
cap_pkts=$(counter capture.kernel_packets || true)
cap_drops=$(counter capture.kernel_drops || true)
bypassed=$(counter flow_bypassed.local_pkts || true)
# A block that counted packets but printed no drops means zero drops.
if [ -n "$cap_pkts" ] && [ -z "$cap_drops" ]; then cap_drops=0; fi
if [ -n "$cap_pkts" ] && [ -z "$bypassed" ]; then bypassed=0; fi

{
  echo "# HELP netsec_squid_ca_not_after_seconds Expiry of the Squid intercept signing CA (unix time)."
  echo "# TYPE netsec_squid_ca_not_after_seconds gauge"
  [ -n "$not_after" ] && echo "netsec_squid_ca_not_after_seconds $not_after"
  echo "# HELP netsec_squid_up 1 when a squid process is running."
  echo "# TYPE netsec_squid_up gauge"
  echo "netsec_squid_up $up"
  echo "# HELP netsec_opted_in_members Addresses in the opted_in alias (machines Squid decrypts)."
  echo "# TYPE netsec_opted_in_members gauge"
  echo "netsec_opted_in_members ${members:-0}"
  echo "# HELP netsec_suricata_capture_kernel_packets_total Packets Suricata's capture saw (resets on restart)."
  echo "# TYPE netsec_suricata_capture_kernel_packets_total counter"
  [ -n "$cap_pkts" ] && echo "netsec_suricata_capture_kernel_packets_total $cap_pkts"
  echo "# HELP netsec_suricata_capture_kernel_drops_total Packets Suricata's capture missed (resets on restart)."
  echo "# TYPE netsec_suricata_capture_kernel_drops_total counter"
  [ -n "$cap_drops" ] && echo "netsec_suricata_capture_kernel_drops_total $cap_drops"
  echo "# HELP netsec_suricata_flow_bypassed_packets_total Packets skipped after the stream depth (resets on restart)."
  echo "# TYPE netsec_suricata_flow_bypassed_packets_total counter"
  [ -n "$bypassed" ] && echo "netsec_suricata_flow_bypassed_packets_total $bypassed"
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
