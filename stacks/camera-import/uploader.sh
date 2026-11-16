#!/bin/sh
# Camera import uploader. Every INTERVAL seconds it hands each photo waiting in
# INCOMING to Immich with the official Immich CLI. The CLI deletes a file only
# after Immich has it (new or duplicate), so a failed upload stays and is
# retried on the next round. SFTPGo writes uploads to its temp path and renames
# them in only when complete, so every file here is whole.
#
# Each round pushes three gauges to the Pushgateway for the CameraImport*
# alerts: how many files wait, how long the oldest has waited, and when the
# round ran. Age comes from ctime (the rename into INCOMING), not mtime,
# because an SFTP client may set mtime to the capture time.
#
# Tests: uploader_test.sh.
set -u

INCOMING=${INCOMING:-/srv/data/incoming}
INTERVAL=${INTERVAL:-30}
PUSH_URL=${PUSH_URL:-}
CLI=${CLI:-node /usr/src/app/packages/cli/dist}
ROUNDS=${ROUNDS:-0} # 0 = run forever; tests set a number

push_metrics() {
  [ -n "$PUSH_URL" ] || return 0
  now=$(date +%s)
  waiting=$(find "$INCOMING" -type f | wc -l)
  oldest=$(find "$INCOMING" -type f -printf '%C@\n' | sort -n | head -n1 | cut -d. -f1)
  age=0
  [ -n "$oldest" ] && age=$((now - oldest))
  BODY="camera_import_files_waiting $waiting
camera_import_oldest_waiting_seconds $age
camera_import_last_run_timestamp $now
" node -e '
fetch(process.env.PUSH_URL, { method: "PUT", body: process.env.BODY })
  .then((r) => { if (!r.ok) console.error("pushgateway answered", r.status); })
  .catch((e) => console.error("pushgateway unreachable:", e.message));'
}

round=0
while :; do
  if [ -n "$(find "$INCOMING" -type f -print -quit)" ]; then
    $CLI upload --recursive --delete --delete-duplicates --no-progress "$INCOMING" \
      || echo "upload round failed; files stay for the next round"
    find "$INCOMING" -mindepth 1 -type d -empty -delete
  fi
  push_metrics
  round=$((round + 1))
  [ "$ROUNDS" -gt 0 ] && [ "$round" -ge "$ROUNDS" ] && break
  sleep "$INTERVAL"
done
