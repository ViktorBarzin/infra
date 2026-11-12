#!/usr/bin/env bash
# Checks the three steps t3-provision-users.sh runs so a rebuilt devvm gets each
# user's own state back (docs/plans/2026-11-11-disposable-devvm.md):
#   restore_user_credentials  the Vault-held credential files (workstation-creds)
#   install_vault_token_renew the renewer, its user units and a first token
#   install_user_dotfiles     chezmoi init --apply from the roster's dotfiles repo
#   install_agent_api_keys    the memory and pages keys in ~/.claude/settings.json
#   install_admin_infra_clone the admin's ~/code/infra, which the hourly run reads
#   stage_shared_auth         the shared Codex login and the chrome hub configs
# and that an admin VAULT_TOKEN the run is given reaches only the vault CLI,
# never a command run as a user (take_admin_vault_token, vault_admin).
#
# Run: bash scripts/test-t3-provision-creds.sh
#
# Pulls the functions out of the script by name and runs them against a temp
# home, with stand-ins for runuser, vault, systemctl, loginctl, curl and
# getent that record what they were asked to do.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/t3-provision-users.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

extract() {
  awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
for fn in take_admin_vault_token vault_admin mkdir_as write_as repo_url restore_user_credentials install_vault_token_renew install_user_dotfiles dotfiles_apply install_agent_api_keys install_admin_infra_clone stage_shared_auth; do
  eval "$(extract "$fn")"
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
CALLS="$tmp/calls"; : > "$CALLS"
export CALLS
# runuser notes the VAULT_TOKEN it was handed: a user's processes must never get one.
printf '#!/usr/bin/env bash\necho "runuser VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.runuser"\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
[[ "$*" == *is-enabled* ]] && exit 1
exit 0
EOF
cat > "$tmp/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "loginctl $*" >> "$CALLS"
[[ "$1" == show-user ]] && echo "Linger=no"
exit 0
EOF
cat > "$tmp/bin/vault" <<'EOF'
#!/usr/bin/env bash
echo "vault $*" >> "$CALLS"
echo "vault VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.vault"
[[ -n "${FAKE_VAULT_DENY:-}" ]] && exit 2
[[ "$*" == "kv get -field=api_keys secret/claude-memory" ]] && { printf '{"%s":"mem-key-1","other":"x"}' "$(id -un)"; exit 0; }
[[ "$*" == "kv get -field=api_keys secret/pages-publish" ]] && { printf '{"%s":"pages-key-1"}' "$(id -un)"; exit 0; }
[[ "$*" == "kv get -field=codex_shared_auth_json secret/workstation" ]] && { printf '{"tokens":"codex-login-1"}\n'; exit 0; }
[[ "$1 $2" == "token lookup" ]] && exit 0
[[ "$1 $2" == "token create" ]] && { echo "s.minted-token"; exit 0; }
exit 0
EOF
# git clones by making the target's .git, or fails when FAKE_GIT_FAIL is set.
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
[[ -n "${FAKE_GIT_FAIL:-}" ]] && exit 128
if [[ " $* " == *" clone "* ]]; then for a in "$@"; do last="$a"; done; mkdir -p "$last/.git"; fi
exit 0
GIT
for b in chgrp groupadd; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$b" > "$tmp/bin/$b"; done
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
# the chezmoi installer: writes a fake binary where -b says; its init leaves a
# source with a .git in it, as a real clone does
cat <<'SH'
while [ $# -gt 0 ]; do case "$1" in -b) b="$2"; shift;; esac; shift; done
mkdir -p "$b"; printf '#!/bin/sh\necho "chezmoi $*" >> "$CALLS"\nmkdir -p "$HOME/.local/share/chezmoi/.git"\n[ "$1" = managed ] && printf ".zshrc\\n.claude\\n.claude/settings.json\\n.claude/CLAUDE.md\\n"\nexit 0\n' > "$b/chezmoi"; chmod +x "$b/chezmoi"
SH
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"

LOG="$tmp/log"; : > "$LOG"
log() { echo "$*" >> "$LOG"; }
logged() { grep -qF -- "$1" "$LOG"; }
home="$tmp/home"; mkdir -p "$home"
TEST_HOME="$home"
getent() { echo "u:x:$(id -u):$(id -g)::$TEST_HOME:/bin/sh"; }
DRY_RUN=0
FORGEJO_BASE="https://forgejo.example.invalid"
CHEZMOI_VERSION=v2.69.3
me="$(id -un)"

# --- take_admin_vault_token ---------------------------------------------------
export VAULT_TOKEN=s.admin-test; take_admin_vault_token
eq "the admin token is kept in the script's own variable" "s.admin-test" "$ADMIN_VAULT_TOKEN"
eq "and taken out of the environment" "" "$(printenv VAULT_TOKEN)"
take_line="$(grep -n '^take_admin_vault_token$' "$SCRIPT" | head -1 | cut -d: -f1)"
first_user_cmd="$(grep -n 'fetch --quiet origin master' "$SCRIPT" | head -1 | cut -d: -f1)"
ok "the script takes the token before it first runs anything as a user" test "${take_line:-99999}" -lt "${first_user_cmd:-0}"
ok "the self-deploy re-exec hands the token on without putting it in argv" \
  grep -q 'export VAULT_TOKEN="\$ADMIN_VAULT_TOKEN"' "$SCRIPT"
ok "the deployed files are extracted on the self-deployed pass too" test \
  "$(grep -n '^committed scripts/workstation/workstation-creds.sh' "$SCRIPT" | cut -d: -f1)" -gt \
  "$(grep -n '^if \[\[ -z "\${T3_PROVISION_SELF_DEPLOYED:-}" \]\]; then$' "$SCRIPT" | head -1 | cut -d: -f1)"
no "no function calls the vault CLI directly" grep -qE '(^|[^_a-z-])vault (token|kv) ' <(grep -v '^ *#' "$SCRIPT" | grep -v 'log "')

# --- restore_user_credentials ------------------------------------------------
CREDS_SRC="$tmp/creds.sh"
printf '#!/usr/bin/env bash\necho "creds $*" >> "$CALLS"\necho "creds VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.vault"\necho "workstation-creds: $2 restored 3, kept 0, skipped 0"\n' > "$CREDS_SRC"
FAKE_VAULT_DENY=1 restore_user_credentials "$me"
FAKE_VAULT_DENY=1 restore_user_credentials other
no "without a Vault token nothing is restored" grep -q '^creds ' "$CALLS"
eq "the skip is logged once per run, not per user" "1" "$(grep -c 'credential restore skipped' "$LOG")"
unset CREDS_NO_VAULT_LOGGED
restore_user_credentials "$me"
ok "with a Vault token it restores that user" grep -qx "creds restore $me" "$CALLS"
ok "workstation-creds gets the admin token" grep -qx "creds VAULT_TOKEN=s.admin-test" "$CALLS.vault"
ok "its summary reaches the log" logged "restored 3, kept 0, skipped 0"
: > "$CALLS"; DRY_RUN=1 restore_user_credentials "$me" >/dev/null; DRY_RUN=0
no "a dry run restores nothing" grep -q '^creds ' "$CALLS"

# --- install_vault_token_renew ---------------------------------------------
VTR_SRC="$tmp/vtr.sh"; VTR_SERVICE="$tmp/vtr.service"; VTR_TIMER="$tmp/vtr.timer"
cat > "$VTR_SRC" <<EOF
#!/usr/bin/env bash
vtr_resolve_config() {
  case "\${1:-}" in
    $me) VTR_MINT_POLICIES=(pol-a pol-b) ;;
    *) return 1 ;;
  esac
}
EOF
printf '[Service]\nExecStart=%%h/.local/bin/vault-token-renew\n' > "$VTR_SERVICE"
printf '[Timer]\nOnCalendar=daily\n' > "$VTR_TIMER"
: > "$CALLS"; : > "$LOG"
install_vault_token_renew someone-unmapped
ok "a user the renewer has no scope for is skipped" logged "no token scope for someone-unmapped"
no "and nothing is installed for them" grep -q 'systemctl' "$CALLS"

install_vault_token_renew "$me"
ok "the renewer is installed" cmp -s "$VTR_SRC" "$home/.local/bin/vault-token-renew"
eq "the renewer is executable" "755" "$(stat -c %a "$home/.local/bin/vault-token-renew")"
ok "the service unit is installed" cmp -s "$VTR_SERVICE" "$home/.config/systemd/user/vault-token-renew.service"
ok "the timer unit is installed" cmp -s "$VTR_TIMER" "$home/.config/systemd/user/vault-token-renew.timer"
ok "linger is turned on so the timer runs logged out" grep -qx "loginctl enable-linger $me" "$CALLS"
ok "the timer is enabled" grep -q 'systemctl --user enable --now vault-token-renew.timer' "$CALLS"
ok "a missing token is minted with the renewer's policies" \
  grep -q -- "vault token create -orphan -period=768h -policy=pol-a -policy=pol-b -display-name=devvm-$me -field=token" "$CALLS"
eq "the token lands in ~/.vault-token" "s.minted-token" "$(cat "$home/.vault-token")"
eq "the token file is private" "600" "$(stat -c %a "$home/.vault-token")"

: > "$CALLS"
install_vault_token_renew "$me"
no "an existing token is never re-minted" grep -q 'token create' "$CALLS"
rm "$home/.vault-token"; : > "$CALLS"; : > "$LOG"
FAKE_VAULT_DENY=1 install_vault_token_renew "$me"
no "without admin Vault access no token is written" test -e "$home/.vault-token"
ok "and that is logged" logged "no ~/.vault-token for $me"

# --- install_user_dotfiles -------------------------------------------------
: > "$CALLS"; : > "$LOG"
install_user_dotfiles "$me" "-"
eq "no dotfiles repo, nothing happens" "" "$(cat "$CALLS")"

install_user_dotfiles "$me" viktor/dot_files
ok "chezmoi is installed at the pinned version when missing" grep -q '^curl ' "$CALLS"
ok "the binary lands in ~/.local/bin" test -x "$home/.local/bin/chezmoi"
ok "init clones the roster repo without applying it" \
  grep -qxF "chezmoi init --no-tty https://forgejo.example.invalid/viktor/dot_files.git" "$CALLS"
ok "everything outside ~/.claude and ~/.codex is applied, skipping encrypted entries" \
  grep -qxF "chezmoi apply --force --no-tty --keep-going --exclude=encrypted $home/.zshrc" "$CALLS"
ok "inside ~/.claude only links and directories are applied: the session store restores its files" \
  grep -qxF "chezmoi apply --force --no-tty --keep-going --exclude=encrypted,files $home/.claude" "$CALLS"
no "~/.codex is not named when the source has nothing there" grep -qF "$home/.codex" "$CALLS"
ok "the user manager reloads the new units" grep -q 'systemctl --user daemon-reload' "$CALLS"

: > "$CALLS"
install_user_dotfiles "$me" viktor/dot_files
no "an existing chezmoi source is never re-initialised" grep -q 'chezmoi init' "$CALLS"

mv "$home/.local/share/chezmoi" "$tmp/chezmoi-src"; mkdir -p "$home/.local/share/chezmoi"; : > "$CALLS"; : > "$LOG"
install_user_dotfiles "$me" viktor/dot_files
ok "an empty source, left by a failed first init, is retried" grep -q 'chezmoi init' "$CALLS"
ok "and the retry is logged" logged "retrying dotfiles for $me"
rm -rf "$home/.local/share/chezmoi"; cp "$home/.local/bin/chezmoi" "$tmp/chezmoi-good"
printf '#!/bin/sh\necho "chezmoi $*" >> "$CALLS"\nmkdir -p "$HOME/.local/share/chezmoi"\nexit 1\n' > "$home/.local/bin/chezmoi"
: > "$CALLS"; : > "$LOG"
install_user_dotfiles "$me" viktor/dot_files
ok "a failed init is logged" logged "finished with errors"
no "and leaves no empty source behind, so the next run retries" test -e "$home/.local/share/chezmoi"
cp "$tmp/chezmoi-good" "$home/.local/bin/chezmoi"
mkdir -p "$home/.local/share/chezmoi"; echo keep > "$home/.local/share/chezmoi/dot_zshrc"; : > "$CALLS"
install_user_dotfiles "$me" viktor/dot_files
no "a source with files in it is never re-initialised" grep -q 'chezmoi init' "$CALLS"
eq "and is left as it was" "keep" "$(cat "$home/.local/share/chezmoi/dot_zshrc")"

# --- install_admin_infra_clone ---------------------------------------------
FORGEJO_INFRA_REMOTE="https://forgejo.example.invalid/viktor/infra.git"
: > "$CALLS"; : > "$LOG"
install_admin_infra_clone "$me"
ok "a missing ~/code/infra is cloned from public Forgejo" \
  grep -qx "git clone --quiet $FORGEJO_INFRA_REMOTE $home/code/infra" "$CALLS"
ok "the clone gets the forgejo remote the land flow pushes to" \
  grep -qx "git -C $home/code/infra remote add forgejo $FORGEJO_INFRA_REMOTE" "$CALLS"
eq "~/code is made like the live one, setgid for code-shared" "2770" "$(stat -c %a "$home/code")"
ok "~/code is handed to code-shared" grep -qx "chgrp code-shared $home/code" "$CALLS"
ok "the clone is logged with where its unlock key is" logged "git_crypt_key_b64"
: > "$CALLS"
install_admin_infra_clone "$me"
no "an existing ~/code/infra is never touched" grep -q '^git ' "$CALLS"
rm -rf "$home/code"; mkdir -p "$home/code/.git"; : > "$CALLS"
install_admin_infra_clone "$me"
no "nor a ~/code that is itself the clone" grep -q '^git ' "$CALLS"
rm -rf "$home/code"; : > "$CALLS"; : > "$LOG"
FAKE_GIT_FAIL=1 install_admin_infra_clone "$me"
ok "a failed clone is a warning, retried on the next run" logged "clone of infra failed"
rm -rf "$home/code"; : > "$CALLS"
DRY_RUN=1 install_admin_infra_clone "$me" >/dev/null; DRY_RUN=0
no "a dry run clones nothing" grep -q '^git ' "$CALLS"
ok "the admin tier gets the clone in the account loop" grep -q '\[\[ "$tier" == admin \]\] && install_admin_infra_clone "$os_user"' "$SCRIPT"

# --- stage_shared_auth -----------------------------------------------------
CODEX_SHARED_DIR="$tmp/opt/codex-shared"; ENVDIR="$tmp/etc-t3"; mkdir -p "$ENVDIR" "$tmp/opt"
HUBS_MAP="$tmp/chrome-hubs.json"; printf '{"%s":{"vault_path":"chrome-x","host":"h","namespace":"n"}}\n' "$me" > "$HUBS_MAP"
HUBS_SRC="$tmp/stage-hubs.sh"
cat > "$HUBS_SRC" <<'HUBS'
#!/usr/bin/env bash
echo "hubs VAULT_TOKEN=${VAULT_TOKEN:-<unset>}" >> "$CALLS.vault"
echo "hubs $CHROME_HUBS_MAP $CHROME_HUBS_OUT" >> "$CALLS"
for u in $(jq -r 'keys[]' "$CHROME_HUBS_MAP"); do echo '{"read_token":"r"}' > "$CHROME_HUBS_OUT/chrome-hub-$u.json"; echo "staged $u"; done
HUBS
: > "$CALLS"; : > "$LOG"
FAKE_VAULT_DENY=1 stage_shared_auth
no "without an admin token the Codex login is not written" test -e "$CODEX_SHARED_DIR/auth.json"
no "nor are the hub configs" grep -q '^hubs ' "$CALLS"
ok "and the skip is logged" logged "shared login staging skipped"
: > "$CALLS"; : > "$CALLS.vault"; : > "$LOG"
stage_shared_auth
eq "the Codex login comes from secret/workstation" '{"tokens":"codex-login-1"}' "$(cat "$CODEX_SHARED_DIR/auth.json")"
eq "the login is readable by the group only" "660" "$(stat -c %a "$CODEX_SHARED_DIR/auth.json")"
eq "its directory is setgid and closed to others" "2770" "$(stat -c %a "$CODEX_SHARED_DIR")"
ok "the directory belongs to codex-shared" grep -qx "chgrp codex-shared $CODEX_SHARED_DIR" "$CALLS"
ok "the hub staging script runs with the map and the t3-serve dir" grep -qx "hubs $HUBS_MAP $ENVDIR" "$CALLS"
ok "the hub staging script, run as root, gets the admin token" grep -qx "hubs VAULT_TOKEN=s.admin-test" "$CALLS.vault"
ok "its hub config is staged" test -s "$ENVDIR/chrome-hub-$me.json"
no "no secret value reaches the log" grep -q 'codex-login-1' "$LOG"
no "no temp file is left in the shared directory" compgen -G "$CODEX_SHARED_DIR/.auth.json.*"
: > "$CALLS"
stage_shared_auth
eq "with everything in place nothing is asked of Vault" "" "$(cat "$CALLS")"
echo '{"tokens":"newer-on-the-box"}' > "$CODEX_SHARED_DIR/auth.json"; rm "$ENVDIR/chrome-hub-$me.json"; : > "$CALLS"
stage_shared_auth
eq "a Codex login already there is never replaced" '{"tokens":"newer-on-the-box"}' "$(cat "$CODEX_SHARED_DIR/auth.json")"
ok "while a missing hub config is still staged" test -s "$ENVDIR/chrome-hub-$me.json"
ok "the step runs after the restore and before the account loop" test \
  "$(grep -n '^stage_shared_auth$' "$SCRIPT" | cut -d: -f1)" -lt "$(grep -n '^# 4) per-account' "$SCRIPT" | cut -d: -f1)"

# --- install_agent_api_keys -------------------------------------------------
settings="$home/.claude/settings.json"; mkdir -p "$home/.claude"
printf '{"env":{"MEMORY_API_KEY":"kept-by-hand","STATUSLINE_X":"1"},"fastMode":true}\n' > "$settings"
: > "$CALLS"; : > "$LOG"
install_agent_api_keys "$me"
eq "a key already there is never replaced" "kept-by-hand" "$(jq -r .env.MEMORY_API_KEY "$settings")"
eq "a missing memory key comes from secret/claude-memory" "mem-key-1" "$(jq -r .env.CLAUDE_MEMORY_API_KEY "$settings")"
eq "a missing pages key comes from secret/pages-publish" "pages-key-1" "$(jq -r .env.PAGES_API_KEY "$settings")"
eq "the memory URL is filled in with its key" "https://claude-memory.viktorbarzin.me" "$(jq -r .env.CLAUDE_MEMORY_API_URL "$settings")"
eq "the rest of settings.json is kept" "1 true" "$(jq -r '"\(.env.STATUSLINE_X) \(.fastMode)"' "$settings")"
eq "settings.json stays private" "600" "$(stat -c %a "$settings")"
ok "what it filled is logged by name" logged "CLAUDE_MEMORY_API_KEY"
no "a key value never reaches the log" grep -qE 'mem-key-1|pages-key-1' "$LOG"
: > "$CALLS"
install_agent_api_keys "$me"
no "with every key present Vault is not asked" grep -q '^vault ' "$CALLS"
rm "$settings"; : > "$CALLS"
FAKE_VAULT_DENY=1 install_agent_api_keys "$me"
no "without admin Vault access nothing is written" test -e "$settings"
install_agent_api_keys "$me"
eq "a missing settings.json is created with the keys" "mem-key-1" "$(jq -r .env.MEMORY_API_KEY "$settings")"
: > "$LOG"
TEST_HOME="$tmp/nohome" install_agent_api_keys "$me"
eq "a user without ~/.claude is left alone" "" "$(cat "$LOG")"

# --- the admin token reaches only the vault CLI ------------------------------
ok "the vault CLI was given the admin token" grep -qx "vault VAULT_TOKEN=s.admin-test" "$CALLS.vault"
ok "commands did run as the user" grep -q '^runuser ' "$CALLS.runuser"
no "no command run as a user ever got the admin token" grep -q 's.admin-test' "$CALLS.runuser"

echo "t3-provision creds: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
