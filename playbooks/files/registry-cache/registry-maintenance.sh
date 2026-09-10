#!/usr/bin/env bash
#
# Daily maintenance for the registry cache VM, in the ONE order that is safe.
# Declared by playbooks/registry-cache.yml; do not edit on the box.
#
# WHY A WRAPPER RATHER THAN FIVE CRON LINES
# -----------------------------------------
# The old schedule ran these as separate root-crontab entries spaced by clock
# time, which only holds the ordering if every step finishes inside its slot.
# Nobody has measured how long garbage-collect takes on a 34 GB store, and the
# VM has been at 100% disk, so the slots were an assumption. Running them in one
# process makes the order a property of the script instead.
#
# THE ORDER IS THE POINT
# ----------------------
#   1. cleanup-tags.sh      deletes old TAG LINKS from the filesystem
#   2. garbage-collect      reclaims the blobs those links referenced
#   3. fix-broken-blobs.sh  finds layer links whose blob step 2 removed
#   4. docker restart       clears the in-memory blob-descriptor cache
#
# Before this, cleanup-tags.sh ran daily at 02:00 and garbage-collect ran only on
# Sunday, so Monday to Saturday the references went and the blobs stayed. That is
# the whole reason the disk filled: the daily job removed the only thing pointing
# at the bytes without ever removing the bytes.
#
# Steps 3 and 4 must stay strictly AFTER step 2, and must run even if step 2
# fails. The existing crontab's own comment records why: without the restart
# "the registry serves 200 with 0 bytes for blobs that were GC-ed (stale inmemory
# cache)", and containerd reports that as "unexpected EOF". So this script does
# NOT use `set -e` — a failure in one step is logged and the sequence continues,
# because skipping the repair and the restart is worse than the original failure.
#
# RESIDUAL RISK, stated rather than hidden
# ----------------------------------------
# Registry garbage-collect is documented upstream as unsafe to run concurrently
# with pushes. These are pull-through caches, so no client pushes — but the proxy
# itself writes blobs as it fetches them from upstream, which is the same race. A
# pull landing mid-GC can lose a blob. 02:00 local is the quietest window, and
# steps 3 and 4 are the existing mitigation. The stronger option, not taken here,
# is flipping `maintenance.readonly.enabled: true` in each config, restarting,
# GC-ing, flipping back and restarting again: it removes the race and costs two
# extra restarts plus a read-only window on every cluster image pull.
#
# `--delete-untagged` is deliberately NOT passed. On a pull-through cache many
# manifests are referenced only by digest, and that flag would remove them.
#
# registry-private is absent from every step. It was decommissioned 2026-05-07,
# and two of the old crontab lines still named it, so `docker exec
# registry-private ...` and `docker restart ... registry-private` failed every
# Sunday.

set -uo pipefail

LOG=/var/log/registry-maintenance.log
LOCK=/var/lock/registry-maintenance.lock
KEEP_TAGS=10
GC_CONTAINERS=(registry-dockerhub registry-ghcr)
RESTART_CONTAINERS=(registry-dockerhub registry-ghcr)

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# One run at a time. A GC that overruns 24h must not meet the next day's run.
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
    log "another registry-maintenance run holds $LOCK; exiting" >>"$LOG"
    exit 0
fi

exec >>"$LOG" 2>&1

rc=0
step() {
    local label=$1
    shift
    log "START $label"
    if "$@"; then
        log "OK    $label"
    else
        local s=$?
        log "FAIL  $label (exit $s) — continuing, see the ordering note in this script"
        rc=1
    fi
}

log "=== registry maintenance begins ==="
df -h / | tail -1

step "cleanup-tags (keep $KEEP_TAGS per repo)" \
    python3 /opt/registry/cleanup-tags.sh "$KEEP_TAGS"

for c in "${GC_CONTAINERS[@]}"; do
    step "garbage-collect $c" \
        /usr/bin/docker exec "$c" registry garbage-collect -m /etc/docker/registry/config.yml
done

step "fix-broken-blobs" \
    python3 /opt/registry/fix-broken-blobs.sh

step "restart ${RESTART_CONTAINERS[*]}" \
    /usr/bin/docker restart "${RESTART_CONTAINERS[@]}"

df -h / | tail -1
log "=== registry maintenance done (rc=$rc) ==="
exit "$rc"
