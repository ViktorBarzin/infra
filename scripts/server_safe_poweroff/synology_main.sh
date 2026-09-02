#!/usr/bin/env bash

# This is used to run the main program on synology nas and log all messages to synology's log system

cd /var/services/homes/Administrator/server-power-cycle
# Load iDRAC creds / SNMP community from an out-of-band env file (chmod 600,
# NOT in git) so root/calvin + the SNMP community aren't baked into the binary.
# Also honours POWERON_MIN_CHARGE_PCT / MAINS_STABLE_DWELL_MINUTES overrides.
[ -f ./powercheck.env ] && set -a && . ./powercheck.env && set +a
echo "Starting powercheck"
./powercheck-armv8 -log_dir=./logs

echo "script completed successfully, logging to synlogy's logs"


while IFS= read -r line; do
# for line in $(cat ./logs/powercheck-armv8.INFO); do
    msg=$(echo $line | grep -E '^[IWEF][0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}'| awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
    #echo $line
    echo $msg
    if [[ -n $msg ]]; then
        synologset1 sys info 0x11800000 "$msg"
    fi
done < "./logs/powercheck-armv8.INFO"

# Cleanup logs
find ./logs -type f -mtime +7 -exec rm {} \;

# Cleanup DSM Task Scheduler run output
#
# The DSM task that runs this script has "save output results" pointed at a
# folder on the Backup share. Task Scheduler writes one directory per
# execution there (output.log + script.log, a few hundred bytes each) and
# never rotates them. At the 5-minute cadence that is ~288 directories a day:
# measured 2026-08-24, task 1 held 90,008 run directories going back to
# 2023-12-15, and a retired task 6 still held 46,061 from before Jan 2022 —
# roughly 272,000 tiny files in total.
#
# The space is negligible; the cost is inode count. It slows anything that
# walks the share: `du` over /volume1/Backup no longer finishes on this DS218,
# and the weekly Storage Analyzer run reported 3,819 seconds of work.
#
# Same 7-day spirit as the ./logs cleanup above, with a longer window since
# these are the only record of a past run. Work is capped per invocation so a
# large first pass cannot overrun the 5-minute schedule — at 500 per run the
# existing backlog drains in about a day, then it stays flat. Pruning by mtime
# also retires the leftovers of tasks that no longer exist.
SCHEDULER_OUTPUT="${SCHEDULER_OUTPUT:-/volume1/Backup/synoscheduler}"
SCHEDULER_RETAIN_DAYS="${SCHEDULER_RETAIN_DAYS:-30}"
SCHEDULER_PRUNE_MAX="${SCHEDULER_PRUNE_MAX:-500}"
if [ -d "$SCHEDULER_OUTPUT" ]; then
    find "$SCHEDULER_OUTPUT" -mindepth 2 -maxdepth 2 -type d \
        -mtime +"$SCHEDULER_RETAIN_DAYS" 2>/dev/null \
        | head -n "$SCHEDULER_PRUNE_MAX" \
        | while IFS= read -r run_dir; do
            rm -rf "$run_dir"
        done
fi
