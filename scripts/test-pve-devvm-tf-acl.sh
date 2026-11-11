#!/usr/bin/env bash
# Tests for scripts/pve-devvm-tf-acl, which re-grants stacks/devvm's token its
# VMID slots on the Proxmox host. Every VM destroy deletes the ACLs on
# /vms/<id> (PVE's remove_vm_access, purge or not), so without it each drill
# used up its slot. pveum is a stub that logs its arguments; user.cfg and the
# guest config folders are files in a sandbox.
# Run: bash scripts/test-pve-devvm-tf-acl.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL="$DIR/pve-devvm-tf-acl"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
has() {  # <description> <file> <pattern>
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok; else bad "$1 (no /$3/ in $2)"; sed 's/^/    /' "$2" 2>/dev/null; fi
}
hasnt() {  # <description> <file> <pattern>
  if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1 (found /$3/ in $2)"; else ok; fi
}
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }

U='terraform-devvm@pve'
T='terraform-devvm@pve!tf'

new_sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/nodes/pve/qemu-server" "$SB/nodes/pve/lxc"
  export LOG="$SB/calls"
  : >"$LOG"
  printf '#!/usr/bin/env bash\nprintf "pveum %%s\\n" "$*" >>"$LOG"\n' >"$SB/bin/pveum"
  chmod +x "$SB/bin/pveum"
  # A host with the live devvm and one other VM.
  : >"$SB/nodes/pve/qemu-server/102.conf"
  : >"$SB/nodes/pve/qemu-server/200.conf"
  export PVE_USER_CFG="$SB/user.cfg" PVE_NODES_DIR="$SB/nodes" PVEUM="$SB/bin/pveum"
}

user_cfg() {  # <pool vmlist> <acl lines...>
  {
    printf 'user:%s:1:0::::Terraform stacks/devvm::\n' "$U"
    printf 'token:%s:0:1:stacks/devvm:\n\n' "$T"
    printf 'pool:devvm:VMs stacks/devvm owns. The live devvm 102 is deliberately not a member.:%s::\n\n' "$1"
    shift
    printf '%s\n' "$@"
  } >"$PVE_USER_CFG"
}

run() {  # [args...] — output to $SB/out, exit code to $rc
  "$ACL" "$@" >"$SB/out" 2>&1
  rc=$?
}

all_slots() {
  local id
  for id in $(seq 9100 9109); do printf 'acl:1:/vms/%s:%s,%s:TFDevvm:\n' "$id" "$U" "$T"; done
}

# --- every slot granted: nothing to do, and nothing printed -----------------
new_sandbox
user_cfg "" $(all_slots)
run
eq "all granted: exit 0" 0 "$rc"
eq "all granted: no pveum call" "" "$(cat "$LOG")"
eq "all granted: silent" "" "$(cat "$SB/out")"

# --- a destroyed drill's slot is re-granted to the user and the token -------
new_sandbox
user_cfg "" $(all_slots | grep -v '/vms/9103:')
run
eq "missing slot: exit 0" 0 "$rc"
has "missing slot: user re-granted" "$LOG" "^pveum acl modify /vms/9103 --roles TFDevvm --users $U --propagate 1$"
has "missing slot: token re-granted" "$LOG" "^pveum acl modify /vms/9103 --roles TFDevvm --tokens $T --propagate 1$"
eq "missing slot: only that slot" 2 "$(wc -l <"$LOG" | tr -d ' ')"
has "missing slot: says what it granted" "$SB/out" "grant /vms/9103"

# --- only the token lost it: only the token is re-granted --------------------
new_sandbox
user_cfg "" $(all_slots | grep -v '/vms/9105:') "acl:1:/vms/9105:$U:TFDevvm:"
run
eq "token only: one call" 1 "$(wc -l <"$LOG" | tr -d ' ')"
has "token only: token re-granted" "$LOG" "/vms/9105 --roles TFDevvm --tokens"

# --- a slot whose ACL carries another role, not TFDevvm, still counts as missing
new_sandbox
user_cfg "" $(all_slots | grep -v '/vms/9106:') "acl:1:/vms/9106:$U,$T:PVEAuditor:"
run
eq "other role: both granted" 2 "$(wc -l <"$LOG" | tr -d ' ')"

# --- --dry-run says what it would grant and changes nothing ------------------
new_sandbox
user_cfg "" $(all_slots | grep -v '/vms/9103:')
run --dry-run
eq "dry-run: exit 0" 0 "$rc"
eq "dry-run: no pveum call" "" "$(cat "$LOG")"
has "dry-run: names the grant" "$SB/out" "grant /vms/9103 $U"

# --- a running drill in its slot (a pool member) keeps its grant -------------
new_sandbox
: >"$SB/nodes/pve/qemu-server/9104.conf"
user_cfg "9104" $(all_slots | grep -v '/vms/9104:')
run
has "pool member: re-granted" "$LOG" "/vms/9104 --roles TFDevvm --users"

# --- a slot holding a guest outside pool devvm is never granted --------------
new_sandbox
: >"$SB/nodes/pve/qemu-server/9107.conf"
user_cfg "" $(all_slots | grep -v '/vms/9107:')
run
eq "foreign VM: exit 0" 0 "$rc"
hasnt "foreign VM: no grant" "$LOG" "/vms/9107"
has "foreign VM: says why" "$SB/out" "skip /vms/9107.*outside pool devvm"

# --- the same for a container, which shares the VMID space ------------------
new_sandbox
: >"$SB/nodes/pve/lxc/9108.conf"
user_cfg "" $(all_slots | grep -v '/vms/9108:')
run
hasnt "foreign CT: no grant" "$LOG" "/vms/9108"

# --- the live devvm: listed only for the replacement, never granted while it exists
new_sandbox
user_cfg "" $(all_slots)
DEVVM_TF_VMIDS="102 $(seq -s ' ' 9100 9109)" run
hasnt "live 102 exists: no grant" "$LOG" "/vms/102"
has "live 102 exists: says why" "$SB/out" "skip /vms/102"
rm "$SB/nodes/pve/qemu-server/102.conf"
DEVVM_TF_VMIDS="102 $(seq -s ' ' 9100 9109)" run
has "102 gone: granted for the replacement" "$LOG" "^pveum acl modify /vms/102 --roles TFDevvm --tokens"
new_sandbox
rm "$SB/nodes/pve/qemu-server/102.conf"
user_cfg "" $(all_slots)
run
hasnt "default list has no 102" "$LOG" "/vms/102"

# --- refuses to act on a host it cannot read ---------------------------------
new_sandbox
rm -f "$SB/nodes/pve/qemu-server/"*.conf
user_cfg "" $(all_slots | grep -v '/vms/9103:')
run
eq "no guest configs (pmxcfs down?): fails" 1 "$rc"
eq "no guest configs: no grant" "" "$(cat "$LOG")"

new_sandbox
run
eq "no user.cfg: fails" 1 "$rc"
eq "no user.cfg: no grant" "" "$(cat "$LOG")"

new_sandbox
printf 'pool:devvm:x:::\n' >"$PVE_USER_CFG"
run
eq "token user not declared yet: exit 0" 0 "$rc"
eq "token user not declared yet: no grant" "" "$(cat "$LOG")"
has "token user not declared yet: says so" "$SB/out" "pve-host.yml"

new_sandbox
printf 'user:%s:1:0::::x::\n' "$U" >"$PVE_USER_CFG"
run
eq "no pool devvm: fails" 1 "$rc"

new_sandbox
user_cfg "" $(all_slots)
DEVVM_TF_VMIDS="9100 abc" run
eq "bad VMID list: fails" 1 "$rc"
eq "bad VMID list: no grant" "" "$(cat "$LOG")"

# --- a failing pveum fails the run -------------------------------------------
new_sandbox
printf '#!/usr/bin/env bash\nexit 7\n' >"$SB/bin/pveum"
user_cfg "" $(all_slots | grep -v '/vms/9103:')
run
eq "pveum failure: fails" 1 "$rc"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
