#!/usr/bin/env bash
# anca-elements-mirror — single-disk-failure mirror of /srv/nfs/anca-elements → /mnt/backup
#
# Deploy to PVE host at /usr/local/bin/anca-elements-mirror.
# Schedule: weekly Mon 04:00 via systemd timer (anca-elements-mirror.timer).
#
# WHY: /srv/nfs/anca-elements lives on the sdc thin pool. Synology no longer
# holds the original (deleted after this mirror was verified). sda /mnt/backup
# is the only other local disk with room (~770G) — this gives us a single-
# disk-failure copy. No offsite for this archive (intentional, see backup-dr.md).
#
# Idempotent: `rsync -aH --delete` makes destination match source exactly.
# Re-runs only transfer changed files.

set -euo pipefail

SRC=/srv/nfs/anca-elements
DST=/mnt/backup/anca-elements
LOG=/var/log/anca-elements-mirror.log
LOCKFILE=/run/anca-elements-mirror.lock
PUSHGATEWAY="${ANCA_MIRROR_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB=anca-elements-mirror

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
warn() { log "WARN: $*"; }

push_metrics() {
    local status="${1:-0}" bytes="${2:-0}"
    cat <<EOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
anca_elements_mirror_last_run_timestamp $(date +%s)
anca_elements_mirror_last_status ${status}
anca_elements_mirror_bytes ${bytes}
EOF
}

KILLED=""
cleanup() {
    rm -f "$LOCKFILE"
    if [ -n "$KILLED" ]; then
        push_metrics 2 0  # status=2 → aborted (matches lvm-pvc-snapshot convention)
    fi
}
trap cleanup EXIT
trap 'KILLED=1; exit 143' TERM INT

if ! ( set -o noclobber; echo $$ > "$LOCKFILE" ) 2>/dev/null; then
    log "FATAL: another instance running (pid $(cat "$LOCKFILE" 2>/dev/null || echo unknown))"
    exit 1
fi

mountpoint -q /mnt/backup || { log "FATAL: /mnt/backup not mounted"; push_metrics 1 0; exit 1; }
[ -d "$SRC" ]              || { log "FATAL: source $SRC missing"; push_metrics 1 0; exit 1; }

mkdir -p "$DST"

log "=== mirror starting: $SRC → $DST ==="
SRC_SIZE_GB=$(du -sBG "$SRC" 2>/dev/null | awk '{print $1}')
log "source size: $SRC_SIZE_GB"

# -aH preserves hardlinks (probably none here, cheap insurance).
# --info=stats2 emits a final transfer summary into the log.
# --no-perms / --no-owner / --no-group: source has root:www-data 2775 and
# we don't need to perfectly preserve those on the mirror copy — dest will
# inherit /mnt/backup's defaults. (Symmetric with anca-elements-sync.sh's
# choice when copying FROM Synology.)
RSYNC_RC=0
rsync \
    -rlt --delete -H \
    --no-perms --no-owner --no-group \
    --info=stats2 \
    "$SRC/" "$DST/" 2>&1 | tee -a "$LOG" || RSYNC_RC=${PIPESTATUS[0]}

DST_BYTES=$(du -sb "$DST" 2>/dev/null | awk '{print $1}')

if [ "$RSYNC_RC" -eq 0 ]; then
    log "=== mirror complete; dest size: $(du -sh "$DST" | cut -f1) ==="
    push_metrics 0 "$DST_BYTES"
else
    log "=== mirror failed: rsync exited $RSYNC_RC ==="
    push_metrics 1 "$DST_BYTES"
    exit "$RSYNC_RC"
fi
