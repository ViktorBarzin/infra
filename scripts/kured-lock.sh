#!/usr/bin/env bash
# kured-lock — take and release kured's own node lock from outside kured.
#
# One lock keeps the cluster's disruptive work from overlapping: kured's
# reboots, the weekly k8s-version-upgrade chain's node drains, and the
# Proxmox host's nightly backup chain (scripts/nightly-chain.sh). It is the
# annotation kured already uses, `weave.works/kured-node-lock` on the
# kured/kured DaemonSet (kured 1.23.0, pkg/daemonsetlock/daemonsetlock.go):
#
#   {"nodeID":"<holder>","metadata":{"unschedulable":false},
#    "created":"<RFC3339 UTC>","TTL":<nanoseconds, 0 = never expires>}
#
# kured runs with --concurrency=1, so this single-lock format is the one it
# reads. While anyone else holds a live lock, kured skips its reboot and tries
# again next period. kured writes TTL 0; the writers here always set a TTL, so
# a holder that dies leaves a lock that expires on its own.
#
# Every write carries the resourceVersion that was read, so of two writers
# racing for a free lock only one wins (the API server answers the other with
# a conflict), the same compare-and-swap kured's own Update relies on.
#
# Sourced by stacks/k8s-version-upgrade/scripts/upgrade-step.sh (mounted from
# the scripts ConfigMap at /scripts/kured-lock.sh) and by nightly-chain on the
# Proxmox host (/usr/local/bin/kured-lock). Tests: scripts/kured-lock.test.sh.

KUBECTL=${KUBECTL:-kubectl}
KURED_LOCK_NS=${KURED_LOCK_NS:-kured}
KURED_LOCK_DS=${KURED_LOCK_DS:-kured}
KURED_LOCK_ANNOTATION=${KURED_LOCK_ANNOTATION:-weave.works/kured-node-lock}
KURED_LOCK_POLL=${KURED_LOCK_POLL:-30}

# _kured_lock_read -> "<resourceVersion>\t<live holder or empty>"
_kured_lock_read() {
  $KUBECTL get ds "$KURED_LOCK_DS" -n "$KURED_LOCK_NS" -o json | jq -r --arg a "$KURED_LOCK_ANNOTATION" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (.metadata.annotations[$a] // "") as $v
    | (if $v == "" then "" else ($v | fromjson
        | if (.TTL // 0) > 0 and ((.created | epoch) + ((.TTL // 0) / 1e9)) <= now
          then "" else .nodeID end) end) as $holder
    | "\(.metadata.resourceVersion)\t\($holder)"'
}

# kured_lock_holder -> prints the live holder, empty when free
kured_lock_holder() {
  local line
  line=$(_kured_lock_read) || return 2
  printf '%s\n' "${line#*$'\t'}"
}

# kured_lock_try_at_rv <holder> <ttl-seconds> <resourceVersion>
# Writes the lock at exactly that resourceVersion. 0 written, 2 conflict.
kured_lock_try_at_rv() {
  local holder=$1 ttl=$2 rv=$3 value
  value=$(jq -cn --arg id "$holder" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ttl "$((ttl * 1000000000))" \
    '{nodeID: $id, metadata: {unschedulable: false}, created: $created, TTL: $ttl}')
  $KUBECTL annotate ds/"$KURED_LOCK_DS" -n "$KURED_LOCK_NS" --overwrite \
    --resource-version="$rv" "$KURED_LOCK_ANNOTATION=$value" >/dev/null 2>&1 || return 2
}

# kured_lock_try <holder> <ttl-seconds>
# 0 taken (or already ours: the TTL is refreshed), 1 held by someone else
# (prints who), 2 the write lost a race or the API failed.
kured_lock_try() {
  local holder=$1 ttl=$2 line rv cur
  line=$(_kured_lock_read) || return 2
  rv=${line%%$'\t'*}
  cur=${line#*$'\t'}
  if [ -n "$cur" ] && [ "$cur" != "$holder" ]; then
    printf 'kured-lock: held by %s\n' "$cur"
    return 1
  fi
  kured_lock_try_at_rv "$holder" "$ttl" "$rv"
}

# kured_lock_acquire <holder> <ttl-seconds> <wait-seconds>
# Retries every KURED_LOCK_POLL seconds. 0 taken, 75 still held at the deadline.
kured_lock_acquire() {
  local holder=$1 ttl=$2 wait=$3 deadline out rc
  deadline=$(($(date +%s) + wait))
  while :; do
    # `|| rc=$?`, not `; rc=$?`: callers run under set -e (upgrade-step.sh).
    rc=0
    out=$(kured_lock_try "$holder" "$ttl") || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '%s\n' "${out:-kured-lock: could not write the lock}"
      return 75
    fi
    sleep "$KURED_LOCK_POLL"
  done
}

# kured_lock_release <holder>
# Removes the lock only while <holder> holds it. A free or foreign lock is
# left alone and counts as success.
kured_lock_release() {
  local holder=$1 line rv cur _
  for _ in 1 2 3 4 5; do
    line=$(_kured_lock_read) || return 2
    rv=${line%%$'\t'*}
    cur=${line#*$'\t'}
    [ "$cur" = "$holder" ] || return 0
    $KUBECTL annotate ds/"$KURED_LOCK_DS" -n "$KURED_LOCK_NS" \
      --resource-version="$rv" "$KURED_LOCK_ANNOTATION-" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 2
}

# CLI: kured-lock acquire|release|holder ...
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  cmd=${1:-}
  shift || true
  case "$cmd" in
    acquire) kured_lock_acquire "$@" ;;
    release) kured_lock_release "$@" ;;
    holder) kured_lock_holder ;;
    *) echo "usage: kured-lock acquire <holder> <ttl-s> <wait-s> | release <holder> | holder" >&2; exit 64 ;;
  esac
fi
