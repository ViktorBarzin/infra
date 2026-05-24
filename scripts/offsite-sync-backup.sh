#!/usr/bin/env bash
# offsite-sync-backup — Sync backups to Synology NAS
# Deploy to PVE host at /usr/local/bin/offsite-sync-backup
# Schedule: Daily 06:00 via systemd timer (After=daily-backup.service)
#
# Two sync paths:
#   Step 1: sda (/mnt/backup) → Synology pve-backup/ (PVC snapshots, pfsense, pve-config, sqlite)
#   Step 2: NFS (/srv/nfs, /srv/nfs-ssd) → Synology nfs/, nfs-ssd/ (inotify change-tracked)
set -euo pipefail

# --- Configuration ---
BACKUP_ROOT="/mnt/backup"
SYNOLOGY="Administrator@192.168.1.13"
PVE_BACKUP_DEST="${SYNOLOGY}:/volume1/Backup/Viki/pve-backup"
NFS_DEST="${SYNOLOGY}:/volume1/Backup/Viki/nfs"
NFS_SSD_DEST="${SYNOLOGY}:/volume1/Backup/Viki/nfs-ssd"
MANIFEST="${BACKUP_ROOT}/.changed-files"
NFS_CHANGE_LOG="${BACKUP_ROOT}/.nfs-changes.log"
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

if ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "${SYNOLOGY}" true 2>/dev/null; then
    log "FATAL: Cannot SSH to Synology"
    echo "backup_last_success_timestamp 0" | \
        curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
    exit 1
fi

DAY_OF_MONTH=$(date +%d)

# ============================================================
# STEP 1: sda → Synology pve-backup/ (PVC snapshots, pfsense, pve-config)
# ============================================================
log "--- Step 1: sda → Synology pve-backup/ ---"

# Trigger: monthly cleanup window OR daily-backup signalled the manifest grew
# past its cap (Synology was unreachable too long for incremental to keep up).
FORCE_FULL_FLAG="${BACKUP_ROOT}/.force-full-sync"
FORCE_FULL=""
[ -f "${FORCE_FULL_FLAG}" ] && FORCE_FULL=1
if [ "${DAY_OF_MONTH}" -le 7 ] || [ -n "${FORCE_FULL}" ]; then
    [ -n "${FORCE_FULL}" ] && log "Forced full sync (manifest size cap tripped)..." || log "Monthly full sync (1st Sunday)..."
    # No -z on LAN: gigabit hop to 192.168.1.13 doesn't benefit from compression
    # and burns CPU on the PVE host that's already busy with cluster IO.
    rsync -rlt --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fog=r \
        --exclude='.changed-files' \
        --exclude='.changed-files.lock' \
        --exclude='.last-offsite-sync' \
        --exclude='.lv-pvc-mapping.json' \
        --exclude='.nfs-changes.log' \
        --exclude='.force-full-sync' \
        --exclude='/anca-elements/' \
        "${BACKUP_ROOT}/" "${PVE_BACKUP_DEST}/" 2>&1 || STATUS=1
    rm -f "${FORCE_FULL_FLAG}"
elif [ -s "${MANIFEST}" ]; then
    MANIFEST_LINES=$(wc -l < "${MANIFEST}")
    log "Incremental sync (${MANIFEST_LINES} files from manifest)..."
    # /anca-elements is being ingested into Immich (Immich becomes canonical) —
    # skip the redundant copy in /mnt/backup/anca-elements/ until manual cleanup.
    rsync -rlt --chmod=Du=rwx,Dgo=rx,Fu=rw,Fog=r --files-from="${MANIFEST}" \
        --exclude='anca-elements/' \
        "${BACKUP_ROOT}/" "${PVE_BACKUP_DEST}/" 2>&1 || STATUS=1
else
    log "No changed files in manifest, nothing to sync"
fi

# ============================================================
# STEP 2: NFS → Synology nfs/ + nfs-ssd/ (inotify change-tracked, FILTERED)
# ============================================================
#
# DESIGN: Step 2 only carries paths that BYPASS the sda mirror. Paths that ARE
# mirrored to sda by nfs-mirror reach Synology via Step 1 (sda → Synology
# pve-backup/) and must NOT also flow through Step 2 — that would duplicate
# every byte and double Synology consumption.
#
# The skip-list below MUST stay in sync with EXCLUDES in
# /usr/local/bin/nfs-mirror (which defines what nfs-mirror does NOT copy to
# sda). The two are complementary: nfs-mirror EXCLUDES = offsite-sync Step 2
# INCLUDES. Failing to keep them aligned creates either gaps (data missing
# from Synology) or duplication (data on Synology via both paths).
log "--- Step 2: NFS → Synology (skip-list paths only — sda-bypass leg) ---"

# Regex matching paths NOT on sda (must reach Synology directly).
# Top-level dirs under /srv/nfs/ — anchored, no nesting allowed.
NFS_SDA_BYPASS_RE='^/srv/nfs/(immich|frigate|prometheus|loki|temp|alertmanager|ollama|audiblez|ebook2audiobook|[^/]+-backup)/'

# rsync include/exclude args for the monthly full sync (HDD).
# Order matters: --include patterns first, --exclude '*' last.
NFS_FULL_INCLUDES=(
    --include='/immich/'        --include='/immich/***'
    --include='/frigate/'       --include='/frigate/***'
    --include='/prometheus/'    --include='/prometheus/***'
    --include='/loki/'          --include='/loki/***'
    --include='/temp/'          --include='/temp/***'
    --include='/alertmanager/'  --include='/alertmanager/***'
    --include='/ollama/'        --include='/ollama/***'
    --include='/audiblez/'      --include='/audiblez/***'
    --include='/ebook2audiobook/' --include='/ebook2audiobook/***'
    --include='/*-backup/'      --include='/*-backup/***'
    --exclude='*'
)

if [ "${DAY_OF_MONTH}" -le 7 ]; then
    # Monthly: full sync with --delete for cleanup, restricted to bypass-list.
    log "Monthly full NFS sync (sda-bypass paths only)..."
    rsync -rlt --delete "${NFS_FULL_INCLUDES[@]}" /srv/nfs/ "${NFS_DEST}/" 2>&1 \
        && log "  OK: nfs/ full sync (bypass-list)" || { warn "nfs/ full sync failed"; STATUS=1; }
    # nfs-ssd: every dir under it (immich/ollama/llamacpp) is in the bypass list,
    # so a plain --delete still applies cleanly.
    rsync -rlt --delete /srv/nfs-ssd/ "${NFS_SSD_DEST}/" 2>&1 \
        && log "  OK: nfs-ssd/ full sync" || { warn "nfs-ssd/ full sync failed"; STATUS=1; }
    > "${NFS_CHANGE_LOG}"
elif [ -s "${NFS_CHANGE_LOG}" ]; then
    # Incremental: only sync changed files in bypass-list paths.
    sort -u "${NFS_CHANGE_LOG}" > /tmp/nfs-changes-deduped

    # HDD NFS — include only sda-bypass paths.
    grep -E "${NFS_SDA_BYPASS_RE}" /tmp/nfs-changes-deduped | \
        while IFS= read -r f; do [ -f "$f" ] && echo "${f#/srv/nfs/}"; done \
        > /tmp/sync-nfs.list 2>/dev/null
    NFS_COUNT=$(wc -l < /tmp/sync-nfs.list 2>/dev/null || echo 0)
    if [ "${NFS_COUNT:-0}" -gt 0 ]; then
        rsync -rlt --files-from=/tmp/sync-nfs.list /srv/nfs/ "${NFS_DEST}/" 2>&1 \
            && log "  OK: nfs/ (${NFS_COUNT} bypass files)" \
            || { warn "nfs/ incremental failed"; STATUS=1; }
    fi

    # SSD NFS — every nfs-ssd path (immich/ollama/llamacpp) is in the bypass list.
    grep '^/srv/nfs-ssd/' /tmp/nfs-changes-deduped | \
        while IFS= read -r f; do [ -f "$f" ] && echo "${f#/srv/nfs-ssd/}"; done \
        > /tmp/sync-nfs-ssd.list 2>/dev/null || true
    SSD_COUNT=$(wc -l < /tmp/sync-nfs-ssd.list 2>/dev/null || echo 0)
    if [ "${SSD_COUNT:-0}" -gt 0 ]; then
        rsync -rlt --files-from=/tmp/sync-nfs-ssd.list /srv/nfs-ssd/ "${NFS_SSD_DEST}/" 2>&1 \
            && log "  OK: nfs-ssd/ (${SSD_COUNT} files)" \
            || { warn "nfs-ssd/ incremental failed"; STATUS=1; }
    fi

    TOTAL=$(wc -l < /tmp/nfs-changes-deduped)
    log "  Processed ${TOTAL} change events (${NFS_COUNT} nfs + ${SSD_COUNT} nfs-ssd bypass-list files synced)"
    > "${NFS_CHANGE_LOG}"
    rm -f /tmp/nfs-changes-deduped /tmp/sync-nfs.list /tmp/sync-nfs-ssd.list
else
    log "  No NFS changes to sync"
fi

# ============================================================
# Finish
# ============================================================
if [ "${STATUS}" -eq 0 ]; then
    touch "${BACKUP_ROOT}/.last-offsite-sync"
    > "${MANIFEST}"
    log "=== Offsite sync complete (success) ==="
else
    warn "Offsite sync had errors — manifest preserved for retry"
    log "=== Offsite sync complete (with errors) ==="
fi

cat <<EOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
backup_last_success_timestamp $(date +%s)
offsite_sync_last_status ${STATUS}
EOF

exit "${STATUS}"
