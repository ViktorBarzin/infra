#!/usr/bin/env bash
# Give each active user a bounded share of the disk, and give a lone user all
# of it.
#
# THE PROPERTY THIS EXISTS FOR, in Viktor's words: "whenever nobody is using
# the machine, I can use the entirety of it, and when it's being used, I do not
# interfere with other users". Neither cgroup primitive does that on its own.
#
#   io.weight is work-conserving and would be exactly right, but it is inert
#   unless the device runs BFQ or has a blk-iocost model. BFQ was tried on
#   2026-09-12 and reverted the same day: measured at identical load it was
#   2.5x worse on reads and 13x worse on writes, because slice_idle=8ms
#   serialises a box running dozens of sessions.
#
#   io.max is a hard throttle that works under any scheduler (verified on this
#   box: a 10 MB/s limit held a 28.6 MB/s reader to 9.3 MB/s). But it is a
#   fixed number, so a share sized for four users is still only a quarter at
#   3am on an empty machine.
#
#   io.latency would give protection without the waste, and is NOT COMPILED
#   into this kernel (6.8.0-134): the cgroup exposes io.max and io.weight only.
#
# So the work-conserving half is done here instead of by the kernel: count who
# is actually active, divide the device between them, and lift the cap entirely
# when one user is alone. A timer re-runs it, so the share follows the room.
#
# WHAT COUNTS AS ACTIVE, and why it is not "has processes". Every user on this
# box has dozens of idle tmux sessions holding memory and doing nothing; if
# those counted, nobody would ever be alone. A user is active when they have a
# terminal attached, or when their slice actually moved bytes in the last
# interval. Both are things a person does, not things a leftover session does.
set -uo pipefail

INTERVAL_S="${DEVVM_IO_FAIRSHARE_INTERVAL_S:-30}"
# The ceiling to divide. These are devvm's QEMU caps (scripts/apply-mbps-caps.sh),
# which are the real limit on what this guest can pull, so dividing them is
# dividing what actually exists rather than a number off a datasheet.
DEVICE_RIOPS="${DEVVM_DEVICE_RIOPS:-1200}"
DEVICE_RBPS="${DEVVM_DEVICE_RBPS:-62914560}"   # 60 MB/s
DEVICE_WBPS="${DEVVM_DEVICE_WBPS:-62914560}"   # 60 MB/s
# Bytes in one interval below which a slice counts as idle rather than working.
IDLE_FLOOR_BYTES="${DEVVM_IO_IDLE_FLOOR_BYTES:-$((4 * 1024 * 1024))}"
STATE="${DEVVM_IO_FAIRSHARE_STATE:-/run/devvm-io-fairshare.state}"
TEXTFILE_DIR="${DEVVM_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
DRY_RUN="${DEVVM_IO_FAIRSHARE_DRY_RUN:-0}"
# Overridable so the division can be tested against a fake tree. The live
# behaviour cannot be exercised on demand: it needs two people working at once,
# and waiting for that to happen is not a test.
CG="${DEVVM_IO_FAIRSHARE_CGROUP_ROOT:-/sys/fs/cgroup/user.slice}"

# The backing device as io.max names it. dm-0 is what the guest's filesystems
# actually sit on; 8:0 is sda underneath it. Limits are written for the dm
# device because that is where the cgroup accounts the bytes.
DEVNUM="$(lsblk -no MAJ:MIN "$(awk '$2=="/"{print $1}' /proc/mounts | head -1)" 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$DEVNUM" ]] || exit 0

declare -A prev=()
[[ -r "$STATE" ]] && while read -r k v; do prev["$k"]="$v"; done < "$STATE"

active=(); idle=(); : > "$STATE.tmp"
for d in "$CG"/user-*.slice; do
  [[ -d "$d" ]] || continue
  uid="${d##*/user-}"; uid="${uid%.slice}"
  [[ "$uid" -ge 1000 ]] 2>/dev/null || continue
  user="$(id -nu "$uid" 2>/dev/null)" || user=""

  bytes=$(awk -v dn="$DEVNUM" '$1==dn{for(i=1;i<=NF;i++){if($i~/^rbytes=/) r=substr($i,8); if($i~/^wbytes=/) w=substr($i,8)}} END{print (r+w)+0}' "$d/io.stat" 2>/dev/null)
  bytes=${bytes:-0}
  echo "$uid $bytes" >> "$STATE.tmp"
  delta=$(( bytes - ${prev[$uid]:-$bytes} ))
  (( delta < 0 )) && delta=0

  attached=0
  [[ -n "$user" ]] && runuser -u "$user" -- tmux list-sessions -F '#{session_attached}' 2>/dev/null | grep -q '^[1-9]' && attached=1

  if (( attached == 1 || delta > IDLE_FLOOR_BYTES )); then active+=("$uid"); else idle+=("$uid"); fi
done
mv -f "$STATE.tmp" "$STATE" 2>/dev/null

n=${#active[@]}
apply() { # uid, value
  local f="$CG/user-$1.slice/io.max"
  [[ -w "$f" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then echo "  would set user-$1 io.max: $2"; return 0; fi
  echo "$DEVNUM $2" > "$f" 2>/dev/null || true
}

# A lone user, or nobody, gets the whole device. This is the half io.max cannot
# do by itself and the reason this script exists.
if (( n <= 1 )); then
  for d in "$CG"/user-*.slice; do
    uid="${d##*/user-}"; uid="${uid%.slice}"
    [[ "$uid" -ge 1000 ]] 2>/dev/null && apply "$uid" "riops=max rbps=max wbps=max"
  done
  msg="io fairshare: ${n} active, no caps (whole device available)"
else
  share_riops=$(( DEVICE_RIOPS / n )); share_rbps=$(( DEVICE_RBPS / n )); share_wbps=$(( DEVICE_WBPS / n ))
  for uid in "${active[@]}"; do apply "$uid" "riops=$share_riops rbps=$share_rbps wbps=$share_wbps"; done
  # An idle user is not competing, so capping them buys nothing and would only
  # make their next keystroke slow. They are lifted the moment they act.
  for uid in "${idle[@]}"; do apply "$uid" "riops=max rbps=max wbps=max"; done
  msg="io fairshare: ${n} active, ${share_riops} riops + $(( share_rbps / 1048576 )) MB/s each"
fi
echo "$msg"

if [[ -n "$TEXTFILE_DIR" && -d "$TEXTFILE_DIR" && "$DRY_RUN" != "1" ]]; then
  t="$TEXTFILE_DIR/devvm_io_fairshare.prom"
  {
    echo "# HELP devvm_io_active_users Users counted as competing for the disk this interval."
    echo "# TYPE devvm_io_active_users gauge"
    echo "devvm_io_active_users $n"
    echo "# HELP devvm_io_share_riops Read IOPS each active user is currently allowed; 0 means uncapped."
    echo "# TYPE devvm_io_share_riops gauge"
    echo "devvm_io_share_riops $(( n <= 1 ? 0 : DEVICE_RIOPS / n ))"
    echo "# HELP devvm_io_fairshare_last_run_timestamp_seconds When this last completed."
    echo "# TYPE devvm_io_fairshare_last_run_timestamp_seconds gauge"
    echo "devvm_io_fairshare_last_run_timestamp_seconds $(date +%s)"
  } > "$t.tmp" 2>/dev/null && mv -f "$t.tmp" "$t" || rm -f "$t.tmp"
fi
