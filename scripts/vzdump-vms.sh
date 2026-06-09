#!/usr/bin/env bash
# vzdump-vms — image-level backup of hand-managed Proxmox VMs (NOT in Terraform).
# Deploy to PVE host at /usr/local/bin/vzdump-vms (strip the .sh).
# Schedule: Daily 01:00 via systemd timer.
#
# WHY: the hand-managed Linux VMs (devvm, …) have NO image backup. nfs-mirror /
# daily-backup / offsite-sync cover cluster PVCs, NFS, pfSense and PVE config —
# but never the VM disks themselves. A lost devvm disk = unrecoverable home dirs
# + local-only git repos (the monorepo root has no remote). This takes a live
# `vzdump --mode snapshot` of each configured VMID to /mnt/backup/vzdump (sda =
# Copy 2). The monthly offsite-sync full pass (days 1-7) mirrors /mnt/backup —
# including this dir — to Synology with --delete (Copy 3), bounded to local
# retention. We deliberately do NOT append to the incremental manifest: it never
# deletes, so daily multi-GB images would accumulate unbounded on Synology.
#
# RESTORE: pick a dump under /mnt/backup/vzdump, then on the PVE host:
#   qmrestore /mnt/backup/vzdump/vzdump-qemu-<vmid>-<ts>.vma.zst <new-or-same-vmid>
# (restore to a fresh VMID first if the original still exists, then swap), or use
# the PVE UI (Datacenter → Storage → upload dir → Restore). See backup-dr.md.
set -euo pipefail

# systemd oneshot units get a minimal PATH (/usr/bin:/bin) — qm and vzdump live
# in /usr/sbin, so set an explicit PATH or the script silently can't find them.
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# --- Configuration ---
VMIDS="${VZDUMP_VMIDS:-102}"                       # space-separated. 102 = devvm. Add VMIDs here.
DUMPDIR="${VZDUMP_DUMPDIR:-/mnt/backup/vzdump}"
KEEP="${VZDUMP_KEEP:-3}"                           # retain N newest dumps per VMID on sda
COMPRESS="${VZDUMP_COMPRESS:-zstd}"
BACKUP_ROOT="/mnt/backup"
PUSHGATEWAY="${VZDUMP_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="vzdump-backup"
LOCKFILE="/run/vzdump-vms.lock"

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }

# --- Metrics (always returns 0 so it never trips set -e) ---
push_metrics() {
    local status="${1:-0}" bytes="${2:-0}" now
    now=$(date +%s)
    {
        echo "vzdump_last_run_timestamp ${now}"
        echo "vzdump_last_status ${status}"
        echo "vzdump_last_bytes ${bytes}"
        [ "${status}" -eq 0 ] && echo "vzdump_last_success_timestamp ${now}"
    } | curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
    return 0
}

# --- Locking (push a non-success metric if systemd kills us mid-run) ---
KILLED=""
cleanup() {
    rm -f "${LOCKFILE}"
    # NB: must be `if…fi`, NOT `[ … ] && …` — a bash EXIT trap whose LAST command
    # returns non-zero overrides the script's `exit 0`, so the `&&` short-circuit
    # (when KILLED is empty) would falsely mark a successful backup as failed.
    if [ -n "${KILLED}" ]; then push_metrics 2 0; fi
}
trap cleanup EXIT
trap 'KILLED=1; exit 143' TERM INT

if ! ( set -o noclobber; echo $$ > "${LOCKFILE}" ) 2>/dev/null; then
    warn "Another instance running (PID $(cat "${LOCKFILE}" 2>/dev/null || echo unknown)) — exiting"
    exit 0
fi

# --- Preconditions ---
if ! mountpoint -q "${BACKUP_ROOT}"; then
    warn "${BACKUP_ROOT} not mounted — aborting"; push_metrics 1 0; exit 1
fi
mkdir -p "${DUMPDIR}"

# --- Main ---
log "=== vzdump-vms starting (VMIDs: ${VMIDS}, keep ${KEEP}) ==="
STATUS=0
TOTAL_BYTES=0

for vmid in ${VMIDS}; do
    if ! qm status "${vmid}" >/dev/null 2>&1; then
        warn "VMID ${vmid} not found on this node — skipping"
        STATUS=1
        continue
    fi

    log "--- vzdump ${vmid} ($(qm config "${vmid}" 2>/dev/null | sed -n 's/^name: //p')) ---"
    if vzdump "${vmid}" \
        --dumpdir "${DUMPDIR}" \
        --mode snapshot \
        --compress "${COMPRESS}" \
        --ionice 7 \
        --quiet 1; then
        newest=$(ls -t "${DUMPDIR}"/vzdump-qemu-"${vmid}"-*.vma.* 2>/dev/null | grep -v '\.notes$' | head -1 || true)
        if [ -n "${newest}" ]; then
            sz=$(stat -c%s "${newest}" 2>/dev/null || echo 0)
            TOTAL_BYTES=$((TOTAL_BYTES + sz))
            log "  OK: $(basename "${newest}") ($(numfmt --to=iec "${sz}" 2>/dev/null || echo "${sz}B"))"
        fi
    else
        warn "vzdump ${vmid} failed (rc=$?)"
        STATUS=1
    fi

    # Retention: keep newest ${KEEP} per VMID (archive + its .log + .notes siblings).
    mapfile -t archives < <(ls -t "${DUMPDIR}"/vzdump-qemu-"${vmid}"-*.vma.* 2>/dev/null | grep -v '\.notes$' || true)
    if [ "${#archives[@]}" -gt "${KEEP}" ]; then
        for old in "${archives[@]:${KEEP}}"; do
            prefix="${old%.vma.*}"   # …/vzdump-qemu-<vmid>-<YYYY_MM_DD>-<HH_MM_SS>
            log "  prune: $(basename "${prefix}")"
            rm -f "${prefix}".vma.* "${prefix}".log 2>/dev/null || true
        done
    fi
done

log "=== vzdump-vms complete (status=${STATUS}, $(numfmt --to=iec "${TOTAL_BYTES}" 2>/dev/null || echo "${TOTAL_BYTES}B")) ==="
push_metrics "${STATUS}" "${TOTAL_BYTES}"
exit "${STATUS}"
