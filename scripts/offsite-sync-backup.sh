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
    # anca-elements: now in Immich (canonical); /mnt/backup copy deleted
    # 2026-05-26. Exclude retained as a safety belt in case it re-appears.
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
# DESIGN: Step 2 only carries paths that BYPASS the sda mirror. As of
# 2026-05-26 that's just /srv/nfs/immich/ (1.5T, doesn't fit on sda).
# Everything else under /srv/nfs/ now flows through sda via nfs-mirror,
# reaching Synology via Step 1 (sda → pve-backup/). frigate and temp are
# excluded from both legs — intentionally NOT backed up.
#
# nfs-ssd is handled separately below: its three dirs (immich, ollama,
# llamacpp) all go direct to Synology since /srv/nfs-ssd is not mirrored
# to sda. ollama+llamacpp are small enough (~85G total) that the direct
# leg is fine and we don't need to extend nfs-mirror to cover the SSD.
#
# Keep this aligned with /usr/local/bin/nfs-mirror's EXCLUDES — the
# excludes there are { immich (this leg), frigate (no backup), temp
# (no backup), anca-elements (deleted), pvc-data and friends (owned by
# daily-backup) }. Only the bypass-leg subset matters here: { immich }.
log "--- Step 2: NFS → Synology (immich-only direct leg + nfs-ssd) ---"

# Regex matching paths NOT on sda (must reach Synology directly).
NFS_SDA_BYPASS_RE='^/srv/nfs/immich/'

# rsync include/exclude args for the monthly full sync (HDD).
NFS_FULL_INCLUDES=(
    --include='/immich/'  --include='/immich/***'
    --exclude='*'
)

if [ "${DAY_OF_MONTH}" -le 7 ]; then
    # Monthly: full sync with --delete for cleanup, restricted to bypass-list.
    # --delete here will reap legacy dirs on Synology (frigate, ollama,
    # audiblez, ebook2audiobook, *-backup, prometheus, loki, temp,
    # alertmanager) since they're no longer in NFS_FULL_INCLUDES.
    log "Monthly full NFS sync (immich-only — reaps legacy bypass dirs)..."
    rsync -rlt --delete "${NFS_FULL_INCLUDES[@]}" /srv/nfs/ "${NFS_DEST}/" 2>&1 \
        && log "  OK: nfs/ full sync (immich-only)" || { warn "nfs/ full sync failed"; STATUS=1; }
    # nfs-ssd: full sync of all three dirs (immich, ollama, llamacpp).
    rsync -rlt --delete /srv/nfs-ssd/ "${NFS_SSD_DEST}/" 2>&1 \
        && log "  OK: nfs-ssd/ full sync" || { warn "nfs-ssd/ full sync failed"; STATUS=1; }
    > "${NFS_CHANGE_LOG}"
elif [ -s "${NFS_CHANGE_LOG}" ]; then
    # Incremental: only sync changed files matching the bypass leg (immich).
    sort -u "${NFS_CHANGE_LOG}" > /tmp/nfs-changes-deduped

    # HDD NFS — include only /srv/nfs/immich/ paths.
    grep -E "${NFS_SDA_BYPASS_RE}" /tmp/nfs-changes-deduped | \
        while IFS= read -r f; do [ -f "$f" ] && echo "${f#/srv/nfs/}"; done \
        > /tmp/sync-nfs.list 2>/dev/null
    NFS_COUNT=$(wc -l < /tmp/sync-nfs.list 2>/dev/null || echo 0)
    if [ "${NFS_COUNT:-0}" -gt 0 ]; then
        rsync -rlt --files-from=/tmp/sync-nfs.list /srv/nfs/ "${NFS_DEST}/" 2>&1 \
            && log "  OK: nfs/ (${NFS_COUNT} immich files)" \
            || { warn "nfs/ incremental failed"; STATUS=1; }
    fi

    # SSD NFS — every nfs-ssd path (immich/ollama/llamacpp) ships direct.
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
    log "  Processed ${TOTAL} change events (${NFS_COUNT} nfs/immich + ${SSD_COUNT} nfs-ssd files synced)"
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
