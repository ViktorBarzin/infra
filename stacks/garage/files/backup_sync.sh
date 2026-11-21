#!/bin/sh
# Second step of the garage-backup CronJob (stacks/garage/main.tf); runs in
# the rclone image after backup_prepare.py wrote /work/buckets and
# /work/rclone.env. Layout under $BACKUP_ROOT (Cloud's `cloud bucket restore`
# reads it, so it is a contract):
#
#   current/<bucket>/<key>        the mirror as of this run
#   <YYYY-MM-DD>/<bucket>/<key>   what this run overwrote or deleted, so the
#                                 version the previous run had copied
#
# A bucket that is gone from Garage moves whole from current/ into the dated
# directory, so it ages out like a deleted object. The newest $KEEP dated
# directories stay; older ones are deleted. Retention counts directories, not
# days, so a job that stops running never ages out the last copies.
#
# Each run first moves what it replaces into .staging/<date>/<bucket>, then
# into the dated directory with --ignore-existing, and deletes the rest. So a
# second run on the same day adds to that day's directory and never replaces
# a file in it: the dated copy stays the version the previous night had. A
# .staging left by a killed run is merged the same way at the next start.
#
# Pushes backup_last_success_timestamp (job garage-backup) only when every
# bucket synced; GarageBackupStale reads it.
set -eu

BACKUP_ROOT="${BACKUP_ROOT:-/backup}"
KEEP="${KEEP:-7}"
DATE="${BACKUP_DATE:-$(date -u +%Y-%m-%d)}"
START=$(date +%s)

set -a
. /work/rclone.env
set +a

# merge <staging dir> <dated dir>: add what the dated dir lacks, drop the
# rest. On failure the staging dir stays for the next run to merge.
merge() {
  rclone move "$1" "$2" --ignore-existing --create-empty-src-dirs -q && rm -rf "$1"
}

mkdir -p "$BACKUP_ROOT/current"
STAGE="$BACKUP_ROOT/.staging"
for left in "$STAGE"/*/; do
  [ -d "$left" ] || continue
  echo "== merging $(basename "$left") left by an earlier run"
  merge "$left" "$BACKUP_ROOT/$(basename "$left")" || echo "WARN: could not merge $left"
done
total=0
failed=0
while IFS= read -r bucket; do
  [ -n "$bucket" ] || continue
  total=$((total + 1))
  echo "== $bucket"
  if ! rclone sync "garage:$bucket" "$BACKUP_ROOT/current/$bucket" \
      --backup-dir "$STAGE/$DATE/$bucket" \
      --create-empty-src-dirs --stats-one-line --stats 0 -v; then
    echo "FAIL: $bucket"
    failed=$((failed + 1))
  fi
  if [ -d "$STAGE/$DATE/$bucket" ] && ! merge "$STAGE/$DATE/$bucket" "$BACKUP_ROOT/$DATE/$bucket"; then
    echo "FAIL: $bucket (staging merge)"
    failed=$((failed + 1))
  fi
done < /work/buckets

# Buckets that no longer exist in Garage.
for dir in "$BACKUP_ROOT"/current/*/; do
  [ -d "$dir" ] || continue
  bucket=$(basename "$dir")
  if ! grep -qxF "$bucket" /work/buckets; then
    # Its last state wins over an earlier run's copies from today.
    echo "== $bucket is gone from Garage; moving it to $DATE/"
    if rclone move "$BACKUP_ROOT/current/$bucket" "$BACKUP_ROOT/$DATE/$bucket" \
        --create-empty-src-dirs -q; then
      rm -rf "${BACKUP_ROOT:?}/current/$bucket"
    else
      echo "FAIL: moving $bucket"
      failed=$((failed + 1))
    fi
  fi
done

[ "$failed" -ne 0 ] || rm -rf "$STAGE"

# Retention: keep the newest $KEEP dated directories.
ls -1 "$BACKUP_ROOT" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r \
  | awk -v keep="$KEEP" 'NR > keep' | while IFS= read -r old; do
    echo "== removing $old (older than the newest $KEEP)"
    rm -rf "${BACKUP_ROOT:?}/$old"
  done

END=$(date +%s)
metrics="garage_backup_buckets $total
garage_backup_failed_buckets $failed
garage_backup_duration_seconds $((END - START))
garage_backup_last_run_timestamp $END
"
if [ "$failed" -eq 0 ]; then
  metrics="${metrics}backup_last_success_timestamp $END
"
fi
if [ -n "${PUSHGATEWAY:-}" ]; then
  printf '%s' "$metrics" > /tmp/metrics
  wget -q -O /dev/null --post-file=/tmp/metrics \
    "$PUSHGATEWAY/metrics/job/garage-backup" || echo "WARN: Pushgateway push failed"
fi

echo "$total bucket(s), $failed failed, $((END - START)) s"
[ "$failed" -eq 0 ]
