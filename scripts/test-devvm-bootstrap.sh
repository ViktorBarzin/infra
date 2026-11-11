#!/usr/bin/env bash
# Tests for scripts/devvm-bootstrap (the first-boot build a Terraform-made devvm
# runs from cloud-init) and scripts/devvm-drill-handoff (the applier side that
# hands it a wrapped Vault token through the guest agent). Every external
# command is a stub on PATH that logs its arguments, so nothing touches Vault,
# Proxmox, apt or git.
# Run: bash scripts/test-devvm-bootstrap.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$DIR/devvm-bootstrap"
HANDOFF="$DIR/devvm-drill-handoff"

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
has() {  # <description> <file> <pattern>
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok; else bad "$1 (no /$3/ in $2)"; cat "$2" 2>/dev/null | sed 's/^/    /'; fi
}
hasnt() {  # <description> <file> <pattern>
  if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1 (found /$3/ in $2)"; else ok; fi
}
eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected [$2] got [$3]"; fi; }

new_sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/state" "$SB/log"
  export LOG="$SB/log/calls"
  : >"$LOG"
}

stub() {  # <name> <body>  — body runs with "$@" = the call's arguments
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$LOG"\n%s\n' "$1" "$2" >"$SB/bin/$1"
  chmod +x "$SB/bin/$1"
}

# ---------------------------------------------------------------------------
# devvm-bootstrap
# ---------------------------------------------------------------------------

bootstrap_stubs() {
  # curl answers the unwrap call; the config it reads on stdin carries the
  # wrapped token header, which the stub records so the test can check the
  # token never went into argv.
  stub curl 'cat >>"$LOG.stdin"
case "$*" in
  *sys/wrapping/unwrap*) printf "%s" "${UNWRAP_REPLY-{\"auth\":{\"client_token\":\"hvs.inner\"}}}" ;;
esac'
  stub vault 'echo "VAULT_TOKEN=$VAULT_TOKEN VAULT_ADDR=$VAULT_ADDR" >>"$LOG.env"'
  stub git 'case "$1" in clone) mkdir -p "${@: -1}/scripts/workstation" "${@: -1}/playbooks"; printf "#!/bin/sh\necho provisioner \"\$WORKSTATION_DIR\" >>\"$LOG\"\n" >"${@: -1}/scripts/t3-provision-users.sh" ;; esac'
  stub ansible-playbook 'echo "playbook VAULT_TOKEN=$VAULT_TOKEN cwd=$PWD" >>"$LOG.env"; exit "${PLAYBOOK_RC:-0}"'
  stub install 'cp "${@: -2:1}" "${@: -1}" && chmod +x "${@: -1}"'
  stub apt-get 'exit 0'
}

run_bootstrap() {
  PATH="$SB/bin:$PATH" \
    DEVVM_BOOTSTRAP_HANDOFF="$SB/handoff.json" \
    DEVVM_BOOTSTRAP_STATE="$SB/state" \
    DEVVM_BOOTSTRAP_CLONE="$SB/clone" \
    DEVVM_BOOTSTRAP_PROVISIONER="$SB/t3-provision-users" \
    DEVVM_BOOTSTRAP_WAIT="${WAIT:-2}" \
    DEVVM_BOOTSTRAP_POLL=1 \
    bash "$BOOTSTRAP" >"$SB/log/out" 2>&1
}

# 1. Happy path: unwrap, clone the asked ref, playbook, provisioning, revoke.
new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"wizard/drill"}' >"$SB/handoff.json"
run_bootstrap; rc=$?
eq "happy path exits 0" 0 "$rc"
eq "status is ok" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
has "unwrap goes to Vault" "$LOG" 'curl .*https://vault\.viktorbarzin\.me/v1/sys/wrapping/unwrap'
has "wrapped token sent as a header on stdin" "$LOG.stdin" 'X-Vault-Token: hvs\.wrapped'
hasnt "wrapped token never in argv" "$LOG" 'hvs\.wrapped'
hasnt "inner token never in argv" "$LOG" 'hvs\.inner'
has "clones the handed-over ref" "$LOG" 'git clone --depth 1 --branch wizard/drill https://forgejo\.viktorbarzin\.me/viktor/infra\.git'
has "playbook runs locally against this box" "$LOG" 'ansible-playbook -i localhost, -c local -e devvm_target=localhost .*playbooks/devvm\.yml'
has "playbook sees the unwrapped token" "$LOG.env" 'playbook VAULT_TOKEN=hvs\.inner'
has "provisioner runs from the bootstrap clone" "$LOG" "provisioner $SB/clone/scripts/workstation"
has "installs the lobby packages after the playbook" "$LOG" 'apt-get install -y -qq terminal-lobby ttyd-devvm'
if [[ "$(grep -nE '^ansible-playbook' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^apt-get install -y -qq terminal-lobby' "$LOG" | cut -d: -f1)" ]]; then ok; else bad "lobby install comes after the playbook"; fi
has "token revoked at the end" "$LOG" 'vault token revoke -self'
[[ -e "$SB/handoff.json" ]] && bad "handoff file removed after reading" || ok

# 1b. The guest agent creates the file 0666, so the bootstrap refuses a
# handoff directory anyone but root can enter.
new_sandbox; bootstrap_stubs
mkdir -p "$SB/hd"; chmod 0755 "$SB/hd"
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/hd/handoff.json"
PATH="$SB/bin:$PATH" DEVVM_BOOTSTRAP_HANDOFF="$SB/hd/handoff.json" DEVVM_BOOTSTRAP_STATE="$SB/state" \
  DEVVM_BOOTSTRAP_CLONE="$SB/clone" DEVVM_BOOTSTRAP_PROVISIONER="$SB/t3-provision-users" \
  DEVVM_BOOTSTRAP_WAIT=2 DEVVM_BOOTSTRAP_POLL=1 bash "$BOOTSTRAP" >"$SB/log/out" 2>&1; rc=$?
eq "open handoff dir exits non-zero" 1 "$rc"
has "status names the handoff dir" "$SB/state/status" 'handoff directory'
hasnt "open handoff dir never unwraps" "$LOG" 'unwrap'

# 2. No handoff within the wait: fail, say why, run nothing.
new_sandbox; bootstrap_stubs
WAIT=1 run_bootstrap; rc=$?
eq "missing handoff exits non-zero" 1 "$rc"
has "status names the wait" "$SB/state/status" '^failed: no handoff'
hasnt "no playbook without a token" "$LOG" 'ansible-playbook'

# 3. A wrapped token someone already unwrapped is an alarm, not a retry.
new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/handoff.json"
UNWRAP_REPLY='{"errors":["wrapping token is not valid or does not exist"]}' run_bootstrap; rc=$?
eq "failed unwrap exits non-zero" 1 "$rc"
has "status flags possible interception" "$SB/state/status" 'unwrap'
hasnt "no clone after a failed unwrap" "$LOG" 'git clone'

# 4. A ref with shell metacharacters is refused before anything runs.
new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master;rm -rf /"}' >"$SB/handoff.json"
run_bootstrap; rc=$?
eq "bad ref exits non-zero" 1 "$rc"
has "status names the ref" "$SB/state/status" 'ref'
hasnt "bad ref never unwraps" "$LOG" 'unwrap'

# 5. A failed playbook stops provisioning, still revokes the token.
new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/handoff.json"
PLAYBOOK_RC=2 run_bootstrap; rc=$?
[[ $rc -ne 0 ]] && ok || bad "failed playbook exits non-zero"
has "status names the playbook" "$SB/state/status" '^failed: playbook'
hasnt "no provisioning after a failed playbook" "$LOG" '^provisioner'
has "token revoked after a failure too" "$LOG" 'vault token revoke -self'

# ---------------------------------------------------------------------------
# devvm-drill-handoff
# ---------------------------------------------------------------------------

handoff_stubs() {
  # The agent answers ping only from the second call, to exercise the wait.
  stub curl 'cat >>"$LOG.stdin"
for a in "$@"; do case "$a" in content@*) cp "${a#content@}" "$LOG.content" ;; esac; done
case "$*" in
  *agent/ping*) n=$(cat "$LOG.pings" 2>/dev/null || echo 0); n=$((n + 1)); echo $n >"$LOG.pings"
                [ "$n" -ge "${PING_OK_AT:-2}" ] || exit 22; echo "{\"data\":{}}" ;;
  *agent/file-write*) echo "{\"data\":null}" ;;
esac'
  stub vault 'case "$*" in "token create"*) echo hvs.wrappedtoken ;; esac'
}

run_handoff() {
  PATH="$SB/bin:$PATH" \
    PVE_ENDPOINT="https://pve.test:8006" PVE_NODE=pve VMID=9102 \
    PVE_API_TOKEN='terraform-devvm@pve!tf=secret-uuid' INFRA_REF="${REF:-master}" \
    HANDOFF_WAIT="${HWAIT:-5}" HANDOFF_POLL=0 \
    bash "$HANDOFF" >"$SB/log/out" 2>&1
}

# 6. Waits for the agent, mints through the role, writes the handoff file.
new_sandbox; handoff_stubs
run_handoff; rc=$?
eq "handoff exits 0" 0 "$rc"
eq "pinged until the agent answered" 2 "$(cat "$LOG.pings")"
has "mints through the bootstrap role, wrapped" "$LOG" 'vault token create -role=devvm-bootstrap -policy=devvm-bootstrap -wrap-ttl=1h -field=wrapping_token'
has "writes through the guest agent of the right VM" "$LOG" 'curl .*https://pve\.test:8006/api2/json/nodes/pve/qemu/9102/agent/file-write'
has "writes into the root-only handoff dir" "$LOG" 'file=/run/devvm-bootstrap/handoff\.json'
has "handoff carries the wrapped token" "$LOG.content" '"wrapped_token": *"hvs\.wrappedtoken"'
has "handoff carries the ref" "$LOG.content" '"infra_ref": *"master"'
has "PVE token sent as a header on stdin" "$LOG.stdin" 'Authorization: PVEAPIToken=terraform-devvm@pve!tf=secret-uuid'
hasnt "PVE token never in argv" "$LOG" 'secret-uuid'
hasnt "wrapped token never in argv" "$LOG" 'hvs\.wrappedtoken'
hasnt "nothing secret printed" "$SB/log/out" 'secret-uuid|hvs\.'

# 7. An agent that never answers fails without minting a token.
new_sandbox; handoff_stubs
PING_OK_AT=999 HWAIT=1 run_handoff; rc=$?
eq "silent agent exits non-zero" 1 "$rc"
hasnt "no token minted for a VM that never came up" "$LOG" 'vault token create'

# 8. A bad ref is refused before minting.
new_sandbox; handoff_stubs
REF='x$(id)' run_handoff; rc=$?
eq "bad ref exits non-zero" 1 "$rc"
hasnt "no token minted for a bad ref" "$LOG" 'vault token create'

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
