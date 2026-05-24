#!/usr/bin/env bash
# nfs-mirror — local 2nd copy of /srv/nfs (selective) → /mnt/backup
#
# Deploy to PVE host at /usr/local/bin/nfs-mirror.
# Schedule: weekly Mon 04:00 via nfs-mirror.timer.
#
# ROLE in the 3-2-1 strategy:
#   Copy 1 (sdc):       /srv/nfs/* (live PVE NFS)
#   Copy 2 (sda, this): /mnt/backup/<svc>/  ← this script
#   Copy 3 (Synology):  /Backup/Viki/nfs/  (via offsite-sync-backup + inotify)
#
# Replaces the dedicated anca-elements-mirror script; same disk, same
# destination layout (anca-elements lives at /mnt/backup/anca-elements/),
# but now covers every other critical NFS subtree in one pass.
#
# SKIP-LIST rationale (paths NOT mirrored — Synology offsite still covers them):
#   immich       — 1.2T, doesn't fit on sda; Synology only by design
#   frigate      — 14d camera ring, auto-rotates
#   prometheus   — TSDB, rebuildable from cluster state
#   loki         — log retention is a policy choice, not durable data
#   temp         — scratch
#   alertmanager — transient state
#   ollama       — LLM model weights, re-downloadable
#   audiblez     — re-fetchable from Audible
#   ebook2audiobook — regenerable from book sources
#   *-backup     — CronJob output (these ARE backups; backing them up is meta)
#
# Note: /srv/nfs-ssd is intentionally NOT mirrored — after skipping immich
# (47G), ollama (59G), and llamacpp (26G) there's effectively zero residual.

set -euo pipefail

SRC=/srv/nfs/
DST=/mnt/backup/
LOG=/var/log/nfs-mirror.log
LOCKFILE=/run/nfs-mirror.lock
# Manifest of files changed under /mnt/backup since the last offsite-sync.
# offsite-sync-backup Step 1 reads this and rsyncs the listed files to Synology
# pve-backup/ on its next daily run. Without populating it, nfs-mirror's writes
# would only reach Synology via the monthly full sync (1st-7th of month), and
# the monthly --delete pass would also wipe any pre-positioned data.
MANIFEST=/mnt/backup/.changed-files
PUSHGATEWAY="${NFS_MIRROR_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB=nfs-mirror

EXCLUDES=(
    # ---- /mnt/backup subtrees owned by daily-backup — leave alone ----
    --exclude='/pvc-data/'
    --exclude='/sqlite-backup/'
    --exclude='/pfsense/'
    --exclude='/pve-config/'
    --exclude='/lost+found/'

    # ---- state files used by other backup jobs ----
    --exclude='/.changed-files'
    --exclude='/.last-offsite-sync'
    --exclude='/.lv-pvc-mapping.json'
    --exclude='/.nfs-changes.log'

    # ---- NFS paths: too big / transient / re-fetchable ----
    --exclude='/immich/'
    --exclude='/frigate/'
    --exclude='/prometheus/'
    --exclude='/loki/'
    --exclude='/temp/'
    --exclude='/alertmanager/'
    --exclude='/ollama/'
    --exclude='/audiblez/'
    --exclude='/ebook2audiobook/'

    # ---- *-backup CronJob outputs (don't back up backups) ----
    --exclude='/*-backup/'

    # ---- Synology / Windows / macOS cruft ----
    --exclude='/@eaDir/'
    --exclude='*@synoeastream'
    --exclude='/.DS_Store'
    --exclude='/Thumbs.db'
)

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"; }
warn() { log "WARN: $*"; }

# Locked manifest append (shared with daily-backup) — see daily-backup.sh
# for the rationale. flock prevents interleaved appends when nfs-mirror
# (Mon 04:11) overruns into daily-backup (Mon 05:00).
MANIFEST_LOCK="${MANIFEST}.lock"
manifest_append() {
    (
        flock -x 200
        cat >> "${MANIFEST}"
    ) 200>"${MANIFEST_LOCK}"
}

push_metrics() {
    local status="${1:-0}" bytes="${2:-0}"
    cat <<EOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
nfs_mirror_last_run_timestamp $(date +%s)
nfs_mirror_last_status ${status}
nfs_mirror_bytes ${bytes}
EOF
}

KILLED=""
STAMP=""
cleanup() {
    rm -f "$LOCKFILE"
    [ -n "$STAMP" ] && rm -f "$STAMP"
    if [ -n "$KILLED" ]; then
        push_metrics 2 0  # status=2 = aborted
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

log "=== mirror starting: $SRC → $DST ==="
log "skip: immich, frigate, prometheus, loki, ollama, audiblez, *-backup, temp"

# Marker file used to identify files written by this rsync run, so we can append
# their paths to the offsite-sync manifest. Touch BEFORE rsync; `find -newer` AFTER.
STAMP=$(mktemp)

RSYNC_RC=0
rsync \
    -rlt --delete -H \
    --no-perms --no-owner --no-group \
    --info=stats2 \
    "${EXCLUDES[@]}" \
    "$SRC" "$DST" 2>&1 | tee -a "$LOG" || RSYNC_RC=${PIPESTATUS[0]}

DST_BYTES=$(df -B1 --output=used /mnt/backup | tail -1)

if [ "$RSYNC_RC" -eq 0 ]; then
    # Capture files that rsync created/modified and feed them to the offsite-sync
    # manifest so daily Step 1 incremental picks them up tomorrow morning.
    NEW_COUNT=$(find /mnt/backup -newer "$STAMP" -type f \
        ! -path '/mnt/backup/.changed-files' \
        ! -path '/mnt/backup/.changed-files.lock' \
        ! -path '/mnt/backup/.lv-pvc-mapping.json' \
        ! -path '/mnt/backup/.nfs-changes.log' \
        ! -path '/mnt/backup/.last-offsite-sync' \
        ! -path '/mnt/backup/.force-full-sync' \
        -printf '%P\n' 2>/dev/null | tee >(manifest_append) | wc -l)
    log "=== mirror complete; ${NEW_COUNT} files added to offsite manifest ==="
    log "/mnt/backup used: $(df -h --output=used /mnt/backup | tail -1 | tr -d ' ')"
    push_metrics 0 "$DST_BYTES"
else
    log "=== mirror failed: rsync exited $RSYNC_RC ==="
    push_metrics 1 "$DST_BYTES"
    exit "$RSYNC_RC"
fi
