#!/usr/bin/env bash
# Tests for playbooks/files/pve/csi-leak-reconcile. A stub `qm` and `flock` on
# PATH replay monitor output captured from the real host (2026-11-02), so the
# tests touch no VM.
#
#   bash playbooks/files/pve/csi-leak-reconcile.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/csi-leak-reconcile"

fails=0 passes=0
ok() { passes=$((passes + 1)); echo "ok   $1"; }
bad() { fails=$((fails + 1)); echo "FAIL $1"; [ $# -gt 1 ] && printf '     %s\n' "${@:2}"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $(printf %q "$2")" "got:  $(printf %q "$3")"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- fixtures, in the shape `qm monitor` and `qm config` print them ---------

qom_fixture() { # slots that have a throttle object
  printf 'qm> qom-list /objects\nqm> Entering QEMU Monitor for VM 205 - type '"'"'help'"'"' for help\ntype (string)\n'
  for s in "$@"; do echo "throttle-drive-$s (child<throttle-group>)"; done
  echo 'throttle-drive-ide2 (child<throttle-group>)'
}
block_fixture() { # slots with a device attached
  printf 'qm> info block\nqm> Entering QEMU Monitor for VM 205 - type '"'"'help'"'"' for help\n'
  for s in "$@"; do
    printf 'drive-%s: json:{"throttle-group": "throttle-drive-%s", "driver": "throttle"} (throttle)\n    Attached to:      %s\n    Cache mode:       writeback\n\n' "$s" "$s" "$s"
  done
}
config_fixture() { # slots in the VM config
  echo 'name: k8s-node5'
  echo 'scsihw: virtio-scsi-pci'
  for s in "$@"; do echo "$s: local-lvm:vm-9999-pvc-0000,backup=0,iothread=1,size=1G"; done
}

# shellcheck source=csi-leak-reconcile
source "$SCRIPT"

# --- parsing -----------------------------------------------------------------

eq "throttle slots are read from qom-list, scsi only" \
  "scsi1 scsi14 scsi3" "$(qom_fixture scsi3 scsi1 scsi14 | throttle_slots | xargs)"
eq "attached slots are read from info block" \
  "scsi0 scsi3" "$(block_fixture scsi0 scsi3 | attached_slots | xargs)"
eq "config slots are read from qm config" \
  "scsi0 scsi3" "$(config_fixture scsi0 scsi3 | config_slots | xargs)"

# --- which slots are leaked --------------------------------------------------

eq "a throttle object with no config entry and no device is leaked" \
  "scsi1" "$(leaked_slots "$(qom_fixture scsi0 scsi1 scsi3)" "$(config_fixture scsi0 scsi3)" "$(block_fixture scsi0 scsi3)" | xargs)"
eq "a slot still in the config is never leaked (attach or detach in flight)" \
  "" "$(leaked_slots "$(qom_fixture scsi0 scsi1)" "$(config_fixture scsi0 scsi1)" "$(block_fixture scsi0)" | xargs)"
eq "a slot with a device attached is never leaked" \
  "" "$(leaked_slots "$(qom_fixture scsi0 scsi1)" "$(config_fixture scsi0)" "$(block_fixture scsi0 scsi1)" | xargs)"
eq "scsi1 and scsi10 are told apart" \
  "scsi10" "$(leaked_slots "$(qom_fixture scsi1 scsi10)" "$(config_fixture scsi1)" "$(block_fixture scsi1)" | xargs)"

# --- two-strike rule ---------------------------------------------------------

eq "a leak seen for the first time is not due" \
  "" "$(due_slots 205 "scsi1" "" | xargs)"
eq "a leak seen on the previous run too is due" \
  "scsi1" "$(due_slots 205 "scsi1 scsi5" "205:scsi1 204:scsi5" | xargs)"

# --- full run against a stub qm ---------------------------------------------

mkdir -p "$T/bin" "$T/textfile" "$T/state"
# The stub reads its per-VM fixtures from $T/vm/<vmid>/{qom,block,config,running}
# and logs every monitor command it is sent, so a run can be checked afterwards.
cat >"$T/bin/qm" <<'EOF'
#!/usr/bin/env bash
d="$STUB_ROOT/vm/$2"
case "$1" in
  list)
    printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
    for v in "$STUB_ROOT"/vm/*; do printf '       %s node                 %s    1024   1.00 1\n' "$(basename "$v")" "$(cat "$v/running")"; done ;;
  config) cat "$d/config" ;;
  monitor)
    cmd=$(cat)
    echo "$2 $cmd" >>"$STUB_ROOT/monitor.log"
    case "$cmd" in
      "qom-list /objects") cat "$d/qom" ;;
      "info block") cat "$d/block" ;;
      drive_del*) ;;
      object_del*)
        s=${cmd#object_del throttle-drive-}
        grep -v "throttle-drive-$s " "$d/qom" >"$d/qom.new"; mv "$d/qom.new" "$d/qom" ;;
    esac ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/flock"   # flock -w N <fd>: always granted
chmod +x "$T/bin/qm" "$T/bin/flock"

setup_vm() { # vmid running qom-slots / config-slots / attached-slots
  mkdir -p "$T/vm/$1"; echo "$2" >"$T/vm/$1/running"
  # shellcheck disable=SC2086
  { qom_fixture $3 >"$T/vm/$1/qom"; config_fixture $4 >"$T/vm/$1/config"; block_fixture $5 >"$T/vm/$1/block"; }
}
run() {
  STUB_ROOT="$T" PATH="$T/bin:$PATH" TEXTFILE_DIR="$T/textfile" STATE_FILE="$T/state/s" LOCK_DIR="$T/state" \
    bash "$SCRIPT" >"$T/out.log" 2>&1
}
setup_vm 205 running "scsi0 scsi1 scsi3" "scsi0 scsi3" "scsi0 scsi3"
setup_vm 204 running "scsi0 scsi7" "scsi0 scsi7" "scsi0 scsi7"
setup_vm 300 stopped "scsi0 scsi9" "scsi0" "scsi0"
: >"$T/monitor.log"

run
eq "first run deletes nothing" "0" "$(grep -c 'drive_del\|object_del' "$T/monitor.log")"
has() { grep -q "$2" "$T/textfile/pve_csi_leak_reconcile.prom"; }
if has x 'pve_csi_leaked_slots{vmid="205"} 1'; then ok "first run reports the leak"; else bad "first run reports the leak" "$(cat "$T/textfile/pve_csi_leak_reconcile.prom" "$T/out.log")"; fi

run
eq "second run removes the block node, then the throttle object" \
  "205 drive_del drive-scsi1|205 object_del throttle-drive-scsi1" \
  "$(grep 'drive_del\|object_del' "$T/monitor.log" | paste -sd'|')"
if has x 'pve_csi_leaked_slots{vmid="205"} 0'; then ok "second run reports the slot clear"; else bad "second run reports the slot clear" "$(cat "$T/out.log")"; fi
if has x 'pve_csi_leak_cleaned_total 1'; then ok "cleanups are counted"; else bad "cleanups are counted"; fi
if has x 'pve_csi_leak_reconcile_errors 0'; then ok "no VM failed inspection"; else bad "no VM failed inspection" "$(cat "$T/out.log")"; fi
eq "a stopped VM is never inspected" "0" "$(grep -c '^300 ' "$T/monitor.log")"
eq "a healthy VM is never cleaned" "0" "$(grep -c '^204 drive_del\|^204 object_del' "$T/monitor.log")"

echo
echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
