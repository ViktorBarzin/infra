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

# Timers that are deployed but must stay off. Their script and units keep
# arriving with everyone else's, so re-enabling one is a single systemctl
# away, but this loop makes sure nothing quietly turns them back on.
#
# vzdump-vms, retired 2026-09-15. It read all 228 GiB of devvm's disk every
# Sunday at 01:00 and was the largest single IO cliff on the host: measured
# live on 2026-09-13, sdc read latency went from 0.23 ms to 107.26 ms and
# etcd write latency from 1.36 ms to 22.07 ms for the duration. Its own
# --ionice 7 does nothing, because sdc runs mq-deadline, which ignores
# ionice classes. The restore path it covered is now the devvm playbook plus
# devvm-home-backup, validated end to end on 2026-08-29, and the last three
# full images stay on /mnt/backup as a floor that no longer advances.
# Reasoning in docs/plans/2026-09-12-io-bottleneck-ssd-vs-spindles.md.
#
# Disabled rather than masked on purpose: these unit files live in
# /etc/systemd/system, and a mask puts its symlink at that same path, so it
# never takes and every run reports a change that no apply can settle.
DISABLED_TIMERS="${DISABLED_TIMERS:-vzdump-vms}"
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

echo "---disabling---"
for n in $DISABLED_TIMERS; do
    $SSH "systemctl disable --now $n.timer" || true
    echo "$n.timer: $($SSH "systemctl is-enabled $n.timer" 2>&1 || true) / $($SSH "systemctl is-active $n.timer" 2>&1 || true)"
done

echo "---reloading---"
$SSH "systemctl daemon-reload"
# Naming every timer explicitly: list-timers with no argument would hide a unit
# that failed to load, which is the failure this sync exists to surface.
for n in $NAMES; do
    case " $DISABLED_TIMERS " in *" $n "*) continue ;; esac
    $SSH "systemctl list-timers --no-pager --all $n.timer"
done

echo "---done---"
