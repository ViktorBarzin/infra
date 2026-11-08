#!/bin/bash
# Nightly backup of the claude-sessions ClickHouse to the PVE NFS share
# (mounted at /backups in both the server pod and this job).
#
# ClickHouse's native BACKUP writes the database's parts to disk 'backups'.
# Sunday (or when no full backup exists yet) takes a full backup; other days
# take an incremental against the newest full, so a restore needs at most two
# backups. Retention: incrementals 28 days, fulls 35 days, which keeps the
# base of every retained incremental (a base is at most 7 days older).
# Restore: docs/runbooks/restore-claude-sessions.md.
set -euo pipefail

ch() { clickhouse-client --host "$CH_HOST" --port 9000 --user default --password "$CLICKHOUSE_PASSWORD" "$@"; }

t0=$(date -u +%s)
stamp=$(date -u +%Y%m%d-%H%M%S)
latest_full=$(find /backups -mindepth 1 -maxdepth 1 -type d -name 'full-*' -printf '%f\n' | sort | tail -1)

if [ -z "$latest_full" ] || [ "${FORCE_FULL:-0}" = 1 ] || { [ "$(date -u +%u)" = 7 ] && [ "${FORCE_INCREMENTAL:-0}" != 1 ]; }; then
  kind=full
  name="full-$stamp"
  query="BACKUP DATABASE claude TO Disk('backups', '$name')"
else
  kind=incremental
  name="incr-$stamp"
  query="BACKUP DATABASE claude TO Disk('backups', '$name') SETTINGS base_backup = Disk('backups', '$latest_full')"
fi

echo "backup kind=$kind name=$name base=${latest_full:-none}"
result=$(ch -q "$query" --format TSV)
echo "$result"
status=$(printf '%s' "$result" | cut -f2)
if [ "$status" != BACKUP_CREATED ]; then
  echo "backup failed: status=$status"
  exit 1
fi
if [ ! -f "/backups/$name/.backup" ]; then
  echo "backup reported success but /backups/$name/.backup is missing"
  exit 1
fi

lines=$(ch -q "SELECT count() FROM claude.lines")
find /backups -mindepth 1 -maxdepth 1 -type d -name 'incr-*' -mtime +28 -exec rm -rf {} +
find /backups -mindepth 1 -maxdepth 1 -type d -name 'full-*' -mtime +35 -exec rm -rf {} +

dur=$(( $(date -u +%s) - t0 ))
bytes=$(du -sb "/backups/$name" | cut -f1)
echo "backup written: /backups/$name kind=$kind bytes=$bytes lines=$lines duration_s=$dur"
cat > /tmp/metrics <<METRICS
# TYPE backup_last_success_timestamp gauge
backup_last_success_timestamp $(date -u +%s)
# TYPE backup_duration_seconds gauge
backup_duration_seconds $dur
# TYPE backup_output_bytes gauge
backup_output_bytes{kind="$kind"} $bytes
# TYPE claude_sessions_backup_lines gauge
claude_sessions_backup_lines $lines
METRICS
wget -qO- --post-file=/tmp/metrics "$PUSHGATEWAY/metrics/job/claude-sessions-backup" || echo "pushgateway push failed"
