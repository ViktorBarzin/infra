#!/bin/bash
# netsec-technitium (stacks/netsec CronJob, every 5 minutes): copies new rows
# of Technitium's Postgres query log into netsec.technitium with
# technitium_pull.sql, then pushes its freshness to Pushgateway for
# NetsecTechnitiumStale. The 90 days that existed on 2026-11-11 were
# backfilled once as the ClickHouse admin (docs/runbooks/network-ids.md,
# "Technitium query log"); this job only follows the tail.
set -euo pipefail

OVERLAP=20000   # rows re-checked below the newest copied dlid: about an hour
CHUNK=200000    # cap per run, about 12 h of lookups; keeps one run far under
                # netsec_writer's hourly quota, which Vector shares

ch() { clickhouse-client --host "$CH_HOST" --user netsec_writer --password "$NETSEC_WRITER_PASSWORD" "$@"; }

wm=$(ch -q "SELECT max(dlid) FROM netsec.technitium")
if [ "$wm" = 0 ]; then
  echo "netsec.technitium is empty: run the backfill in docs/runbooks/network-ids.md first"
  exit 1
fi
lo=$(( wm > OVERLAP ? wm - OVERLAP : 0 ))
hi=$(( wm + CHUNK ))

ch --param_pw="$PG_PASSWORD" --param_lo="$lo" --param_hi="$hi" --queries-file /scripts/technitium_pull.sql

read -r newest_dlid newest_ts copied <<<"$(ch --format TSV -q "SELECT max(dlid), toUnixTimestamp(max(ts)), countIf(dlid > $wm) FROM netsec.technitium WHERE dlid > $lo")"
echo "copied=$copied newest_dlid=$newest_dlid newest_ts=$newest_ts"

# No "# TYPE" lines, as in claude-sessions' backup.sh.
cat > /tmp/metrics <<METRICS
netsec_technitium_pull_last_success_timestamp $(date -u +%s)
netsec_technitium_newest_row_timestamp $newest_ts
netsec_technitium_rows_copied $copied
METRICS
wget -qO- --post-file=/tmp/metrics "$PUSHGATEWAY/metrics/job/netsec-technitium" >/dev/null
