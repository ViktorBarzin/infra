#!/usr/bin/env bash
# Tests for the idle/active classification in devvm-io-fairshare.sh.
#
# The classification is the whole decision this script makes, and it is the
# part that broke silently: the idle floor was a fixed 40 MB chosen for a
# 10-minute timer, and when the timer went to 2 minutes the same number became
# a 5x stricter rate test. A user working without an attached terminal then
# reads as idle, and an idle user is deliberately left UNCAPPED, so the
# regression handed the whole device to exactly the person it should throttle.
set -uo pipefail
SCRIPT="$(dirname "$0")/devvm-io-fairshare.sh"
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# A fake cgroup tree. Only io.stat and io.max are read, and io.max must be
# writable for apply() to do anything.
mktree() { # root, devnum, uid:bytes...
  local root="$1" dn="$2"; shift 2
  for spec in "$@"; do
    local uid="${spec%%:*}" bytes="${spec##*:}"
    mkdir -p "$root/user-$uid.slice"
    printf '%s rbytes=%s wbytes=0 rios=1 wios=0 dbytes=0 dios=0\n' "$dn" "$bytes" \
      > "$root/user-$uid.slice/io.stat"
    : > "$root/user-$uid.slice/io.max"
  done
}

run() { # root, state, elapsed_fudge_seconds -> stdout
  local root="$1" state="$2"
  DEVVM_IO_FAIRSHARE_CGROUP_ROOT="$root" \
  DEVVM_IO_FAIRSHARE_STATE="$state" \
  DEVVM_IO_FAIRSHARE_DRY_RUN=1 \
  DEVVM_TEXTFILE_DIR="" \
  bash "$SCRIPT" 2>/dev/null
}

DN="$(lsblk -no MAJ:MIN "$(awk '$2=="/"{print $1}' /proc/mounts | head -1)" 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$DN" ]] || { echo "cannot resolve the root device number"; exit 1; }

# --- a user moving 133 kB/s over a 2-minute period is WORKING --------------
# 16 MB in 120s. Under the old fixed 40 MB floor this read as idle and the
# slice was uncapped; the floor is meant to sit at 68 kB/s.
T=$(mktemp -d); S="$T/state"
mktree "$T/cg" "$DN" 1000:0 1002:0
run "$T/cg" "$S" >/dev/null
# rewind the recorded timestamp so the next run sees a 120s period
sed -i 's/^__ts .*/__ts '"$(( $(date +%s) - 120 ))"'/' "$S" 2>/dev/null
mktree "$T/cg" "$DN" 1000:$((16 * 1024 * 1024)) 1002:$((16 * 1024 * 1024))
out="$(run "$T/cg" "$S")"
if grep -q '2 active' <<<"$out"; then
  ok "16 MB over 120s counts both users as working"
else
  bad "16 MB over 120s counts both users as working" "got: $(tr '\n' '|' <<<"$out")"
fi

# --- a genuinely quiet user is still idle ----------------------------------
T2=$(mktemp -d); S2="$T2/state"
mktree "$T2/cg" "$DN" 1000:0 1002:0
run "$T2/cg" "$S2" >/dev/null
sed -i 's/^__ts .*/__ts '"$(( $(date +%s) - 120 ))"'/' "$S2" 2>/dev/null
# 1 MB in 120s is 8.7 kB/s, well under the 68 kB/s line
mktree "$T2/cg" "$DN" 1000:$((1024 * 1024)) 1002:$((1024 * 1024))
out2="$(run "$T2/cg" "$S2")"
if grep -q '0 active' <<<"$out2"; then
  ok "1 MB over 120s leaves both users idle"
else
  bad "1 MB over 120s leaves both users idle" "got: $(tr '\n' '|' <<<"$out2")"
fi

# --- the floor tracks the period, not a hardcoded interval ------------------
# The same 16 MB spread over 10 minutes is 27 kB/s and IS idle. This is the
# property that makes the timer safe to retune without editing the floor.
T3=$(mktemp -d); S3="$T3/state"
mktree "$T3/cg" "$DN" 1000:0 1002:0
run "$T3/cg" "$S3" >/dev/null
sed -i 's/^__ts .*/__ts '"$(( $(date +%s) - 600 ))"'/' "$S3" 2>/dev/null
mktree "$T3/cg" "$DN" 1000:$((16 * 1024 * 1024)) 1002:$((16 * 1024 * 1024))
out3="$(run "$T3/cg" "$S3")"
if grep -q '0 active' <<<"$out3"; then
  ok "the same 16 MB over 600s is idle, so the floor follows the period"
else
  bad "the same 16 MB over 600s is idle, so the floor follows the period" "got: $(tr '\n' '|' <<<"$out3")"
fi

rm -rf "$T" "$T2" "$T3"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
