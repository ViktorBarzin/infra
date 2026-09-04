#!/bin/sh
# Sync the PVE host backup scripts and their systemd units from this repo.
#
# Covers all six: lvm-pvc-snapshot, daily-backup, offsite-sync-backup,
# devvm-home-backup, vzdump-vms and nfs-mirror. The first three were here from
# the start; devvm-home-backup and vzdump-vms joined on 2026-09-03, the former
# because nothing deployed it at all and the latter to close a drift window.
# nfs-mirror joined 2026-09-04, the last one still deployed by hand.
#
# Run by .woodpecker/pve-scripts-sync.yml. Lives in a file rather than inline in
# the pipeline because Woodpecker traces each `commands:` entry through
# /bin/sh -c, and a multi-line loop containing quotes failed to parse there
# ("syntax error: unterminated quoted string", pipeline #1466, 2026-09-03).
# A script is also something you can run `sh -n` over before landing it.
#
# Idempotent: copies the same bytes every run. It diffs first so the pipeline
# log shows the intended change even when nothing moves.
#
# Requires: openssh-client, a key at ~/.ssh/id_ed25519 authorised for
# root@$PVE_HOST, and $PVE_HOST in ~/.ssh/known_hosts. Run from the repo root.

set -eu

PVE_HOST="${PVE_HOST:-192.168.1.127}"
NAMES="${NAMES:-lvm-pvc-snapshot daily-backup offsite-sync-backup devvm-home-backup vzdump-vms nfs-mirror}"
SSH="ssh -o BatchMode=yes root@$PVE_HOST"

echo "---diff---"
for n in $NAMES; do
    $SSH "cat /usr/local/bin/$n" > "/tmp/remote.$n" 2>/dev/null || true
    if diff -u "/tmp/remote.$n" "scripts/$n.sh" > /dev/null 2>&1; then
        echo "$n.sh: unchanged"
    else
        diff -u "/tmp/remote.$n" "scripts/$n.sh" || true
    fi
    for u in service timer; do
        $SSH "cat /etc/systemd/system/$n.$u" > "/tmp/remote.$n.$u" 2>/dev/null || true
        if diff -u "/tmp/remote.$n.$u" "scripts/$n.$u" > /dev/null 2>&1; then
            echo "$n.$u: unchanged"
        else
            diff -u "/tmp/remote.$n.$u" "scripts/$n.$u" || true
        fi
    done
done

echo "---applying---"
for n in $NAMES; do
    scp -o BatchMode=yes "scripts/$n.sh" "root@$PVE_HOST:/usr/local/bin/$n"
    $SSH "chmod 755 /usr/local/bin/$n && bash -n /usr/local/bin/$n"
    scp -o BatchMode=yes "scripts/$n.service" "scripts/$n.timer" \
        "root@$PVE_HOST:/etc/systemd/system/"
    echo "$n: deployed"
done

echo "---reloading---"
$SSH "systemctl daemon-reload"
# Naming every timer explicitly: list-timers with no argument would hide a unit
# that failed to load, which is the failure this sync exists to surface.
for n in $NAMES; do
    $SSH "systemctl list-timers --no-pager --all $n.timer"
done

echo "---done---"
