#!/usr/bin/env bash
# t3-state-pull — copy the devvm's nightly T3 snapshots onto sda.
# Deploy to PVE host at /usr/local/bin/t3-state-pull (scripts/ci/pve-scripts-sync.sh).
# Schedule: a nightly-chain step, after devvm-home-backup and before
# offsite-sync-backup, so the Synology gets the same files the same night.
#
# WHY THIS EXISTS
# ---------------
# Every T3 thread, project registration and paired session of a user lives in
# one SQLite file, ~/.t3/userdata/statev2.sqlite, on the devvm's own disk.
# t3-backup-state (devvm, daily ~03:30 UTC) already writes a clean
# `VACUUM INTO` copy per user to /var/backups/t3-state/<user>/, but that is on
# the same disk, so it is lost with the VM. The disposable-devvm plan
# (docs/plans/2026-11-11-disposable-devvm.md) keeps T3 threads in this pulled
# copy: a rebuilt devvm gets them back with t3-restore-state.
#
# WHAT IT COPIES
# --------------
# Only the daily snapshots, state-YYYYMMDD-HHMMSS.sqlite[.gz]. Pre-bump copies
# (state-prebump-*) are taken minutes after the daily one and exist for a
# version rollback on the box itself; journals and -wal/-shm are litter.
# The newest KEEP per user are kept under /mnt/backup/t3-state/<user>/, always
# as .sqlite.gz: the devvm leaves its newest snapshot uncompressed
# (devvm-cleanup gzips the rest), so this compresses that one itself, and
# takes the devvm's .gz once it exists. A snapshot already here is never
# fetched again, so a quiet night moves nothing.
#
# A file modified in the last SETTLE seconds is skipped: the chain can reach
# this step while t3-backup-state is still writing tonight's copy or
# devvm-cleanup is still gzipping yesterday's. Every kept file is checked
# (SQLite header, or `gzip -t`) before it replaces anything.
#
# Pruning holds when the newest snapshot is under a quarter of the largest
# one kept, and the step fails. That is what a rebuilt devvm whose T3 state
# never came back would send: an empty database, which KEEP nights later
# would have pushed every real generation out.
#
# PULL, NOT PUSH, like devvm-home-backup: the host holds the key and the devvm
# cannot reach its own backups. The devvm side pins the key to
# `command="/usr/bin/rrsync -ro /var/backups/t3-state",restrict` (declared in
# playbooks/devvm.yml, key text in Vault secret/devvm-authorized-keys field
# root-t3-state-pull), so it can read that one directory and nothing else.
#
# New files are appended to /mnt/backup/.changed-files, so offsite-sync's
# nightly incremental pass carries them; its monthly full pass reaps pruned
# ones on the Synology. nfs-mirror excludes /t3-state/ so its --delete leaves
# this tree alone.
#
# RESTORE: docs/architecture/backup-dr.md, "T3 snapshots".
# Tests: scripts/t3-state-pull.test.sh.
set -uo pipefail

# systemd oneshot units get a minimal PATH (/usr/bin:/bin). Appended, not
# prepended, so the tests can put stubs first.
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/usr/bin:/sbin:/bin"

# devvm is 10.0.10.10. rrsync roots the key at /var/backups/t3-state, so the
# remote "/" below is that directory.
SRC="${T3_PULL_SRC-root@10.0.10.10}"
REMOTE_ROOT="${T3_PULL_REMOTE_ROOT:-/}"
SSH_KEY="${T3_PULL_SSH_KEY:-/root/.ssh/id_devvm_t3_state}"
BACKUP_ROOT="${T3_PULL_BACKUP_ROOT:-/mnt/backup}"
DEST_ROOT="${T3_PULL_DEST:-${BACKUP_ROOT}/t3-state}"
KEEP="${T3_PULL_KEEP:-3}"
SETTLE="${T3_PULL_SETTLE:-1800}"
LOCKFILE="${T3_PULL_LOCKFILE:-/run/t3-state-pull.lock}"
MANIFEST="${BACKUP_ROOT}/.changed-files"
PUSHGATEWAY="${T3_PULL_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB=t3-state-pull

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }

STATUS=0
BYTES=0
STARTED=$(date +%s)

# Per-user gauges come from what is on sda, not from what the devvm listed,
# so a pull that cannot reach the devvm still publishes an ageing timestamp.
push_metrics() {
    local now d u newest n stamp
    now=$(date +%s)
    {
        echo "t3_state_pull_last_run_timestamp ${now}"
        echo "t3_state_pull_last_status ${STATUS}"
        echo "t3_state_pull_last_bytes ${BYTES}"
        echo "t3_state_pull_last_duration_seconds $((now - STARTED))"
        [ "${STATUS}" -eq 0 ] && echo "t3_state_pull_last_success_timestamp ${now}"
        for d in "${DEST_ROOT}"/*/; do
            [ -d "$d" ] || continue
            u=$(basename "$d")
            newest=$(find "$d" -maxdepth 1 -name 'state-*.sqlite.gz' -printf '%f\n' 2>/dev/null | sort | tail -1)
            n=$(find "$d" -maxdepth 1 -name 'state-*.sqlite.gz' 2>/dev/null | wc -l)
            echo "t3_state_pull_snapshots{user=\"${u}\"} ${n}"
            [[ $newest =~ ^state-([0-9]{8})-([0-9]{6})\.sqlite\.gz$ ]] || continue
            d=${BASH_REMATCH[1]}; stamp=${BASH_REMATCH[2]}
            # t3-backup-state names files in the devvm's time zone, UTC.
            echo "t3_state_pull_newest_snapshot_timestamp{user=\"${u}\"} $(date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${stamp:0:2}:${stamp:2:2}:${stamp:4:2}" +%s)"
        done
    } | curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" >/dev/null 2>&1 || true
}

manifest_append() {  # same lock daily-backup and nfs-mirror use
    ( flock -x 200; cat >>"${MANIFEST}" ) 200>"${MANIFEST}.lock"
}

exec 9>"${LOCKFILE}"
if ! flock -n 9; then
    warn "another t3-state-pull is running"; exit 0
fi

if ! mountpoint -q "${BACKUP_ROOT}"; then
    warn "${BACKUP_ROOT} not mounted, aborting"; STATUS=1; push_metrics; exit 1
fi
if [ ! -f "${SSH_KEY}" ]; then
    warn "SSH key ${SSH_KEY} missing, aborting"; STATUS=1; push_metrics; exit 1
fi
install -d -m 0700 "${DEST_ROOT}"

SSH_CMD="ssh -i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=15"
REMOTE="${SRC:+${SRC}:}${REMOTE_ROOT}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

log "=== t3-state-pull starting (${REMOTE} -> ${DEST_ROOT}, keep ${KEEP}) ==="

if ! rsync --list-only -r --timeout=300 -e "${SSH_CMD}" "${REMOTE}" >"${WORK}/list" 2>"${WORK}/err"; then
    warn "cannot list ${REMOTE}: $(tail -3 "${WORK}/err" | tr '\n' ' ')"
    STATUS=1; push_metrics; exit 1
fi

# pick["user/stem"] = the remote file to take for that snapshot: the .gz when
# one has settled, else the .sqlite.
declare -A pick=()
now=$(date +%s)
while read -r perms _size day time name; do
    [[ $perms == -* ]] || continue
    [[ $name =~ ^([a-z_][a-z0-9_-]*)/(state-[0-9]{8}-[0-9]{6})\.sqlite(\.gz)?$ ]] || continue
    key="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    gz=${BASH_REMATCH[3]}
    # rsync prints the mtime in this host's zone; date reads it back the same way.
    mtime=$(date -d "${day//\//-} ${time}" +%s 2>/dev/null) || continue
    if [ $((now - mtime)) -lt "${SETTLE}" ]; then
        log "skip ${name}: modified $((now - mtime))s ago, may still be being written"
        continue
    fi
    if [ -n "$gz" ] || [ -z "${pick[$key]:-}" ]; then pick[$key]=$name; fi
done <"${WORK}/list"

# fetch <user> <remote-name> <stem> -> 0 when <stem>.sqlite.gz is in place
fetch() {
    local u=$1 name=$2 stem=$3 dir="${DEST_ROOT}/$1" in got out
    in="${dir}/.incoming"
    install -d -m 0700 "$dir" "$in"
    got="${in}/$(basename "$name")"
    out="${dir}/${stem}.sqlite.gz"
    if ! rsync -t --timeout=3600 -e "${SSH_CMD}" "${REMOTE}${name}" "${in}/" 2>"${WORK}/err"; then
        warn "fetch failed: ${name}: $(tail -3 "${WORK}/err" | tr '\n' ' ')"; rm -f "$got"; return 1
    fi
    if [[ $got == *.gz ]]; then
        if ! gzip -t "$got" 2>/dev/null; then
            warn "${name} is not valid gzip, discarded"; rm -f "$got"; return 1
        fi
    else
        if [ "$(head -c 15 "$got")" != "SQLite format 3" ]; then
            warn "${name} has no SQLite header, discarded"; rm -f "$got"; return 1
        fi
        if ! nice gzip -6 -c "$got" >"${got}.gz" || ! gzip -t "${got}.gz"; then
            warn "compressing ${name} failed"; rm -f "$got" "${got}.gz"; return 1
        fi
        rm -f "$got"; got="${got}.gz"
    fi
    BYTES=$((BYTES + $(stat -c %s "$got")))
    chmod 0600 "$got"
    mv -f "$got" "$out"
    echo "${out#"${BACKUP_ROOT}"/}" | manifest_append
    log "pulled ${name} -> ${out} ($(stat -c %s "$out") bytes)"
}

# prune <user>: keep the newest KEEP, unless the newest looks like an empty DB.
prune() {
    local dir="${DEST_ROOT}/$1" newest largest f have=()
    mapfile -t have < <(find "$dir" -maxdepth 1 -name 'state-*.sqlite.gz' -printf '%f\n' | sort -r)
    [ "${#have[@]}" -gt "${KEEP}" ] || return 0
    newest=$(stat -c %s "${dir}/${have[0]}")
    largest=$(for f in "${have[@]}"; do stat -c %s "${dir}/$f"; done | sort -n | tail -1)
    if [ $((newest * 4)) -lt "$largest" ]; then
        warn "$1: newest snapshot ${have[0]} is ${newest} bytes, under a quarter of the largest kept (${largest}); pruning held. Was the T3 state restored after a rebuild?"
        return 1
    fi
    for f in "${have[@]:${KEEP}}"; do
        log "prune: $1/$f"
        rm -f "${dir:?}/$f"
    done
}

users=$(printf '%s\n' "${!pick[@]}" | cut -d/ -f1 | sort -u)
for u in $users; do
    [ -n "$u" ] || continue
    ok=1
    for stem in $(printf '%s\n' "${!pick[@]}" | awk -F/ -v u="$u" '$1 == u {print $2}' | sort -r | head -n "${KEEP}"); do
        [ -s "${DEST_ROOT}/${u}/${stem}.sqlite.gz" ] && continue
        fetch "$u" "${pick[$u/$stem]}" "$stem" || ok=0
    done
    rm -rf "${DEST_ROOT:?}/${u}/.incoming"
    if [ "$ok" = 1 ]; then
        prune "$u" || STATUS=1
    else
        warn "$u: a fetch failed, nothing pruned"
        STATUS=1
    fi
done

push_metrics
log "=== t3-state-pull done (status=${STATUS}, ${BYTES} bytes, $(($(date +%s) - STARTED))s) ==="
exit "${STATUS}"
