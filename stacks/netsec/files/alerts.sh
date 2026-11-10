#!/bin/sh
# netsec-alerts (stacks/netsec CronJob): every minute, posts Suricata malware
# and C2 alerts that involve one of our hosts to Alertmanager (lane=security,
# so Slack #alerts). The query (alerts.sql) builds the payload; Alertmanager
# dedupes by labels and resolves each alert 15 minutes after its last hit.
set -eu
payload=$(curl -fsS --max-time 30 \
  -H "X-ClickHouse-User: netsec_alerts" -H "X-ClickHouse-Key: ${NETSEC_ALERTS_PASSWORD}" \
  --data-binary @/etc/netsec-alerts/alerts.sql \
  "http://clickhouse.claude-sessions.svc.cluster.local:8123/?default_format=TSVRaw")
if [ "$payload" = "[]" ]; then
  echo "netsec-alerts: no home-host malware alerts in the last 15 min"
  exit 0
fi
curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary "$payload" \
  http://prometheus-alertmanager.monitoring.svc.cluster.local:9093/api/v2/alerts
echo "netsec-alerts: posted $(printf '%s' "$payload" | grep -o '"alertname"' | wc -l) alert(s)"
