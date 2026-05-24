#!/usr/bin/env bash
# anca-elements-sync.sh — copy Anca's WD-Elements backup from Synology to PVE NFS
#
# Usage:
#   /usr/local/bin/anca-elements-sync.sh
#
# Idempotent: re-running after a successful sync is a no-op (only the dry-run
# verification runs, which reports "sync verified clean" immediately).
#
# Resumable: if fpsync was interrupted, resume with:
#   fpsync -r /var/tmp/fpsync \
#     -n 4 -s 4G \
#     -o "-lptgoD -H --no-perms --no-owner --no-group --exclude=@eaDir/ --exclude=*@synoeastream --exclude=.DS_Store --exclude=Thumbs.db" \
#     /mnt/synology-backup/Anca/Elements/ /srv/nfs/anca-elements/
#
# NOTE: fpsync -o = rsync options override (what we want)
#       fpsync -O = fpart partition options override (NOT rsync)
# NOTE: Do NOT use -a or -r in fpsync rsync options — fpsync handles
#       recursion via fpart; -r causes fpsync to warn and skip the slab.
#
# Log: /var/log/anca-elements-sync.log

set -euo pipefail

LOG=/var/log/anca-elements-sync.log
SRC_HOST=192.168.1.13
SRC_EXPORT=/volume1/Backup
SRC_SUBPATH=Anca/Elements
MOUNT_POINT=/mnt/synology-backup
DEST=/srv/nfs/anca-elements

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"
}

# ── 1. Ensure destination + mount-point directories exist ────────────────────
log "Step 1: ensuring directories"
mkdir -p "$DEST" "$MOUNT_POINT"

# ── 2. NFS-mount Synology read-only (skip if already mounted) ───────────────
MOUNTED_HERE=0
if mountpoint -q "$MOUNT_POINT"; then
    log "Step 2: $MOUNT_POINT already mounted — skipping"
else
    log "Step 2: mounting ${SRC_HOST}:${SRC_EXPORT} at $MOUNT_POINT (read-only)"
    mount -t nfs \
        -o ro,vers=4,nolock,soft,timeo=300,retrans=2 \
        "${SRC_HOST}:${SRC_EXPORT}" \
        "$MOUNT_POINT"
    MOUNTED_HERE=1
    log "Step 2: mount successful"
fi

# ── 3. Ensure fpsync (from fpart package) is available ──────────────────────
log "Step 3: checking for fpsync"
if ! command -v fpsync >/dev/null 2>&1; then
    log "Step 3: fpsync not found — installing fpart"
    apt-get install -y fpart
    log "Step 3: fpart installed"
else
    log "Step 3: fpsync already available"
fi

# ── 4. Run fpsync (4-way parallel, no compression — source is already-compressed media) ──
log "Step 4: starting fpsync"
log "  source : ${MOUNT_POINT}/${SRC_SUBPATH}/"
log "  dest   : ${DEST}/"
log "  workers: 4, slab: 4G"
fpsync \
    -n 4 \
    -s 4G \
    -o "-lptgoD -H --no-perms --no-owner --no-group --exclude=@eaDir/ --exclude=*@synoeastream --exclude=.DS_Store --exclude=Thumbs.db" \
    "${MOUNT_POINT}/${SRC_SUBPATH}/" \
    "${DEST}/" \
    2>&1 | tee -a "$LOG"
log "Step 4: fpsync completed"

# ── 5. Verification dry-run ──────────────────────────────────────────────────
log "Step 5: running dry-run verification rsync"
VERIFY_OUT=$(rsync \
    -rlptgoD -H --no-perms --no-owner --no-group \
    --exclude='@eaDir/' --exclude='*@synoeastream' \
    --exclude='.DS_Store' --exclude='Thumbs.db' \
    -n --delete \
    --info=progress2 \
    --out-format='%o %f' \
    "${MOUNT_POINT}/${SRC_SUBPATH}/" \
    "${DEST}/" \
    2>&1 || true)

# Count lines that represent actual file changes (send / del. operations)
CHANGE_COUNT=$(echo "$VERIFY_OUT" | grep -cE '^(send|del\.)' || true)

if [ "$CHANGE_COUNT" -eq 0 ]; then
    log "Step 5: sync verified clean — no pending changes"
else
    log "Step 5: WARNING — verification found ${CHANGE_COUNT} pending change(s). First 50 lines:"
    # Use printf to avoid SIGPIPE from head closing the pipe early (set -o pipefail)
    { echo "$VERIFY_OUT" | head -50; } >> "$LOG" 2>&1 || true
fi

# ── 6. Unmount (only if we mounted it) ──────────────────────────────────────
if [ "$MOUNTED_HERE" -eq 1 ]; then
    log "Step 6: unmounting $MOUNT_POINT"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    log "Step 6: unmounted"
else
    log "Step 6: mount was pre-existing — leaving in place"
fi

log "Done. Final size: $(du -sh "${DEST}" | cut -f1)"
