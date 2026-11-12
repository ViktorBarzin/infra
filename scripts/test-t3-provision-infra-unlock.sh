#!/usr/bin/env bash
# Checks unlock_admin_infra_clone in t3-provision-users.sh: on a run with an
# admin Vault token, the admin's locked ~/code/infra is git-crypt unlocked with
# Vault secret/infra git_crypt_key_b64, so a rebuilt devvm needs no hand unlock
# (docs/runbooks/devvm-credentials.md, "Rebuild: put a user's credentials back").
#   - only on the live box's address, or on a drill root opted in
#   - only with an admin token that reads the key
#   - a clone that already has its key is never touched (no re-lock, no read)
#   - the key file lives in a 0700 directory, is 0600, and is gone afterwards
#   - the key never reaches the log, a command line or a user's environment
#   - the filters get --key-file, as on the live clone, so worktrees decrypt
#
# Run: bash scripts/test-t3-provision-infra-unlock.sh
#
# Pulls the functions out of the script by name and runs them against a temp
# home holding a real git-crypt repo, with stand-ins for runuser, ip and vault
# that record what they were asked to do. Needs git and git-crypt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

command -v git-crypt >/dev/null || { echo "SKIP: git-crypt not installed"; exit 0; }

extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
for fn in take_admin_vault_token vault_admin mkdir_as write_as is_live_devvm unlock_admin_infra_clone; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
mkdir -p "$tmp/bin" "$tmp/scratch" "$tmp/state"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS
# runuser records its command and the VAULT_TOKEN it was handed: a user's
# processes must never get one.
cat > "$tmp/bin/runuser" <<'EOF'
#!/usr/bin/env bash
echo "runuser $* (VAULT_TOKEN=${VAULT_TOKEN:-<unset>})" >> "$CALLS"
[[ "$1" == -u ]] && shift 2
[[ "$1" == -- ]] && shift
exec "$@"
EOF
cat > "$tmp/bin/ip" <<'EOF'
#!/usr/bin/env bash
echo "2: eth0    inet ${FAKE_ADDR:-10.0.10.10}/24 brd 10.0.10.255 scope global eth0"
EOF
cat > "$tmp/bin/vault" <<EOF
#!/usr/bin/env bash
echo "vault \$* (VAULT_TOKEN=\${VAULT_TOKEN:-<unset>})" >> "\$CALLS"
[[ "\$1 \$2" == "token lookup" ]] && { [[ -n "\${FAKE_NO_TOKEN:-}" ]] && exit 2; exit 0; }
[[ "\$*" == "kv get -field=git_crypt_key_b64 secret/infra" ]] && { [[ -n "\${FAKE_DENY:-}" ]] && exit 2; cat "$tmp/key.b64"; exit 0; }
exit 1
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
LOG="$tmp/log"; : > "$LOG"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
DRY_RUN=0
STATEDIR="$tmp/state"
INFRA_UNLOCK_TMP="$tmp/scratch"
me="$(id -un)"
home="$tmp/home"; mkdir -p "$home/code"
TEST_HOME="$home"
getent() { echo "$me:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# An origin like Forgejo's infra: one git-crypt file, one plain file.
src="$tmp/origin"
git init -q -b master "$src"
( cd "$src" && git-crypt init >/dev/null 2>&1 &&
  echo 'config.tfvars filter=git-crypt diff=git-crypt' > .gitattributes &&
  echo 'secret_value = "plaintext-marker"' > config.tfvars && echo readme > README &&
  git add -A && git commit -qm init && git-crypt export-key "$tmp/key" )
base64 -w0 "$tmp/key" > "$tmp/key.b64"
dst="$home/code/infra"
fresh_clone() { rm -rf "$dst"; git clone -q "$src" "$dst"; }
locked() { head -c 10 "$dst/config.tfvars" | grep -q GITCRYPT; }
leftovers() { [[ -n "$(ls -A "$tmp/scratch")" ]]; }
reset() { : > "$CALLS"; : > "$LOG"; }

# The admin token arrives in VAULT_TOKEN and is taken out of the environment.
VAULT_TOKEN=s.admin-token; take_admin_vault_token

# --- nothing to unlock -----------------------------------------------------------
reset
unlock_admin_infra_clone "$me"
no "no clone yet: vault is not asked" grep -q '^vault ' "$CALLS"

fresh_clone
ok "a fresh clone is locked" locked

# --- a drill keeps the key off its disk -------------------------------------------
reset
FAKE_ADDR=10.0.10.14 unlock_admin_infra_clone "$me"
ok "a drill without the opt-in stays locked" locked
no "and never reads the key" grep -q 'secret/infra' "$CALLS"
ok "and says how to opt in" logged "touch $STATEDIR/drill-unlock-infra"

# --- no admin token: the hourly run -----------------------------------------------
reset
FAKE_NO_TOKEN=1 unlock_admin_infra_clone "$me"
ok "no admin token: stays locked" locked
no "and the key is not read" grep -q 'secret/infra' "$CALLS"
ok "and logs the skip" logged "no admin Vault token"

# --- a token that cannot read secret/infra: the bootstrap's own run ---------------
reset
FAKE_DENY=1 unlock_admin_infra_clone "$me"
ok "a token without secret/infra: stays locked" locked
no "and leaves no key directory" leftovers
ok "and logs why" logged "cannot read secret/infra"

# --- dry run ----------------------------------------------------------------------
reset
DRY_RUN=1
eq "dry run only reports" "[dry-run] git-crypt unlock $me:~/code/infra with secret/infra git_crypt_key_b64" \
  "$(unlock_admin_infra_clone "$me")"
DRY_RUN=0
ok "dry run leaves it locked" locked

# --- a dirty tree: git-crypt refuses, nothing is left behind -----------------------
reset
echo local-edit >> "$dst/README"
unlock_admin_infra_clone "$me"
ok "a dirty clone stays locked" locked
ok "and the refusal is a WARN" logged "WARN: git-crypt unlock of $me:~/code/infra failed"
no "and the key file is gone" leftovers
fresh_clone

# --- the live box with an admin token ----------------------------------------------
reset
# Watch the key file while git-crypt reads it: a git-crypt stand-in in front
# of the real one notes the modes, then hands over.
real_gc="$(PATH="${PATH#"$tmp/bin:"}" command -v git-crypt)"
cat > "$tmp/bin/git-crypt" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == unlock ]]; then
  echo "git-crypt unlock: dir \$(stat -c %a "\$(dirname "\$2")") file \$(stat -c %a "\$2")" >> "\$CALLS"
fi
exec "$real_gc" "\$@"
EOF
chmod +x "$tmp/bin/git-crypt"
FAKE_ADDR=10.0.10.10 unlock_admin_infra_clone "$me"
no "the live box unlocks the clone" locked
eq "the secret file reads as plaintext" 'secret_value = "plaintext-marker"' "$(cat "$dst/config.tfvars")"
ok "the key file was 0600 in a 0700 directory" grep -qxF "git-crypt unlock: dir 700 file 600" "$CALLS"
no "and is gone afterwards" leftovers
ok "the unlock is logged" logged "unlocked $me:~/code/infra"
ok "the clone holds its key" test -s "$dst/.git/git-crypt/keys/default"
eq "git status is clean after the unlock" "" "$(git -C "$dst" status --porcelain)"
ok "vault read the key with the admin token" grep -qF "vault kv get -field=git_crypt_key_b64 secret/infra (VAULT_TOKEN=s.admin-token)" "$CALLS"
no "no command run as the user carried the admin token" grep -q '^runuser .*VAULT_TOKEN=s\.' "$CALLS"
no "the key is on no command line" grep -qF -f "$tmp/key.b64" "$CALLS"
no "and in no log line" grep -qF -f "$tmp/key.b64" "$LOG"
eq "the smudge filter names the key file, as on the live clone" \
  "\"git-crypt\" smudge --key-file $dst/.git/git-crypt/keys/default" "$(git -C "$dst" config filter.git-crypt.smudge)"
eq "so does the clean filter" \
  "\"git-crypt\" clean --key-file $dst/.git/git-crypt/keys/default" "$(git -C "$dst" config filter.git-crypt.clean)"
eq "and the diff textconv" \
  "\"git-crypt\" diff --key-file $dst/.git/git-crypt/keys/default" "$(git -C "$dst" config diff.git-crypt.textconv)"
git -C "$dst" worktree add -q "$tmp/wt" -b wt-test 2>/dev/null
eq "a plain worktree of the clone decrypts" 'secret_value = "plaintext-marker"' "$(cat "$tmp/wt/config.tfvars" 2>/dev/null)"
git -C "$dst" worktree remove --force "$tmp/wt" 2>/dev/null

# --- already unlocked: never touched again ------------------------------------------
reset
FAKE_ADDR=10.0.10.10 unlock_admin_infra_clone "$me"
no "an unlocked clone: vault is not asked" grep -q '^vault ' "$CALLS"
no "and git-crypt is not run" grep -q 'git-crypt' "$CALLS"
no "nor locked again" locked
eq "and nothing is logged" "" "$(cat "$LOG")"

# --- a drill that opted in ---------------------------------------------------------
fresh_clone; reset
touch "$STATEDIR/drill-unlock-infra"
FAKE_ADDR=10.0.10.14 unlock_admin_infra_clone "$me"
no "a drill with the opt-in unlocks" locked
rm "$STATEDIR/drill-unlock-infra"

# --- wiring ------------------------------------------------------------------------
ok "the main loop unlocks right after the admin's clone" \
  grep -qxF '  [[ "$tier" == admin ]] && unlock_admin_infra_clone "$os_user"' "$SCRIPT"
ok "after install_admin_infra_clone" \
  eval 'grep -n -e "&& install_admin_infra_clone \"\$os_user\"" -e "&& unlock_admin_infra_clone \"\$os_user\"" "$SCRIPT" | cut -d: -f2 | tr -d "\n" | grep -q "install_admin_infra_clone.*unlock_admin_infra_clone"'

echo "t3-provision infra unlock: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
