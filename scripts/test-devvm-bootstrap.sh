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
  *secret/data/workstation/devvm/ssh-host-keys*) [ -n "${HOSTKEYS_REPLY:-}" ] && cat "$HOSTKEYS_REPLY" || printf "{\"errors\":[\"permission denied\"]}" ;;
esac'
  stub vault 'echo "VAULT_TOKEN=$VAULT_TOKEN VAULT_ADDR=$VAULT_ADDR" >>"$LOG.env"
case "$*" in
  "kv get -format=json secret/devvm-t3-seed")
    [ -z "${SEED_VAULT_FAIL:-}" ] || exit 2
    printf "{\"data\":{\"data\":{\"private_key\":\"PRIVKEY-SECRET\",\"known_hosts\":\"192.168.1.127 ssh-ed25519 AAAAhostkey\"}}}" ;;
esac'
  # The clone carries the real playbook, so the vault version the bootstrap
  # installs is checked against the one the playbook pins.
  stub git 'case "$1" in clone) mkdir -p "${@: -1}/scripts/workstation" "${@: -1}/playbooks"; cp "'"$DIR"'/../playbooks/devvm.yml" "${@: -1}/playbooks/devvm.yml"; [ -z "${NO_VAULT_PIN:-}" ] || sed -i "/devvm_vault_version:/d" "${@: -1}/playbooks/devvm.yml"; printf "#!/bin/sh\necho provisioner \"\$WORKSTATION_DIR\" >>\"$LOG\"\n[ -e \"\$DEVVM_BOOTSTRAP_T3_HOLD\" ] && echo provisioner-held >>\"$LOG\"\nexit 0\n" >"${@: -1}/scripts/t3-provision-users.sh" ;; esac'
  stub ansible-playbook 'echo "playbook VAULT_TOKEN=$VAULT_TOKEN HOME=${HOME:-unset} cwd=$PWD" >>"$LOG.env"; [ -e "$DEVVM_BOOTSTRAP_T3_HOLD" ] && echo "hold present at playbook" >>"$LOG.env"; exit "${PLAYBOOK_RC:-0}"'
  # rsync records the key and known_hosts files its ssh was given, then
  # "copies" one snapshot into a destination that arrives root-only, as the
  # host'"'"'s 0700 /mnt/backup/t3-state would make it.
  stub rsync 'for a in "$@"; do case "$a" in "ssh "*)
    k=$(sed -E "s/.* -i ([^ ]+).*/\1/" <<<"$a"); kh=$(sed -E "s/.*UserKnownHostsFile=([^ ]+).*/\1/" <<<"$a")
    echo "$k" >"$LOG.seedkeypath"; cat "$k" >"$LOG.seedkey"; stat -c %a "$k" >"$LOG.seedkeymode"; cat "$kh" >"$LOG.seedkh" ;;
  esac; done
d="${@: -1}"; mkdir -p "$d/wizard"; chmod 0700 "$d"; echo snap >"$d/wizard/state-20261111-034710.sqlite.gz"
exit "${RSYNC_RC:-0}"'
  stub install 'cp "${@: -2:1}" "${@: -1}" && chmod +x "${@: -1}"'
  stub systemctl 'exit 0'
  # The box's own first-boot host keys, which a drill keeps.
  mkdir -p "$SB/etc-ssh" "$SB/cloud.cfg.d" "$SB/tmp"
  for t in ed25519 ecdsa; do
    ssh-keygen -q -t "$t" -N "" -C fresh -f "$SB/etc-ssh/ssh_host_${t}_key"
  done
  stub apt-get 'exit 0'
  # dpkg-query reports the installed vault: none on a blank box.
  stub dpkg-query 'printf "%s" "${VAULT_INSTALLED:-}"; [ -n "${VAULT_INSTALLED:-}" ]'
}

run_bootstrap() {
  # cloud-init's runcmd has no HOME, and that is how the bootstrap runs for real.
  env -u HOME PATH="$SB/bin:$PATH" \
    DEVVM_BOOTSTRAP_HANDOFF="$SB/handoff.json" \
    DEVVM_BOOTSTRAP_STATE="$SB/state" \
    DEVVM_BOOTSTRAP_CLONE="$SB/clone" \
    DEVVM_BOOTSTRAP_PROVISIONER="$SB/t3-provision-users" \
    DEVVM_BOOTSTRAP_T3_DIR="$SB/t3" \
    DEVVM_BOOTSTRAP_T3_HOLD="$SB/hold/awaiting-snapshots" \
    DEVVM_BOOTSTRAP_HASHICORP_KEYRING="$SB/hashicorp.asc" \
    DEVVM_BOOTSTRAP_HASHICORP_LIST="$SB/hashicorp.list" \
    DEVVM_BOOTSTRAP_SSH_DIR="$SB/etc-ssh" \
    DEVVM_BOOTSTRAP_CLOUD_CFG_D="$SB/cloud.cfg.d" \
    TMPDIR="$SB/tmp" \
    DEVVM_BOOTSTRAP_WAIT="${WAIT:-2}" \
    DEVVM_BOOTSTRAP_POLL=1 \
    bash "$BOOTSTRAP" </dev/null >"$SB/log/out" 2>&1
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
has "playbook gets a HOME under cloud-init (go build needs one)" "$LOG.env" 'playbook .*HOME=/root '

has "provisioner runs from the bootstrap clone" "$LOG" "provisioner $SB/clone/scripts/workstation"
has "installs the lobby packages after the playbook" "$LOG" 'apt-get install -y -qq terminal-lobby ttyd-devvm'
if [[ "$(grep -nE '^ansible-playbook' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^apt-get install -y -qq terminal-lobby' "$LOG" | cut -d: -f1)" ]]; then ok; else bad "lobby install comes after the playbook"; fi
has "token revoked at the end" "$LOG" 'vault token revoke -self'
[[ -e "$SB/handoff.json" ]] && bad "handoff file removed after reading" || ok
hasnt "a drill never asks for the live host keys" "$LOG" 'ssh-host-keys'
eq "a drill keeps its own host keys" "fresh" "$(cut -d' ' -f3 "$SB/etc-ssh/ssh_host_ed25519_key.pub")"
[[ -z "$(ls -A "$SB/cloud.cfg.d")" ]] && ok || bad "a drill leaves cloud-init's key handling alone"
hasnt "a drill does not restart sshd" "$LOG" '^systemctl .*ssh'

# 1a. T3 snapshots: copied from the PVE host after the playbook, before
# provisioning, with the read-only key from Vault, so provisioning's
# t3-restore-state --if-missing finds them. The hold is up from before the
# playbook (whose provisioning timer could fire early) until the copy is in.
has "reads the seed key from Vault with the bootstrap token" "$LOG.env" 'VAULT_TOKEN=hvs\.inner'
has "reads the seed key from Vault" "$LOG" '^vault kv get -format=json secret/devvm-t3-seed'
has "pulls from the PVE host's snapshot directory" "$LOG" "^rsync .* root@192\.168\.1\.127:\./ $SB/t3/\$"
has "skips the host's staging directory" "$LOG" '^rsync .*--exclude=\.incoming'
has "pins the host key, no first-use trust" "$LOG" '^rsync .*StrictHostKeyChecking=yes'
has "uses only the seed key" "$LOG" '^rsync .*IdentitiesOnly=yes'
eq "ssh gets the key from Vault" "PRIVKEY-SECRET" "$(cat "$LOG.seedkey" 2>/dev/null)"
eq "the key file is 600" "600" "$(cat "$LOG.seedkeymode" 2>/dev/null)"
eq "ssh gets the host key from Vault" "192.168.1.127 ssh-ed25519 AAAAhostkey" "$(cat "$LOG.seedkh" 2>/dev/null)"
[[ -n "$(cat "$LOG.seedkeypath" 2>/dev/null)" && ! -e "$(cat "$LOG.seedkeypath")" ]] && ok || bad "seed key file removed after the copy"
hasnt "seed key never in argv" "$LOG" 'PRIVKEY-SECRET'
hasnt "seed key never printed" "$SB/log/out" 'PRIVKEY-SECRET'
has "hold is up while the playbook runs" "$LOG.env" 'hold present at playbook'
[[ -e "$SB/hold/awaiting-snapshots" ]] && bad "hold removed after a good copy" || ok
hasnt "provisioning is not held after a good copy" "$LOG" 'provisioner-held'
eq "snapshot directory stays 755 for the users' own nightly copies" "755" "$(stat -c %a "$SB/t3" 2>/dev/null)"
eq "snapshots arrived" "snap" "$(cat "$SB/t3/wizard/state-20261111-034710.sqlite.gz" 2>/dev/null)"
if [[ "$(grep -nE '^rsync' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^provisioner' "$LOG" | cut -d: -f1)" ]]; then ok; else bad "the copy comes before provisioning"; fi
if [[ "$(grep -nE '^apt-get install -y -qq terminal-lobby' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^rsync' "$LOG" | cut -d: -f1)" ]]; then ok; else bad "the copy comes after the playbook and the lobby"; fi

# 1d. The vault CLI is the version the playbook pins. The playbook installs
# vault=<that version> and apt refuses to downgrade, so a bootstrap that
# installed the newest vault would fail the playbook on every new box.
pin="$(sed -n 's/^ *devvm_vault_version: *"\(.*\)"$/\1/p' "$DIR/../playbooks/devvm.yml")"
[[ -n "$pin" ]] && ok || bad "the playbook pins devvm_vault_version"
has "installs the playbook's vault version" "$LOG" "^apt-get install -y -qq vault=$pin\$"
hasnt "never installs an unpinned vault" "$LOG" '^apt-get install -y -qq vault$'
has "adds the HashiCorp source the playbook declares" "$SB/hashicorp.list" "^deb \\[signed-by=$SB/hashicorp\\.asc\\] https://apt\\.releases\\.hashicorp\\.com jammy main\$"
if [[ "$(grep -nE '^git clone' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^apt-get install -y -qq vault=' "$LOG" | cut -d: -f1)" && \
      "$(grep -nE '^apt-get install -y -qq vault=' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^ansible-playbook' "$LOG" | cut -d: -f1)" ]]; then ok
else bad "vault is installed after the clone and before the playbook"; fi

new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/handoff.json"
VAULT_INSTALLED="$pin" run_bootstrap; rc=$?
eq "vault already at the pin: exits 0" 0 "$rc"
hasnt "vault already at the pin: no reinstall" "$LOG" '^apt-get install -y -qq vault'

new_sandbox; bootstrap_stubs
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/handoff.json"
NO_VAULT_PIN=1 run_bootstrap; rc=$?
eq "no pin in the playbook exits non-zero" 1 "$rc"
has "status names the missing pin" "$SB/state/status" '^failed: .*devvm_vault_version'
hasnt "no playbook without a vault pin" "$LOG" '^ansible-playbook'

# 1c. A copy that fails does not stop the build: users still get their
# accounts, the hold stays so no empty T3 starts, and the status says so.
for fail_how in RSYNC_RC=23 SEED_VAULT_FAIL=1; do
  new_sandbox; bootstrap_stubs
  printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master"}' >"$SB/handoff.json"
  ( export "${fail_how?}"; run_bootstrap ); rc=$?
  eq "$fail_how: build still exits 0" 0 "$rc"
  has "$fail_how: status is ok and names the T3 hold" "$SB/state/status" '^ok .*T3'
  has "$fail_how: provisioning runs, under the hold" "$LOG" 'provisioner-held'
  [[ -e "$SB/hold/awaiting-snapshots" ]] && ok || bad "$fail_how: hold left in place"
  has "$fail_how: the build log warns" "$SB/log/out" 'WARN.*T3'
  k="$(cat "$LOG.seedkeypath" 2>/dev/null)"; [[ -z "$k" || ! -e "$k" ]] && ok || bad "$fail_how: seed key removed"
  hasnt "$fail_how: seed key never printed" "$SB/log/out" 'PRIVKEY-SECRET'
done

# 1e. The live identity (handoff host_keys true, modules/proxmox-devvm
# allow_live_identity): the live devvm's SSH host keys come from Vault
# secret/workstation/devvm/ssh-host-keys and replace the first-boot ones right
# after the unwrap, before the long build, so the Proxmox host's pinned
# known_hosts line and every user's keep matching. cloud-init is told never to
# delete or regenerate them, or a later instance-id change would.
hostkeys_json() {  # <dir with ssh_host_*_key{,.pub}> -> JSON reply on stdout
  local d="$1" args=() f
  for f in "$d"/ssh_host_*; do args+=(--rawfile "$(basename "$f")" "$f"); done
  jq -n "${args[@]}" '{data: {data: $ARGS.named}}'
}
live_keys() {  # makes $SB/live with the live box's pairs, the reply in $SB/hostkeys.json
  mkdir -p "$SB/live"
  ssh-keygen -q -t ed25519 -N "" -C "root@devvm" -f "$SB/live/ssh_host_ed25519_key"
  ssh-keygen -q -t ecdsa -N "" -C "root@devvm" -f "$SB/live/ssh_host_ecdsa_key"
  ssh-keygen -q -t rsa -b 2048 -N "" -C "root@devvm" -f "$SB/live/ssh_host_rsa_key"
  hostkeys_json "$SB/live" >"$SB/hostkeys.json"
}

new_sandbox; bootstrap_stubs; live_keys
printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master","host_keys":true}' >"$SB/handoff.json"
HOSTKEYS_REPLY="$SB/hostkeys.json" run_bootstrap; rc=$?
eq "live identity exits 0" 0 "$rc"
eq "live identity: status is ok" "ok" "$(cat "$SB/state/status" 2>/dev/null)"
has "reads the host keys with the unwrapped token" "$LOG" 'curl .*https://vault\.viktorbarzin\.me/v1/secret/data/workstation/devvm/ssh-host-keys'
has "host-key read sends the token as a header on stdin" "$LOG.stdin" 'X-Vault-Token: hvs\.inner'
for t in ed25519 ecdsa rsa; do
  if cmp -s "$SB/live/ssh_host_${t}_key" "$SB/etc-ssh/ssh_host_${t}_key"; then ok; else bad "$t private key installed"; fi
  if cmp -s "$SB/live/ssh_host_${t}_key.pub" "$SB/etc-ssh/ssh_host_${t}_key.pub"; then ok; else bad "$t public key installed"; fi
  eq "$t private key is 600" 600 "$(stat -c %a "$SB/etc-ssh/ssh_host_${t}_key")"
  eq "$t public key is 644" 644 "$(stat -c %a "$SB/etc-ssh/ssh_host_${t}_key.pub")"
done
has "cloud-init keeps the keys" "$SB/cloud.cfg.d/99-devvm-host-keys.cfg" '^ssh_deletekeys: false$'
has "cloud-init generates none" "$SB/cloud.cfg.d/99-devvm-host-keys.cfg" '^ssh_genkeytypes: \[\]$'
has "sshd restarted on the new keys" "$LOG" '^systemctl try-restart ssh\.service'
if [[ "$(grep -nE '^systemctl try-restart ssh' "$LOG" | cut -d: -f1)" -lt "$(grep -nE '^git clone' "$LOG" | cut -d: -f1)" ]]; then ok; else bad "host keys go in before the clone and the playbook"; fi
priv_line="$(sed -n 2p "$SB/live/ssh_host_ed25519_key")"
hasnt "host private key never in argv" "$LOG" "$priv_line"
hasnt "host private key never printed" "$SB/log/out" "$priv_line"
[[ -z "$(ls -A "$SB/tmp")" ]] && ok || bad "no host-key temp files left behind"

# A pair that does not match, a missing ed25519 key, or a Vault refusal
# installs nothing: the box keeps its first-boot keys, the build goes on, and
# the status says the identity was not kept.
for case in mismatch no-ed25519 denied; do
  new_sandbox; bootstrap_stubs; live_keys
  case "$case" in
    mismatch) ssh-keygen -q -t ed25519 -N "" -f "$SB/other"; cp "$SB/other.pub" "$SB/live/ssh_host_ed25519_key.pub"; hostkeys_json "$SB/live" >"$SB/hostkeys.json" ;;
    no-ed25519) rm "$SB/live/ssh_host_ed25519_key"*; hostkeys_json "$SB/live" >"$SB/hostkeys.json" ;;
    denied) rm "$SB/hostkeys.json" ;;
  esac
  printf '{"wrapped_token":"hvs.wrapped","infra_ref":"master","host_keys":true}' >"$SB/handoff.json"
  HOSTKEYS_REPLY="$( [[ -e "$SB/hostkeys.json" ]] && echo "$SB/hostkeys.json")" run_bootstrap; rc=$?
  eq "$case: build still exits 0" 0 "$rc"
  has "$case: status names the host keys" "$SB/state/status" '^ok .*host keys'
  has "$case: the build log warns" "$SB/log/out" 'WARN.*host keys'
  eq "$case: first-boot ed25519 key left in place" "fresh" "$(cut -d' ' -f3 "$SB/etc-ssh/ssh_host_ed25519_key.pub")"
  [[ -e "$SB/etc-ssh/ssh_host_rsa_key" ]] && bad "$case: no live key installed" || ok
  [[ -z "$(ls -A "$SB/cloud.cfg.d")" ]] && ok || bad "$case: cloud-init left alone"
  hasnt "$case: sshd not restarted" "$LOG" '^systemctl .*ssh'
  has "$case: provisioning still runs" "$LOG" '^provisioner'
  [[ -z "$(ls -A "$SB/tmp")" ]] && ok || bad "$case: no host-key temp files left behind"
done

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
    HOST_KEYS="${HOST_KEYS:-false}" \
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
hasnt "a drill's token cannot read the live host keys" "$LOG" 'devvm-host-identity'
has "a drill's handoff asks for no host keys" "$LOG.content" '"host_keys": *false'

# 6a. The live identity: the token may also read the live host keys, and the
# handoff tells the guest to install them.
new_sandbox; handoff_stubs
HOST_KEYS=true run_handoff; rc=$?
eq "live handoff exits 0" 0 "$rc"
has "live token carries the host-key policy" "$LOG" 'vault token create -role=devvm-bootstrap -policy=devvm-bootstrap -policy=devvm-host-identity -wrap-ttl=1h -field=wrapping_token'
has "live handoff asks for the host keys" "$LOG.content" '"host_keys": *true'

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
