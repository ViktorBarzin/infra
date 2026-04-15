#!/usr/bin/env bash
# daily-backup — 3-2-1 backup: PVC file copy + SQLite + pfsense + PVE config to sda
# Deploy to PVE host at /usr/local/bin/daily-backup
# Schedule: Daily 05:00 via systemd timer
set -euo pipefail

# --- Configuration ---
BACKUP_ROOT="/mnt/backup"
PVC_MOUNT="/tmp/pvc-mount"
PUSHGATEWAY="${DAILY_BACKUP_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="daily-backup"
LOCKFILE="/run/daily-backup.lock"
MANIFEST="${BACKUP_ROOT}/.changed-files"
MAPPING_CACHE="${BACKUP_ROOT}/.lv-pvc-mapping.json"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; push_metrics 1 0; exit 1; }

# --- Locking ---
cleanup() {
    umount "${PVC_MOUNT}" 2>/dev/null || true
    rm -f "${LOCKFILE}"
}
trap cleanup EXIT
if ! ( set -o noclobber; echo $$ > "${LOCKFILE}" ) 2>/dev/null; then
    die "Another instance is running (PID $(cat "${LOCKFILE}" 2>/dev/null || echo unknown))"
fi

# --- Metrics ---
push_metrics() {
    local status="${1:-0}" bytes="${2:-0}"
    cat <<EOF | curl -s --connect-timeout 5 --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
daily_backup_last_run_timestamp $(date +%s)
daily_backup_last_status ${status}
daily_backup_bytes_synced ${bytes}
EOF
}

# --- PVC name resolution ---
resolve_pvc_name() {
    local lv="$1"
    jq -r --arg lv "${lv}" '
        .items[] |
        select(.spec.csi.volumeHandle // "" | endswith($lv)) |
        "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)"
    ' "${MAPPING_CACHE}" 2>/dev/null
}

# --- NFS Export Health Check ---
# Verify NFS exports are healthy before starting backup.
# Detects: missing /etc/exports, incorrect fsid=0 flag, unexpected exports.
# Added 2026-04-14 [PM-2026-04-14]: backup script accessed NFS causing stale handle
# propagation during the fsid=0 outage. Early check prevents cascading failures.
check_nfs_exports() {
    local exports_file="/etc/exports"
    local status=0

    if [ ! -f "${exports_file}" ]; then
        log "WARN: ${exports_file} does not exist — NFS exports may be unconfigured"
        return 1
    fi

    # Check for dangerous fsid=0 on /srv/nfs (breaks NFSv4 subdirectory path resolution)
    if grep -E '^/srv/nfs[[:space:]].*fsid=0' "${exports_file}" 2>/dev/null; then
        log "ERROR: /etc/exports contains fsid=0 on /srv/nfs — this will break all k8s NFS mounts!"
        log "ERROR: Remove fsid=0 and run: exportfs -ra && systemctl restart nfs-server"
        return 1
    fi

    # Verify NFS server is active
    if ! systemctl is-active --quiet nfs-server 2>/dev/null; then
        log "WARN: nfs-server is not running — NFS mounts will fail"
        return 1
    fi

    # Verify exports are actually loaded (exportfs -s lists active exports)
    local active_exports
    active_exports=$(exportfs -s 2>/dev/null | grep -c '/srv/nfs' || true)
    if [ "${active_exports:-0}" -eq 0 ]; then
        log "WARN: No /srv/nfs exports active in kernel — run: exportfs -ra"
        return 1
    fi

    log "NFS export health check passed (${active_exports} /srv/nfs export(s) active)"
    return 0
}

# --- Main ---
log "=== Weekly backup starting ==="

if ! mountpoint -q "${BACKUP_ROOT}"; then
    die "${BACKUP_ROOT} is not mounted"
fi

# NFS export health check — warn but don't abort (backup can proceed with block storage PVCs)
check_nfs_exports || {
    log "WARN: NFS export health check failed — NFS-backed PVC backups may fail"
    STATUS=1
}

STATUS=0
TOTAL_BYTES=0

# Clear manifest for this run
> "${MANIFEST}"

# NFS data is synced directly to Synology via inotifywait + offsite-sync-backup.sh
# No NFS mirror step on sda — saves 53GB and eliminates duplication.

# ============================================================
# STEP 1: PVC file-level copy from LVM thin snapshots
# ============================================================
log "--- Step 2: PVC file copy from snapshots ---"
WEEK=$(date +%Y-%W)
PREV=$(ls -1d "${BACKUP_ROOT}/pvc-data"/????-?? 2>/dev/null | tail -1 || true)

# Cache LV→PVC mapping (fallback if kubectl is down next time)
if kubectl get pv -o json > /tmp/pv-list.json 2>/dev/null; then
    cp /tmp/pv-list.json "${MAPPING_CACHE}"
    rm -f /tmp/pv-list.json
fi

if [ ! -f "${MAPPING_CACHE}" ]; then
    warn "No PV mapping cache and kubectl unavailable — skipping PVC copy"
    STATUS=1
else
    mkdir -p "${PVC_MOUNT}"
    PVC_COUNT=0
    PVC_FAIL=0

    # Iterate origin LVs (not snapshots), find latest snapshot for each
    for origin_lv in $(lvs --noheadings -o lv_name pve 2>/dev/null | grep 'vm-9999-pvc-' | grep -v '_snap_' | tr -d ' '); do
        # Find latest snapshot for this origin
        snap=$(lvs --noheadings -o lv_name pve 2>/dev/null | tr -d ' ' | grep "^${origin_lv}_snap_" | sort | tail -1 || true)
        [ -z "${snap}" ] && continue

        # Resolve human-readable name
        ns_pvc=$(resolve_pvc_name "${origin_lv}")
        if [ -z "${ns_pvc}" ] || [ "${ns_pvc}" = "null/null" ]; then
            warn "Cannot resolve PVC name for ${origin_lv}, skipping"
            continue
        fi

        # Detect LUKS-encrypted volumes and set up mount device
        LUKS_NAME=""
        MOUNT_DEV="/dev/pve/${snap}"
        MOUNT_OPTS="ro"
        if blkid -o value -s TYPE "/dev/pve/${snap}" 2>/dev/null | grep -q 'crypto_LUKS'; then
            # Clean up any stale LUKS mapping for this snapshot from a previous crashed run
            STALE_LUKS="pvc-snap-$(echo "${snap}" | md5sum | cut -c1-12)"
            if [ -e "/dev/mapper/${STALE_LUKS}" ]; then
                umount "/dev/mapper/${STALE_LUKS}" 2>/dev/null || true
                cryptsetup close "${STALE_LUKS}" 2>/dev/null || true
            fi
            LUKS_KEY="/root/.luks-backup-key"
            LUKS_NAME="pvc-snap-$(echo "${snap}" | md5sum | cut -c1-12)"
            if [ -f "${LUKS_KEY}" ] && cryptsetup open --type luks --key-file "${LUKS_KEY}" --readonly "/dev/pve/${snap}" "${LUKS_NAME}" 2>&1; then
                MOUNT_DEV="/dev/mapper/${LUKS_NAME}"
                MOUNT_OPTS="ro,noload"  # noload skips ext4 journal replay on read-only LUKS
                log "  LUKS: decrypted ${snap} → ${LUKS_NAME}"
            else
                warn "Failed to decrypt LUKS snapshot ${snap}"
                PVC_FAIL=$((PVC_FAIL + 1))
                continue
            fi
        fi

        # Mount snapshot read-only, rsync files
        if timeout 30 mount -o "${MOUNT_OPTS}" "${MOUNT_DEV}" "${PVC_MOUNT}" 2>&1; then
            dst="${BACKUP_ROOT}/pvc-data/${WEEK}/${ns_pvc}"
            mkdir -p "${dst}"
            rsync_rc=0
            rsync -az --delete \
                ${PREV:+--link-dest="${PREV}/${ns_pvc}/"} \
                "${PVC_MOUNT}/" "${dst}/" 2>&1 || rsync_rc=$?
            if [ "$rsync_rc" -eq 0 ]; then
                PVC_COUNT=$((PVC_COUNT + 1))
            elif [ "$rsync_rc" -eq 23 ] && [ -n "${LUKS_NAME}" ]; then
                # rsync 23 = partial transfer; expected for LUKS noload mounts
                # (in-flight writes have corrupt metadata from skipped journal replay)
                PVC_COUNT=$((PVC_COUNT + 1))
                log "  partial rsync (LUKS noload) for ${ns_pvc} — OK"
            else
                warn "rsync failed for ${ns_pvc} (rc=$rsync_rc)"
                PVC_FAIL=$((PVC_FAIL + 1))
            fi

            # Auto-detect and safely backup SQLite databases from snapshot
            if command -v sqlite3 &>/dev/null; then
                find "${PVC_MOUNT}" -maxdepth 3 \
                    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
                    -size +0 -type f 2>/dev/null | while read -r dbfile; do
                    # Verify it's actually SQLite (magic number check)
                    if head -c 15 "$dbfile" 2>/dev/null | grep -q 'SQLite format 3'; then
                        relpath="${dbfile#${PVC_MOUNT}/}"
                        dest_file="${BACKUP_ROOT}/sqlite-backup/${WEEK}/${ns_pvc}/${relpath}"
                        mkdir -p "$(dirname "${dest_file}")"
                        if sqlite3 "file://${dbfile}?mode=ro" ".backup '${dest_file}'" 2>/dev/null; then
                            log "    SQLite: ${ns_pvc}/${relpath}"
                        else
                            cp "${dbfile}" "${dest_file}" 2>/dev/null || true
                        fi
                    fi
                done
            fi

            umount "${PVC_MOUNT}" 2>/dev/null || umount -l "${PVC_MOUNT}" 2>/dev/null || true
        else
            warn "Failed to mount snapshot ${snap}"
            PVC_FAIL=$((PVC_FAIL + 1))
        fi

        # Close LUKS device if we opened one
        if [ -n "${LUKS_NAME}" ]; then
            cryptsetup close "${LUKS_NAME}" 2>/dev/null || true
        fi
    done

    log "  PVC copy: ${PVC_COUNT} OK, ${PVC_FAIL} failed"
    [ "${PVC_FAIL}" -gt 0 ] && STATUS=1

    # Add PVC files to manifest
    if [ -d "${BACKUP_ROOT}/pvc-data/${WEEK}" ]; then
        find "${BACKUP_ROOT}/pvc-data/${WEEK}" -type f 2>/dev/null | \
            sed "s|^${BACKUP_ROOT}/||" >> "${MANIFEST}"
    fi

    # Prune old weekly versions (keep 4)
    ls -1d "${BACKUP_ROOT}/pvc-data"/????-?? 2>/dev/null | head -n -4 | xargs rm -rf 2>/dev/null || true
    ls -1d "${BACKUP_ROOT}/sqlite-backup"/????-?? 2>/dev/null | head -n -4 | xargs rm -rf 2>/dev/null || true

    PVC_BYTES=$(du -sb "${BACKUP_ROOT}/pvc-data/${WEEK}" 2>/dev/null | cut -f1 || true)
    TOTAL_BYTES=$((TOTAL_BYTES + ${PVC_BYTES:-0}))
fi

# ============================================================
# STEP 3: pfsense backup (config.xml + full tar)
# ============================================================
log "--- Step 3: pfsense backup ---"
PFSENSE_DEST="${BACKUP_ROOT}/pfsense"
DATE=$(date +%Y%m%d)
mkdir -p "${PFSENSE_DEST}"

if timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 root@10.0.20.1 true 2>/dev/null; then
    # config.xml — primary restore artifact
    if scp -o ConnectTimeout=10 root@10.0.20.1:/cf/conf/config.xml "${PFSENSE_DEST}/config-${DATE}.xml" 2>/dev/null; then
        log "  OK: config.xml"
        echo "pfsense/config-${DATE}.xml" >> "${MANIFEST}"
    else
        warn "Failed to copy pfsense config.xml"
        STATUS=1
    fi

    # Full filesystem tar
    if ssh -o ConnectTimeout=10 root@10.0.20.1 \
        "tar czf - --exclude=/dev --exclude=/proc --exclude=/tmp --exclude=/var/run /" \
        > "${PFSENSE_DEST}/pfsense-full-${DATE}.tar.gz" 2>/dev/null; then
        log "  OK: full tar ($(du -sh "${PFSENSE_DEST}/pfsense-full-${DATE}.tar.gz" | cut -f1))"
        echo "pfsense/pfsense-full-${DATE}.tar.gz" >> "${MANIFEST}"
    else
        warn "Failed to tar pfsense filesystem"
        STATUS=1
    fi

    # Retention: keep 4 weekly copies
    ls -t "${PFSENSE_DEST}"/config-*.xml 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true
    ls -t "${PFSENSE_DEST}"/pfsense-full-*.tar.gz 2>/dev/null | tail -n +5 | xargs rm -f 2>/dev/null || true

    # Push pfsense-specific metric
    echo "backup_last_success_timestamp $(date +%s)" | \
        curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/pfsense-backup" 2>/dev/null || true
else
    warn "Cannot SSH to pfsense (10.0.20.1) — skipping"
    STATUS=1
fi

# ============================================================
# STEP 4: PVE host config backup
# ============================================================
log "--- Step 4: PVE host config ---"
mkdir -p "${BACKUP_ROOT}/pve-config/scripts"
rsync -az --delete /etc/pve/ "${BACKUP_ROOT}/pve-config/etc-pve/" 2>&1 || { warn "Failed to sync /etc/pve"; STATUS=1; }
for script in /usr/local/bin/lvm-pvc-snapshot /usr/local/bin/daily-backup /usr/local/bin/offsite-sync-backup; do
    [ -f "${script}" ] && cp "${script}" "${BACKUP_ROOT}/pve-config/scripts/" 2>/dev/null || true
done
find "${BACKUP_ROOT}/pve-config" -type f 2>/dev/null | sed "s|^${BACKUP_ROOT}/||" >> "${MANIFEST}"
log "  OK: PVE config"

# ============================================================
# STEP 5: Prune LVM snapshots older than 7 days
# ============================================================
log "--- Step 5: Snapshot pruning (7-day retention) ---"
/usr/local/bin/lvm-pvc-snapshot prune 2>&1 || { warn "Snapshot prune failed"; STATUS=1; }

# ============================================================
# Done
# ============================================================
MANIFEST_LINES=$(wc -l < "${MANIFEST}" 2>/dev/null || echo 0)
log "=== Weekly backup complete (status=${STATUS}, ${TOTAL_BYTES} bytes, ${MANIFEST_LINES} files in manifest) ==="
push_metrics "${STATUS}" "${TOTAL_BYTES}"
exit "${STATUS}"
