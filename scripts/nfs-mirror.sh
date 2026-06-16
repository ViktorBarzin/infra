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
# SKIP-LIST rationale (2026-05-26 simplification; REGENERABLE-SERVICE
# CARVE-OUT added 2026-06-01 — see below):
#   immich  — 1.5T, doesn't fit on sda; offsite-sync ships it direct to Synology
#   frigate — camera ring buffer; intentionally NOT backed up anywhere
#   temp    — scratch; intentionally NOT backed up
#
# 2026-06-01 carve-out: the offsite Synology (5.3T) hit 97% and the
# `Backup` share had grown +670G in a week — traced to the 2026-05-26
# change that started mirroring large *regenerable* services to sda and
# thence to Synology pve-backup/. These are now re-excluded because they
# cost offsite capacity for data we can rebuild on demand:
#   ollama          (20G) — LLM model blobs, re-pullable
#   prometheus-backup (64G) — metrics TSDB snapshots; was offsite-excluded
#                             pre-2026-05-26 by original intent
#   audiblez        (24G) — generated audiobooks, re-derivable from ebooks
#   ebook2audiobook (11G) — same, generation output
# Their live copy stays on sdc (/srv/nfs); only the sda + Synology copies
# are dropped. `*-backup` DB dumps (sqlite-backup et al.) are intentionally
# KEPT — they are real database safety copies, not regenerable.
#
# Note: /srv/nfs-ssd is intentionally NOT mirrored — its dirs (immich,
# ollama, llamacpp) go direct to Synology nfs-ssd/ via offsite-sync
# Step 2, which (also 2026-06-01) was narrowed to immich-only so ollama
# + llamacpp on the SSD stop reaching Synology too.

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
    # ---- /mnt/backup subtrees owned by OTHER backup jobs — leave alone ----
    # Without these, the top-level `rsync --delete /srv/nfs/ → /mnt/backup/` below
    # reaps any /mnt/backup dir that has no /srv/nfs counterpart.
    --exclude='/pvc-data/'
    --exclude='/sqlite-backup/'
    --exclude='/pfsense/'
    --exclude='/pve-config/'
    --exclude='/vzdump/'       # VM images from vzdump-vms — NOT a /srv/nfs svc (else --delete reaps them nightly)
    --exclude='/lost+found/'

    # ---- state files used by other backup jobs ----
    --exclude='/.changed-files'
    --exclude='/.last-offsite-sync'
    --exclude='/.lv-pvc-mapping.json'
    --exclude='/.nfs-changes.log'

    # ---- anca-elements: now in Immich (canonical), /mnt/backup copy deleted
    # 2026-05-26. Kept in excludes so nfs-mirror doesn't re-populate from sdc
    # if /srv/nfs/anca-elements is ever re-attached.
    --exclude='/anca-elements/'

    # ---- NFS paths intentionally NOT backed up ----
    --exclude='/immich/'   # 1.5T — ships sdc → Synology direct (Step 2)
    --exclude='/frigate/'  # ring buffer — no backup anywhere
    --exclude='/temp/'     # scratch — no backup anywhere

    # ---- regenerable services: live-only on sdc, no offsite (2026-06-01) ----
    # See header carve-out. --delete reaps any existing copies from sda on
    # the next run; a one-off direct delete already cleared them from Synology.
    --exclude='/ollama/'           # LLM models — re-pullable
    --exclude='/prometheus-backup/' # metrics TSDB snapshots
    --exclude='/audiblez/'         # generated audiobooks
    --exclude='/ebook2audiobook/'  # generated audiobooks

    # ---- Synology / Windows / macOS cruft ----
    --exclude='/@eaDir/'
    --exclude='*@synoeastream'
    --exclude='/.DS_Store'
    --exclude='/Thumbs.db'

    # ---- transient SQLite sidecars (WAL mode) ----
    # Created/checkpointed/deleted constantly, so they vanish mid-rsync and trip
    # exit code 24 (root cause of NfsMirrorFailing on calibre-web-automated's
    # queue.db, 2026-05/06). They must NEVER be in a raw mirror anyway: a -wal/-shm
    # without an atomic .db snapshot is useless to restore from. Consistent SQLite
    # copies are made separately by daily-backup (SQLite backup API).
    --exclude='*-wal'
    --exclude='*-shm'
    --exclude='*-journal'
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
log "skip: immich (Synology direct), frigate/temp (no backup), anca-elements, ollama/prometheus-backup/audiblez/ebook2audiobook (regenerable, live-only)"

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

# rsync exit 24 = "some source files vanished before transfer" — benign for a
# backup mirror: everything else copied; the vanished files are transient (e.g.
# SQLite WAL/SHM, now mostly caught by the excludes above). Treat as success so
# the offsite manifest still updates and NfsMirrorFailing doesn't false-fire.
if [ "$RSYNC_RC" -eq 0 ] || [ "$RSYNC_RC" -eq 24 ]; then
    [ "$RSYNC_RC" -eq 24 ] && warn "rsync exited 24 (source files vanished mid-transfer) — treating as success"
    # Capture files that rsync created/modified and feed them to the offsite-sync
    # manifest so daily Step 1 incremental picks them up tomorrow morning.
    # Use -cnewer (ctime), not -newer (mtime): rsync -t preserves SOURCE mtime
    # on the dest, so freshly-written files with old source mtime look "older"
    # than $STAMP and -newer misses them. ctime is set when the inode is written,
    # regardless of -t, so it correctly identifies what this run created.
    # (Bug hit 2026-05-26 full bypass-list mirror: 800k files copied, manifest
    # captured only 2 entries → forced a .force-full-sync to recover.)
    NEW_COUNT=$(find /mnt/backup -cnewer "$STAMP" -type f \
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
