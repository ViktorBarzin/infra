#!/usr/bin/env bash
# offsite-sync-backup — Sync /mnt/backup to Synology NAS using changed-files manifest
# Deploy to PVE host at /usr/local/bin/offsite-sync-backup
# Schedule: Weekly Sunday 08:00 via systemd timer (After=weekly-backup.service)
set -euo pipefail

# --- Configuration ---
BACKUP_ROOT="/mnt/backup"
DEST="Administrator@192.168.1.13:/volume1/Backup/Viki/pve-backup"
MANIFEST="${BACKUP_ROOT}/.changed-files"
PUSHGATEWAY="${OFFSITE_SYNC_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="offsite-backup-sync"
LOCKFILE="/run/offsite-sync-backup.lock"

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }

# --- Locking ---
cleanup() { rm -f "${LOCKFILE}"; }
trap cleanup EXIT
if ! ( set -o noclobber; echo $$ > "${LOCKFILE}" ) 2>/dev/null; then
    log "FATAL: Another instance running"; exit 1
fi

# --- Main ---
log "=== Offsite sync starting ==="
STATUS=0

if ! mountpoint -q "${BACKUP_ROOT}"; then
    log "FATAL: ${BACKUP_ROOT} is not mounted"; exit 1
fi

# Test SSH connectivity first
if ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 Administrator@192.168.1.13 true 2>/dev/null; then
    log "FATAL: Cannot SSH to Synology (192.168.1.13)"
    echo "backup_last_success_timestamp 0" | \
        curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
    exit 1
fi

DAY_OF_MONTH=$(date +%d)

if [ "${DAY_OF_MONTH}" -le 7 ]; then
    # First Sunday of month: full sync with --delete to clean orphans on Synology
    log "Monthly full sync (1st Sunday)..."
    rsync -rltz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fog=r \
        --exclude='.changed-files' \
        --exclude='.last-offsite-sync' \
        --exclude='.lv-pvc-mapping.json' \
        "${BACKUP_ROOT}/" "${DEST}/" 2>&1 || STATUS=1
elif [ -s "${MANIFEST}" ]; then
    # Incremental: only send files listed in manifest (no remote dir walk)
    MANIFEST_LINES=$(wc -l < "${MANIFEST}")
    log "Incremental sync (${MANIFEST_LINES} files from manifest)..."
    rsync -rltz --chmod=Du=rwx,Dgo=rx,Fu=rw,Fog=r --files-from="${MANIFEST}" --no-traverse \
        "${BACKUP_ROOT}/" "${DEST}/" 2>&1 || STATUS=1
else
    log "No changed files in manifest, nothing to sync"
fi

if [ "${STATUS}" -eq 0 ]; then
    # Only clear manifest + update timestamp on SUCCESS
    touch "${BACKUP_ROOT}/.last-offsite-sync"
    > "${MANIFEST}"
    log "=== Offsite sync complete (success) ==="
else
    # Keep manifest for retry next week
    warn "Offsite sync had errors — manifest preserved for retry"
    log "=== Offsite sync complete (with errors) ==="
fi

cat <<EOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
backup_last_success_timestamp $(date +%s)
offsite_sync_last_status ${STATUS}
EOF

exit "${STATUS}"
