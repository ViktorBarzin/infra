#!/usr/bin/env bash
# Keep recently used tmux panes out of swap (devvm, 2026-09-12).
#
# WHY. emo reported sessions becoming unusable under load. The mechanism is not
# CPU: a detached session's pages are the natural reclaim victim, so by the time
# somebody re-attaches, the working set has to fault back in from a 7200rpm
# spindle. Measured 2026-09-12, that cost 190 ms per read.
#
# WHAT COUNTS AS RECENT, and why not just "attached". Of 47 sessions across both
# users, exactly one was attached when this was measured. Keying protection on
# live attachment would protect almost nothing, and would miss the moment that
# actually hurts, which is re-attaching to a session left alone for a day.
# tmux 3.4 exposes session_last_attached, so the window is what we key on.
#
# HOW. tmux puts every pane in its own transient scope,
# user-<uid>.slice/user@<uid>.service/app.slice/tmux-spawn-<uuid>.scope. Setting
# memory.swap.max=0 on a hot pane's scope stops the kernel paging it out. Cold
# panes are returned to the slice default so they stay swappable, which is what
# keeps the protected set small.
#
# This does NOT pin pages in RAM. The kernel can still reclaim file-backed pages
# from a protected pane, and MemoryMax on the scope still bounds a runaway. It
# only removes the anonymous-page swapout path for panes somebody is using.
#
# BUDGET, and why it is not optional. Measured 2026-09-12 before this ever ran:
# a 24 hour window matched 36 of 60 panes holding 21.3 GB on a 31 GB box, and
# even a 1 hour window matched 16 panes holding 14.7 GB. Against that, all 60
# panes together hold 15.5 GB of anonymous memory and the two active users share
# 8 GiB of swap. An unbounded protected set would close the swapout path for
# most of the swappable memory on the box, and reclaim would answer by evicting
# file pages, which is the refault mechanism this change exists to reduce.
#
# So the set is capped. Panes are protected most-recently-used first until their
# anonymous memory reaches the budget; everything past it stays swappable. The
# worst case is then a number we chose rather than one the workload happens to
# produce on a given day.
#
# Idempotent, and safe to run while sessions come and go: a scope that vanishes
# between listing and writing is skipped rather than failing the run.
#
# A systemd daemon-reload CLEARS what this writes. These are cgroup writes made
# behind systemd's back, and a reload re-applies systemd's own view of each
# unit's properties, so every pane returns to the slice default. Observed
# 2026-09-12: protection went from 22 panes to 0 across a reload and back to 22
# on the next tick. The timer is the reconciliation, so the exposure is at most
# one interval. Read a zero right after a reload as expected, not as a failure.
set -uo pipefail

WINDOW_HOURS="${DEVVM_PANE_HOT_HOURS:-24}"
# 6 GiB of the 15.5 GiB of pane anonymous memory, leaving the rest to compete
# for the 8 GiB the two active users share. Raise it only with a measurement.
BUDGET_BYTES="${DEVVM_PANE_SWAP_BUDGET_BYTES:-$(( 6 * 1024 * 1024 * 1024 ))}"
# DEVVM_PANE_GUARD_DRY_RUN=1 classifies and reports without writing anything.
# This script runs as root and writes cgroup files on live sessions, so being
# able to see what it would do before it does it is worth the three lines.
DRY_RUN="${DEVVM_PANE_GUARD_DRY_RUN:-0}"
CG=/sys/fs/cgroup/user.slice
now=$(date +%s)
cutoff=$(( now - WINDOW_HOURS * 3600 ))
hot_count=0
cold_count=0

log() { echo "$*"; }

# Humans only. UID >= 1000 and < 65534, with a real shell and a home.
mapfile -t users < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /nologin|false/ {print $1":"$3}' /etc/passwd)

declare -A hot_scope=()
candidates=()
spent=0

for entry in "${users[@]}"; do
  user="${entry%%:*}"
  uid="${entry##*:}"
  [[ -d "$CG/user-$uid.slice" ]] || continue

  # Sessions this user has touched inside the window, or is attached to now.
  # A never-attached session reports an empty last_attached; treat it as cold.
  while IFS='|' read -r attached last_attached pane_pid; do
    [[ -n "${pane_pid:-}" ]] || continue
    if [[ "${attached:-0}" -gt 0 ]] || { [[ -n "${last_attached:-}" ]] && [[ "$last_attached" -ge "$cutoff" ]]; }; then
      scope=$(awk -F: '{print $3}' "/proc/$pane_pid/cgroup" 2>/dev/null | head -1)
      if [[ "$scope" == *"tmux-spawn-"*".scope" ]]; then
        rank="${last_attached:-0}"                      # attached sorts ahead of detached
        [[ "${attached:-0}" -gt 0 ]] && rank=$(( now + 1 ))
        candidates+=("${rank}|$CG${scope#/user.slice}")
      fi
    fi
  done < <(runuser -u "$user" -- tmux list-panes -a \
             -F '#{session_attached}|#{session_last_attached}|#{pane_pid}' 2>/dev/null)
done

# Spend the budget most-recently-used first, counting anonymous memory because
# that is the only thing swap holds. File pages stay reclaimable either way.
if ((${#candidates[@]})); then
  while IFS='|' read -r _rank scope_dir; do
    [[ -n "${scope_dir:-}" && -d "$scope_dir" ]] || continue
    [[ -n "${hot_scope[$scope_dir]:-}" ]] && continue
    anon=$(awk '/^anon /{print $2; exit}' "$scope_dir/memory.stat" 2>/dev/null)
    anon=${anon:-0}
    (( spent + anon > BUDGET_BYTES )) && continue
    hot_scope["$scope_dir"]=1
    spent=$(( spent + anon ))
  done < <(printf '%s\n' "${candidates[@]}" | sort -t'|' -k1,1nr)
fi

# Reconcile every pane scope on the box against that set.
while IFS= read -r -d '' scope_dir; do
  f="$scope_dir/memory.swap.max"
  [[ -w "$f" ]] || continue
  want="max"
  [[ -n "${hot_scope[$scope_dir]:-}" ]] && want="0"
  current=$(cat "$f" 2>/dev/null) || continue
  [[ "$current" == "$want" ]] && { [[ "$want" == "0" ]] && hot_count=$((hot_count+1)) || cold_count=$((cold_count+1)); continue; }
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  would set $(basename "$scope_dir") memory.swap.max: $current -> $want"
    if [[ "$want" == "0" ]]; then hot_count=$((hot_count+1)); else cold_count=$((cold_count+1)); fi
    continue
  fi
  if echo "$want" > "$f" 2>/dev/null; then
    if [[ "$want" == "0" ]]; then hot_count=$((hot_count+1)); else cold_count=$((cold_count+1)); fi
  fi
done < <(find "$CG" -maxdepth 4 -type d -name 'tmux-spawn-*.scope' -print0 2>/dev/null)

log "pane swap guard: ${hot_count} protected, $(( spent / 1048576 )) MiB anon of $(( BUDGET_BYTES / 1048576 )) MiB budget, window ${WINDOW_HOURS}h; ${cold_count} swappable"
