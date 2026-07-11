#!/usr/bin/env bash
# t3-cgroup-snap.sh — DIAGNOSTIC snapshotter for t3-serve cgroups.
#
# Samples every process in every t3-serve@<user> cgroup at 5s cadence; appends
# one JSONL line per (snapshot,pid) to a rotated local log so that after the
# next cgroup OOM we can identify the killed PID's real argv (the kernel log
# records the prctl-renamed Comm but not the args).
#
# TEMPORARY: removed same-PR as the eventual targeted mitigation.
# Design + rationale: docs/plans/2026-07-09-t3-cgroup-snap-design.md.
# Runbook (analysis recipes + retire checklist): docs/runbooks/t3-cgroup-snap.md.
set -uo pipefail

SNAP_INTERVAL="${T3_SNAP_INTERVAL:-5}"                    # seconds between snapshots
SNAP_LOG="${T3_SNAP_LOG:-/var/log/t3-cgroup-snap.jsonl}"
SNAP_MAX_BYTES="${T3_SNAP_MAX_BYTES:-52428800}"           # 50 MiB per rotation slot -> 150 MiB total
SNAP_ARGV_MAX="${T3_SNAP_ARGV_MAX:-512}"                  # per-proc argv cap
SNAP_CGROUP_GLOB="${T3_SNAP_CGROUP_GLOB:-/sys/fs/cgroup/system.slice/system-t3\x2dserve.slice/t3-serve@*.service}"

# read_pid_status <procroot> <pid> -> single JSON object on stdout, empty on missing.
# Emits just the pid/uid/rss_kb/comm fields; full-line assembly happens in emit_line.
read_pid_status() {
  local proc="$1" pid="$2" s="$1/$2/status" c="$1/$2/comm"
  [ -r "$s" ] && [ -r "$c" ] || return 0
  local rss uid comm
  read -r rss uid < <(awk '
    /^VmRSS:/ { rss = $2 }
    /^Uid:/   { uid = $2 }
    END { print (rss?rss:0), (uid?uid:0) }
  ' "$s" 2>/dev/null)
  comm="$(tr -d '\n' <"$c" 2>/dev/null)"
  jq -cn --argjson pid "$pid" --argjson uid "${uid:-0}" --argjson rss "${rss:-0}" --arg comm "$comm" \
    '{pid:$pid,uid:$uid,rss_kb:$rss,comm:$comm}'
}

# emit_line <procroot> <user> <pid> [ts_override] -> ONE JSONL line, empty if pid gone.
emit_line() {
  local proc="$1" user="$2" pid="$3" ts_override="${4:-}"
  local ts rss uid ppid comm argv exe
  [ -r "$proc/$pid/status" ] && [ -r "$proc/$pid/comm" ] || return 0
  if [ -n "$ts_override" ]; then ts="$ts_override"; else ts="$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')"; fi
  read -r rss uid ppid < <(awk '
    /^VmRSS:/ { rss = $2 }
    /^Uid:/   { uid = $2 }
    /^PPid:/  { ppid = $2 }
    END { print (rss?rss:0), (uid?uid:0), (ppid?ppid:0) }
  ' "$proc/$pid/status" 2>/dev/null)
  comm="$(tr -d '\n' <"$proc/$pid/comm" 2>/dev/null)"
  argv="$(head -c "$SNAP_ARGV_MAX" "$proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | sed 's/ *$//')"
  exe="$(readlink "$proc/$pid/exe" 2>/dev/null || echo '')"
  jq -cn \
    --arg ts "$ts" --arg user "$user" \
    --argjson pid "$pid" --argjson ppid "${ppid:-0}" --argjson uid "${uid:-0}" --argjson rss "${rss:-0}" \
    --arg comm "$comm" --arg exe "$exe" --arg argv "$argv" \
    '{ts:$ts,user:$user,pid:$pid,ppid:$ppid,uid:$uid,rss_kb:$rss,comm:$comm,exe:$exe,argv:$argv}'
}

# rotate_if_needed <path> <max_bytes>: current -> .1, .1 -> .2, .2 -> .3, drop .3.
rotate_if_needed() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  [ "$sz" -ge "$max" ] || return 0
  rm -f "$f.3" 2>/dev/null
  [ -f "$f.2" ] && mv -f "$f.2" "$f.3" 2>/dev/null
  [ -f "$f.1" ] && mv -f "$f.1" "$f.2" 2>/dev/null
  mv -f "$f" "$f.1" 2>/dev/null
  : >"$f"
}

# users_with_cgroup: one <user>\t<cgroup.procs-path> per t3-serve@ cgroup that exists.
users_with_cgroup() {
  local d u
  # shellcheck disable=SC2086 # $SNAP_CGROUP_GLOB is a glob pattern, MUST be word-split.
  for d in $SNAP_CGROUP_GLOB; do
    [ -r "$d/cgroup.procs" ] || continue
    u="${d##*t3-serve@}"; u="${u%.service}"
    printf '%s\t%s\n' "$u" "$d/cgroup.procs"
  done
}

snapshot_once() {
  local u pf pid
  while IFS=$'\t' read -r u pf; do
    while IFS= read -r pid; do
      emit_line /proc "$u" "$pid" || true
    done <"$pf"
  done < <(users_with_cgroup)
}

main() {
  install -m 0640 -o root -g adm /dev/null "$SNAP_LOG" 2>/dev/null || : >"$SNAP_LOG"
  while true; do
    snapshot_once >>"$SNAP_LOG"
    rotate_if_needed "$SNAP_LOG" "$SNAP_MAX_BYTES"
    sleep "$SNAP_INTERVAL"
  done
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
