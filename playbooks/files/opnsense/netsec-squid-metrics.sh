#!/bin/sh
# Installed as /usr/local/bin/netsec-squid-metrics by
# playbooks/tasks/opnsense/squid.yml and run every minute from
# /usr/local/etc/cron.d/netsec-squid. Writes node_exporter textfile metrics for
# the Squid intercept (docs/runbooks/network-ids.md):
#   netsec_squid_ca_not_after_seconds  expiry of the signing intermediate
#   netsec_squid_up                    1 when a squid process runs
#   netsec_opted_in_members            addresses in the pf table opted_in
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
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
