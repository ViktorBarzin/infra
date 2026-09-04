#!/usr/bin/env bash
# devvm-home-backup — file-level incremental backup of devvm's /home to sda.
# Deploy to PVE host at /usr/local/bin/devvm-home-backup (strip the .sh).
# Schedule: Daily 03:30 via systemd timer.
#
# WHY THIS EXISTS
# ---------------
# devvm (VM 102) holds ~116 GiB of /home — per-user home dirs, local-only git
# repos (the monorepo root has no remote), and agent state. Until 2026-08-16 the
# ONLY thing protecting it was `vzdump-vms`, which takes a FULL image backup
# every night: vzdump's .vma format has no incremental mode, so it re-read the
# entire 228 GiB disk daily. Measured against the host's own totals that was
# ~245 GB/night = ~40% of ALL reads on sdc, and 69.6 GB written to sda = ~72% of
# sda's daily writes. Those 75 minutes are where sdc's p99 read latency (~90 ms)
# came from — every VM, every Proxmox-CSI PVC and etcd share that spindle.
#
# This script covers the same data the cheap way. rsync only reads what changed,
# and `--link-dest` makes each generation a hardlink farm against the previous
# one, so N retained days cost ~1x plus the deltas. With the exclusions below the
# tracked set is ~29 GB (vs ~116 GiB raw) — smaller than ONE vzdump archive, so
# this both frees space on sda and gives per-file restore granularity, which is
# far more useful for a dev box than a whole-disk image.
#
# vzdump-vms is NOT retired — it drops to weekly and stays as the bare-metal
# restore floor (a .vma restores the whole VM in one shot; this script does not).
#
# 3-2-1 IS PRESERVED. Copy 1 = live on sdc. Copy 2 = here, on sda. Copy 3 =
# Synology: `offsite-sync-backup`'s monthly full pass (days 1-7) rsyncs all of
# /mnt/backup with `-H`, which rebuilds the hardlink farm remotely instead of
# exploding it into N full copies. Nothing extra to wire up.
#
# PULL, NOT PUSH — deliberate. The PVE host holds the credential and reaches
# INTO devvm; devvm has no way to reach its own backups. A compromised or
# mistaken devvm therefore cannot delete them. The key on the devvm side is
# pinned to `command="/usr/bin/rrsync -ro /home",restrict`, so it can do exactly
# one thing: read /home. An interactive shell over that key is refused.
#
# RESTORE:
#   ls /mnt/backup/devvm-home/                       # pick a generation
#   rsync -aH --numeric-ids \
#     /mnt/backup/devvm-home/<YYYY-MM-DD>/wizard/some/path  <target>
# Whole-home restore goes to a staging dir first, never straight over a live
# /home. For a lost-the-whole-VM event, restore the weekly vzdump image, then
# rsync the newest generation over the top to recover the last day's work.
set -euo pipefail

# systemd oneshot units get a minimal PATH (/usr/bin:/bin).
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# --- Configuration ---
# devvm is 10.0.10.10 (VLAN 10). It is NOT 10.0.20.102 — the VMID does not
# appear in its address, and 10.0.20.102 is a different machine entirely.
SRC="${DEVVM_HOME_SRC:-root@10.0.10.10}"
SSH_KEY="${DEVVM_HOME_SSH_KEY:-/root/.ssh/id_devvm_backup}"
DEST_ROOT="${DEVVM_HOME_DEST:-/mnt/backup/devvm-home}"
KEEP="${DEVVM_HOME_KEEP:-14}"          # retained daily generations (hardlinked)
BACKUP_ROOT="/mnt/backup"
PUSHGATEWAY="${DEVVM_HOME_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="devvm-home-backup"
LOCKFILE="/run/devvm-home-backup.lock"

# The remote key is scoped by rrsync to /home, so the remote path is relative to
# it: ":/" here means "/home" on devvm, not the devvm root filesystem.
REMOTE_PATH="/"

# --- Exclusions ---
# Rule: exclude only what is REGENERABLE from something we already keep. When in
# doubt, back it up — a backup that is 20% larger costs disk, a backup missing
# real work costs work. Notably NOT excluded: ~/.ssh, ~/.config, ~/.claude
# (agent session history), ~/.gnupg, and ~/code (git repos whose worktrees carry
# uncommitted work and whose monorepo root has no remote at all).
#
# The rule needs the patterns to actually match, and until 2026-09-03 several
# did not, so ~8 GB of regenerable content was being copied every night.
# `**/.venv/` and `**/venv/` were meant to catch virtualenvs but missed
# ~/.virtualenvs and ~/bg-bakeoff-venv, and four SDK or plugin caches had no
# pattern at all: ~/.terraform.d (provider plugin cache), ~/android-sdk,
# ~/.dotnet and ~/google-cloud-sdk. `/*/go/pkg/mod/` also only caught part of
# ~/go, so the whole tree goes. Each of them is rebuilt by re-running an
# installer or `terraform init`.
#
# Measured with `rsync -an --stats` over the live /home on 2026-09-03:
#   before  607,968 files  37.81 GB
#   after   446,398 files  29.72 GB
#
# What stays, and why: ~/code holds the only copy of two repos with no remote
# (agent-conductor, cloud) plus unpushed commits and uncommitted work in others.
# The 39 repos that DO live on self-hosted Forgejo are covered a second way, by
# the Forgejo PVC backup in /mnt/backup/pvc-data — if that ever stops, this
# home mirror becomes their only second copy and the trade-off changes.
EXCLUDES=(
    --exclude='/*/.cache/'
    --exclude='**/node_modules/'
    --exclude='**/.venv/'
    --exclude='**/venv/'
    --exclude='/*/.virtualenvs/'
    --exclude='**/*-venv/'
    --exclude='**/__pycache__/'
    --exclude='**/.mypy_cache/'
    --exclude='**/.pytest_cache/'
    --exclude='**/.ruff_cache/'
    --exclude='**/target/debug/'
    --exclude='**/target/release/'
    --exclude='/*/.cargo/registry/'
    --exclude='/*/.rustup/'
    --exclude='/*/.npm/'
    --exclude='/*/.yarn/cache/'
    --exclude='/*/.pnpm-store/'
    --exclude='/*/.bun/install/cache/'
    --exclude='/*/go/'
    --exclude='/*/.local/share/Trash/'
    --exclude='/*/.local/share/containers/'
    --exclude='/*/.vscode-server/'
    --exclude='/*/.cursor-server/'
    --exclude='/*/.ollama/'
    --exclude='/*/snap/'
    --exclude='**/.terraform/'
    --exclude='/*/.terraform.d/'
    --exclude='/*/.gradle/'
    --exclude='/*/android-sdk/'
    --exclude='/*/.dotnet/'
    --exclude='/*/google-cloud-sdk/'
    --exclude='/*/.m2/repository/'
    --exclude='**/.next/'
    --exclude='**/.nuxt/'
    --exclude='**/.svelte-kit/'
    --exclude='**/dist/'
    --exclude='**/build/'
    --exclude='**/*.pyc'
)

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }

# --- Metrics (always returns 0 so it never trips set -e) ---
push_metrics() {
    local status="${1:-0}" bytes="${2:-0}" files="${3:-0}" secs="${4:-0}" now
    now=$(date +%s)
    {
        echo "devvm_home_backup_last_run_timestamp ${now}"
        echo "devvm_home_backup_last_status ${status}"
        echo "devvm_home_backup_last_bytes ${bytes}"
        echo "devvm_home_backup_last_files ${files}"
        echo "devvm_home_backup_last_duration_seconds ${secs}"
        echo "devvm_home_backup_generations ${5:-0}"
        [ "${status}" -eq 0 ] && echo "devvm_home_backup_last_success_timestamp ${now}"
    } | curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || true
    return 0
}

# --- Locking (push a non-success metric if systemd kills us mid-run) ---
KILLED=""
cleanup() {
    rm -f "${LOCKFILE}"
    # Must be `if…fi`, NOT `[ … ] && …` — a bash EXIT trap whose LAST command
    # returns non-zero overrides the script's `exit 0`. Same reasoning as
    # vzdump-vms; see the comment there.
    if [ -n "${KILLED}" ]; then push_metrics 2 0 0 0 0; fi
}
trap cleanup EXIT
trap 'KILLED=1; exit 143' TERM INT

if ! ( set -o noclobber; echo $$ > "${LOCKFILE}" ) 2>/dev/null; then
    warn "Another instance running (PID $(cat "${LOCKFILE}" 2>/dev/null || echo unknown)) — exiting"
    exit 0
fi

# --- Preconditions ---
if ! mountpoint -q "${BACKUP_ROOT}"; then
    warn "${BACKUP_ROOT} not mounted — aborting"; push_metrics 1 0 0 0 0; exit 1
fi
if [ ! -f "${SSH_KEY}" ]; then
    warn "SSH key ${SSH_KEY} missing — aborting"; push_metrics 1 0 0 0 0; exit 1
fi
mkdir -p "${DEST_ROOT}"

SSH_CMD="ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15"

# --- Main ---
STARTED=$(date +%s)
TODAY=$(date +%F)
DEST="${DEST_ROOT}/${TODAY}"
# Newest existing generation that is not today's — the --link-dest base.
PREV=$(find "${DEST_ROOT}" -maxdepth 1 -mindepth 1 -type d -name '20*' ! -name "${TODAY}" -printf '%f\n' 2>/dev/null | sort | tail -1 || true)

log "=== devvm-home-backup starting (src ${SRC}:${REMOTE_PATH}, dest ${DEST}, keep ${KEEP}) ==="
[ -n "${PREV}" ] && log "link-dest base: ${PREV}" || log "no previous generation — this run is a full copy"

STATUS=0
STATS_FILE=$(mktemp)

# --numeric-ids: devvm and the PVE host have different passwd databases; keep
#   uid/gid numeric so a restore puts ownership back exactly as it was.
# --delete: each generation is a faithful mirror of /home at that moment.
# -H: preserve hardlinks *within* the transferred set (offsite-sync relies on
#   the same flag to keep the generation farm from exploding into N copies).
if rsync -aH --numeric-ids --delete --stats \
    --timeout=3600 \
    ${PREV:+--link-dest="../${PREV}"} \
    "${EXCLUDES[@]}" \
    -e "${SSH_CMD}" \
    "${SRC}:${REMOTE_PATH}" "${DEST}/" >"${STATS_FILE}" 2>&1; then
    log "rsync OK"
else
    rc=$?
    # 24 = "file vanished during transfer" — normal on a live home dir, not a
    # failure. Anything else is.
    if [ "${rc}" -eq 24 ]; then
        log "rsync completed with vanished files (rc=24) — treating as success"
    else
        warn "rsync failed (rc=${rc})"
        tail -20 "${STATS_FILE}" >&2 || true
        STATUS=1
    fi
fi

XFER_BYTES=$(awk '/^Total transferred file size:/ {gsub(/,/,"",$5); print $5; exit}' "${STATS_FILE}" 2>/dev/null || echo 0)
NUM_FILES=$(awk '/^Number of files:/ {gsub(/,/,"",$4); print $4; exit}' "${STATS_FILE}" 2>/dev/null || echo 0)
[ -z "${XFER_BYTES}" ] && XFER_BYTES=0
[ -z "${NUM_FILES}" ] && NUM_FILES=0
log "transferred $(numfmt --to=iec "${XFER_BYTES}" 2>/dev/null || echo "${XFER_BYTES}B") across ${NUM_FILES} files"
rm -f "${STATS_FILE}"

# Only publish `latest` and prune once we know this generation is good —
# a failed run must never become the newest restore point.
if [ "${STATUS}" -eq 0 ]; then
    ln -sfn "${TODAY}" "${DEST_ROOT}/latest"

    mapfile -t gens < <(find "${DEST_ROOT}" -maxdepth 1 -mindepth 1 -type d -name '20*' -printf '%f\n' 2>/dev/null | sort -r || true)
    if [ "${#gens[@]}" -gt "${KEEP}" ]; then
        for old in "${gens[@]:${KEEP}}"; do
            log "prune: ${old}"
            rm -rf "${DEST_ROOT:?}/${old}"
        done
    fi
else
    warn "run failed — leaving 'latest' pointing at the previous good generation"
    # A half-written generation is worse than no generation: it looks like a
    # restore point but isn't one.
    [ -n "${PREV}" ] && [ -d "${DEST}" ] && rm -rf "${DEST:?}" && log "removed partial ${TODAY}"
fi

GEN_COUNT=$(find "${DEST_ROOT}" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null | wc -l)
ELAPSED=$(( $(date +%s) - STARTED ))
log "=== devvm-home-backup complete (status=${STATUS}, ${GEN_COUNT} generations, ${ELAPSED}s) ==="
push_metrics "${STATUS}" "${XFER_BYTES}" "${NUM_FILES}" "${ELAPSED}" "${GEN_COUNT}"
exit "${STATUS}"
