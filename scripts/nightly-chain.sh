#!/usr/bin/env bash
# nightly-chain — run the night's backups in dependency order, one after the
# other, instead of at hand-staggered times.
#
# Deploy to PVE host at /usr/local/bin/nightly-chain (scripts/ci/pve-scripts-sync.sh).
# Schedule: daily 00:00 UTC via nightly-chain.timer. The six host backup
# timers are disabled; this is the only thing that starts them.
#
# Order, and why:
#   0. Take kured's node lock (scripts/kured-lock.sh) as "pve-nightly-chain",
#      waiting up to 2 h. While the chain holds it, kured does not reboot a
#      node and the weekly k8s-version-upgrade chain does not drain one, so no
#      drain overlaps the night's disk-heavy work (2026-11-02: drains during
#      nfs-mirror saturated the host's IO and leaked Proxmox CSI slots). If the
#      lock is still busy after the wait, the night runs anyway and reports it:
#      backups matter more than the overlap.
#   1. DB and app dumps: every CronJob annotated
#      backup.viktorbarzin.me/nightly-chain=daily (and =sunday on Sundays),
#      started with `kubectl create job --from=cronjob/...`, at most
#      DUMP_PARALLEL at a time. The CronJobs themselves are suspended; a Job
#      created from a CronJob still updates its lastSuccessfulTime
#      (kubernetes pkg/controller/cronjob/cronjob_controllerv2.go, checked for
#      v1.35), so the *BackupStale alerts keep working. Most dumps land on
#      /srv/nfs, so they must finish before step 2 copies it.
#      A dump whose Job cannot be created is tried again every
#      NIGHTLY_CHAIN_RETRY_DELAY seconds, NIGHTLY_CHAIN_START_TRIES times in
#      all, while the other dumps go on (2026-11-12: the host lost its route
#      to the API from 00:01:56 to about 00:06 and eight dumps were skipped
#      for the night). A create that errors after the Job was written is
#      noticed by the retry, which finds the Job and follows it.
#   2. nfs-mirror          /srv/nfs -> /mnt/backup, including tonight's dumps
#   3. lvm-pvc-snapshot    thin snapshots of the Proxmox CSI PVCs
#   4. daily-backup        copies from the snapshots in step 3 to sda
#   5. t3-state-pull       the devvm's nightly T3 snapshots to sda (2026-11-11)
#   6. offsite-sync-backup sda + immich to the Synology, after 2-5 wrote sda
#   devvm-home-backup was step 5 until 2026-11-12: the devvm is disposable now
#   (docs/plans/2026-11-11-disposable-devvm.md) and the second rebuild drill
#   passed with nothing lost, so a file copy of /home is no longer kept. Its
#   script and units still ship, disabled, and its last copies stay on sda.
#   Each host step is its own systemd unit with its own IO class, timeout and
#   metrics; this script only starts it and waits. A failed step is reported
#   and the chain carries on, because the later steps do not lose anything by
#   running on yesterday's copy of an earlier one.
#   7. Release the lock.
#
# If the cluster API does not answer, the dumps cannot run, but the host
# steps still do: they are the recovery copies for exactly that situation.
#
# Testing: `nightly-chain --only backup-etcd,t3-state-pull` runs just
# those (no lock, no full-night success metric). Tests: scripts/nightly-chain.test.sh.
set -uo pipefail

HOLDER=pve-nightly-chain
LOCK_TTL=${NIGHTLY_CHAIN_LOCK_TTL:-28800}      # 8 h, longer than a slow night
LOCK_WAIT=${NIGHTLY_CHAIN_LOCK_WAIT:-7200}     # 2 h
DUMP_PARALLEL=${NIGHTLY_CHAIN_DUMP_PARALLEL:-3}
DUMP_TIMEOUT=${NIGHTLY_CHAIN_DUMP_TIMEOUT:-7200}
POLL=${NIGHTLY_CHAIN_POLL:-30}
START_TRIES=${NIGHTLY_CHAIN_START_TRIES:-5}
RETRY_DELAY=${NIGHTLY_CHAIN_RETRY_DELAY:-180}   # 5 tries cover ~12 min of no API
ANNOTATION=backup.viktorbarzin.me/nightly-chain
HOST_STEPS="nfs-mirror lvm-pvc-snapshot daily-backup t3-state-pull offsite-sync-backup"
PUSHGATEWAY="${NIGHTLY_CHAIN_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB=nightly-chain
LOCK_LIB=${NIGHTLY_CHAIN_LOCK_LIB:-/usr/local/bin/kured-lock}
KUBECTL=${KUBECTL:-kubectl}
# systemd gives the service no HOME, so kubectl would find no config.
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

# shellcheck source=kured-lock.sh
[ -r "$LOCK_LIB" ] && . "$LOCK_LIB"

log() { echo "$(date -u +%H:%M:%S) $*"; }

METRICS=""
metric() { METRICS+="$*"$'\n'; }
push() {
  printf '%s' "$METRICS" | curl -s --connect-timeout 5 --max-time 10 --data-binary @- \
    "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" >/dev/null 2>&1 || true
  METRICS=""
}

# wanted <name> -> true when --only is unset or names it
ONLY=""
wanted() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

# dump_list -> "<ns> <cronjob>" lines for tonight
dump_list() {
  local dow=${NIGHTLY_CHAIN_DOW:-$(date -u +%u)}
  $KUBECTL get cronjobs -A -o json | jq -r --arg a "$ANNOTATION" --arg sun "$([ "$dow" = 7 ] && echo 1)" '
    .items[]
    | (.metadata.annotations[$a] // "") as $when
    | select($when == "daily" or ($when == "sunday" and $sun == "1"))
    | "\(.metadata.namespace) \(.metadata.name)"'
}

# job_state <ns> <job> -> complete | failed | running
# job_state <ns> <job> <cronjob> <started-epoch> -> complete | failed | running
# Many backup CronJobs set ttlSecondsAfterFinished: 10, so a finished Job is
# often deleted before the next poll sees it (2026-11-11: mysql, drone-logbook
# and mailserver succeeded, and the first live run waited on them for an hour
# because a missing Job read as running). A Job that is gone counts as
# complete when its CronJob's lastSuccessfulTime is at or after the dump
# started, which a Job created from the CronJob updates, and as failed
# otherwise.
job_state() {
  local ns=$1 job=$2 cj=$3 started=$4 json last
  if json=$($KUBECTL get job -n "$ns" "$job" -o json 2>/dev/null); then
    jq -r '
      [.status.conditions[]? | select(.status == "True") | .type] as $c
      | if ($c | index("Complete")) then "complete"
        elif ($c | index("Failed")) then "failed"
        else "running" end' <<<"$json" 2>/dev/null || echo running
    return 0
  fi
  last=$($KUBECTL get cronjob -n "$ns" "$cj" -o json 2>/dev/null |
    jq -r '.status.lastSuccessfulTime // "" | if . == "" then 0 else fromdateiso8601 end' 2>/dev/null) || last=""
  if [ -z "$last" ]; then
    echo running   # API hiccup: look again next poll, the dump timeout still applies
  elif [ "$last" -ge "$started" ]; then
    echo complete
  else
    echo failed
  fi
}

# start_dump <ns> <cronjob> <job> -> 0 when the Job exists afterwards. A
# create can fail after the API wrote the Job (an etcd timeout), and a retry
# then gets AlreadyExists, so a failed create checks for the Job.
start_dump() {
  $KUBECTL create job -n "$1" "$3" --from=cronjob/"$2" >/dev/null && return 0
  $KUBECTL get job -n "$1" "$3" -o name >/dev/null 2>&1
}

# run_dumps -> 0 when every dump completed
run_dumps() {
  local queue=() next=() running=() started=() ns cj job state i rc=0 stamp now tries due entry
  stamp=$(date -u +%Y%m%d%H%M)
  while read -r ns cj; do
    [ -n "$ns" ] || continue
    wanted "$cj" || continue
    queue+=("$ns $cj 0 0")   # namespace, CronJob, failed starts, next try (epoch)
  done < <(dump_list)
  log "dumps: ${#queue[@]} tonight, ${DUMP_PARALLEL} at a time"
  while [ "${#queue[@]}" -gt 0 ] || [ "${#running[@]}" -gt 0 ]; do
    now=$(date +%s)
    next=()
    for entry in "${queue[@]}"; do
      read -r ns cj tries due <<<"$entry"
      if [ "${#running[@]}" -ge "$DUMP_PARALLEL" ] || [ "$due" -gt "$now" ]; then
        next+=("$entry")
        continue
      fi
      job="${cj}-chain-${stamp}"
      if start_dump "$ns" "$cj" "$job"; then
        log "dump started: $ns/$job"
        running+=("$ns $cj $job")
        started+=("$(date +%s)")
      elif [ $((tries + 1)) -lt "$START_TRIES" ]; then
        log "dump start failed, retrying in ${RETRY_DELAY}s ($((tries + 1))/${START_TRIES}): $ns/$cj"
        next+=("$ns $cj $((tries + 1)) $((now + RETRY_DELAY))")
      else
        log "dump FAILED to start after ${START_TRIES} tries: $ns/$cj"
        metric "nightly_chain_step_ok{step=\"$ns/$cj\"} 0"
        rc=1
      fi
    done
    queue=("${next[@]}")
    local still=() still_started=()
    for i in "${!running[@]}"; do
      read -r ns cj job <<<"${running[$i]}"
      state=$(job_state "$ns" "$job" "$cj" "${started[$i]}")
      if [ "$state" = running ] && [ $(($(date +%s) - ${started[$i]})) -ge "$DUMP_TIMEOUT" ]; then
        state=timeout
      fi
      case "$state" in
        running) still+=("${running[$i]}"); still_started+=("${started[$i]}") ;;
        complete) log "dump done: $ns/$job"; metric "nightly_chain_step_ok{step=\"$ns/$cj\"} 1" ;;
        *) log "dump $state: $ns/$job"; metric "nightly_chain_step_ok{step=\"$ns/$cj\"} 0"; rc=1 ;;
      esac
    done
    running=("${still[@]}")
    started=("${still_started[@]}")
    if [ "${#running[@]}" -gt 0 ] || [ "${#queue[@]}" -gt 0 ]; then
      sleep "$POLL"
    fi
  done
  return "$rc"
}

# run_host_steps -> 0 when every step succeeded
run_host_steps() {
  local u rc=0
  for u in $HOST_STEPS; do
    wanted "$u" || continue
    log "step start: $u"
    if systemctl start --wait "$u.service"; then
      log "step done: $u"
      metric "nightly_chain_step_ok{step=\"$u\"} 1"
    else
      log "step FAILED: $u"
      metric "nightly_chain_step_ok{step=\"$u\"} 0"
      rc=1
    fi
  done
  return "$rc"
}

main() {
  local start rc=0 locked=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --only) ONLY=$2; shift 2 ;;
      *) echo "usage: nightly-chain [--only name,name,...]" >&2; return 64 ;;
    esac
  done
  start=$(date +%s)
  metric "nightly_chain_running 1"
  metric "nightly_chain_last_start_timestamp $start"
  push

  if $KUBECTL get --raw /readyz >/dev/null 2>&1; then
    if [ -z "$ONLY" ]; then
      if kured_lock_acquire "$HOLDER" "$LOCK_TTL" "$LOCK_WAIT"; then
        locked=1
        log "kured lock taken as $HOLDER"
      else
        log "kured lock still busy after ${LOCK_WAIT}s; running without it"
      fi
      metric "nightly_chain_lock_acquired $locked"
    fi
    run_dumps || rc=1
  else
    log "cluster API not answering: skipping the dumps, running the host steps"
    metric "nightly_chain_api_up 0"
    rc=1
  fi

  run_host_steps || rc=1

  [ "$locked" = 1 ] && kured_lock_release "$HOLDER"
  metric "nightly_chain_running 0"
  metric "nightly_chain_duration_seconds $(($(date +%s) - start))"
  if [ -z "$ONLY" ]; then
    metric "nightly_chain_last_status $rc"
    [ "$rc" = 0 ] && metric "nightly_chain_last_success_timestamp $(date +%s)"
  fi
  push
  log "nightly chain finished rc=$rc in $(($(date +%s) - start))s"
  return "$rc"
}

if [ "${NIGHTLY_CHAIN_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
