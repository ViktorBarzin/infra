#!/usr/bin/env bash
# weekly-backup — 3-2-1 backup: NFS mirror + PVC file copy + pfsense + PVE config
# Deploy to PVE host at /usr/local/bin/weekly-backup
# Schedule: Weekly Sunday 05:00 via systemd timer
set -euo pipefail

# --- Configuration ---
BACKUP_ROOT="/mnt/backup"
NFS_SERVER="10.0.10.15"
NFS_BASE="/mnt/main"
NFS_MOUNT="/mnt/nfs-truenas"
PVC_MOUNT="/tmp/pvc-mount"
PUSHGATEWAY="${WEEKLY_BACKUP_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="weekly-backup"
LOCKFILE="/run/weekly-backup.lock"
MANIFEST="${BACKUP_ROOT}/.changed-files"
MAPPING_CACHE="${BACKUP_ROOT}/.lv-pvc-mapping.json"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

# NFS backup directories to mirror
BACKUP_DIRS=(
    mysql-backup
    postgresql-backup
    vault-backup
    vaultwarden-backup
    redis-backup
    etcd-backup
    headscale-backup
    prometheus-backup
    plotting-book-backup
)

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; push_metrics 1 0; exit 1; }

# --- Locking ---
cleanup() {
    umount "${PVC_MOUNT}" 2>/dev/null || true
    umount "${NFS_MOUNT}" 2>/dev/null || true
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
weekly_backup_last_run_timestamp $(date +%s)
weekly_backup_last_status ${status}
weekly_backup_bytes_synced ${bytes}
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

# --- Main ---
log "=== Weekly backup starting ==="

if ! mountpoint -q "${BACKUP_ROOT}"; then
    die "${BACKUP_ROOT} is not mounted"
fi

STATUS=0
TOTAL_BYTES=0

# Clear manifest for this run
> "${MANIFEST}"

# ============================================================
# STEP 1: Mirror NFS backup directories from TrueNAS
# ============================================================
log "--- Step 1: NFS backup mirror ---"
mkdir -p "${NFS_MOUNT}"
if ! mountpoint -q "${NFS_MOUNT}"; then
    if ! timeout 30 mount -t nfs -o soft,timeo=30,retrans=3,ro "${NFS_SERVER}:${NFS_BASE}" "${NFS_MOUNT}"; then
        warn "Failed to mount NFS — skipping NFS mirror step"
        STATUS=1
    fi
fi

if mountpoint -q "${NFS_MOUNT}"; then
    mkdir -p "${BACKUP_ROOT}/nfs-mirror"
    for dir in "${BACKUP_DIRS[@]}"; do
        src="${NFS_MOUNT}/${dir}/"
        dst="${BACKUP_ROOT}/nfs-mirror/${dir}/"
        mkdir -p "${dst}"
        if [ ! -d "${src}" ]; then
            continue
        fi
        log "Syncing ${dir}..."
        if rsync -az --delete --out-format='%n' "${src}" "${dst}" 2>/dev/null | \
           sed "s|^|nfs-mirror/${dir}/|" >> "${MANIFEST}"; then
            size=$(du -sb "${dst}" 2>/dev/null | cut -f1)
            TOTAL_BYTES=$((TOTAL_BYTES + size))
            log "  OK: ${dir} ($(du -sh "${dst}" | cut -f1))"
        else
            warn "Failed to sync ${dir}"
            STATUS=1
        fi
    done
    umount "${NFS_MOUNT}" 2>/dev/null || true
fi

# ============================================================
# STEP 2: PVC file-level copy from LVM thin snapshots
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

        # Mount snapshot read-only, rsync files
        if timeout 30 mount -o ro "/dev/pve/${snap}" "${PVC_MOUNT}" 2>&1; then
            dst="${BACKUP_ROOT}/pvc-data/${WEEK}/${ns_pvc}"
            mkdir -p "${dst}"
            if rsync -az --delete \
                ${PREV:+--link-dest="${PREV}/${ns_pvc}/"} \
                "${PVC_MOUNT}/" "${dst}/" 2>&1; then
                PVC_COUNT=$((PVC_COUNT + 1))
            else
                warn "rsync failed for ${ns_pvc}"
                PVC_FAIL=$((PVC_FAIL + 1))
            fi
            umount "${PVC_MOUNT}" 2>/dev/null || umount -l "${PVC_MOUNT}" 2>/dev/null || true
        else
            warn "Failed to mount snapshot ${snap}"
            PVC_FAIL=$((PVC_FAIL + 1))
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
for script in /usr/local/bin/lvm-pvc-snapshot /usr/local/bin/weekly-backup /usr/local/bin/offsite-sync-backup; do
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
